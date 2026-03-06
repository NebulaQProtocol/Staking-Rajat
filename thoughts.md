# THOUGHTS.md — NQ-Swap Staking Pool

Engineering notes for the NQ-Swap liquidity mining protocol. This document covers
the full design process: architecture decisions made before any code was written,
the reasoning behind each major implementation choice, and an honest assessment of
what the system does and does not protect against.

---

## 1. Architecture phase — thinking before coding

The assignment was explicit: design first, code second. So before touching a file
I worked through the following questions.

### What contracts do we actually need?

The core requirement is: users deposit LP tokens, earn reward tokens over time,
and can withdraw after a mandatory wait. That maps cleanly onto three separate
concerns:

1. **The token layer** — LP token (ERC-1363) and reward token (ERC-20). These
   need to be their own contracts, not embedded in the pool, so they can be
   deployed independently and reused.

2. **The pool** — owns all the staking logic, reward accounting, and the
   cooldown/multisig mechanism. One contract. It should not inherit from anything
   it doesn't own.

3. **The oracle** — exposes a single function `rewardPerBlock()`. Keeping it
   behind an interface means the pool never needs to know whether the oracle is
   a mock, a Chainlink feed, or a governance-controlled contract. Swap it without
   touching the pool.

No proxies, no upgrades, no diamond pattern. The complexity budget goes into the
protocol mechanics, not the infrastructure.

### High-level layout

```
    [LP Token (ERC-1363)]
           |
           | stake() or transferAndCall()
           v
    [StakingPool]
           |
           |--- reward accounting (MasterChef accumulator)
           |--- two-step withdrawal with 2-day cooldown
           |--- security multisig with flag/reset power
           |
    [IRewardOracle]           [Reward Token (ERC-20)]
    rewardPerBlock()          transfer on claim/withdraw
```

### What are the real attack surfaces?

Before writing a single line I listed the ways this system could go wrong:

- **Re-entrancy through reward/LP token transfers** — `claimRewards` and
  `executeWithdrawal` call external tokens. If a token fires a callback on
  `transfer`, it can re-enter the pool before state has been zeroed.
- **Re-entrancy through ERC-1363 callback** — `onTransferReceived` fires during
  a `transferAndCall`. The tokens are already in the contract but the pool's
  accounting hasn't updated yet. A malicious LP token could call back into `stake`
  or `requestWithdrawal` before the first call finishes.
- **Fake ERC-1363 callbacks** — anyone can call `onTransferReceived` directly
  without actually transferring tokens. A naive implementation would credit a
  stake backed by no real LP tokens.
- **Accumulator arithmetic overflow** — `accRewardPerShare` accumulates
  `(blocks × rate × 1e18) / totalStaked`. The intermediate `blocks × rate × 1e18`
  is the dangerous multiplication.
- **Oracle rate manipulation** — a compromised oracle could return
  `type(uint256).max`, inflating `accRewardPerShare` and draining the reserve.
- **Withdrawal replay** — request record not deleted before the LP transfer.
  Second call drains twice.
- **Reward insolvency drift** — if `rewardReserve` accounting drifts even slightly
  from the actual token balance, the last claimant gets a silent transfer failure.

Every one of these shaped a concrete decision in the implementation.

### Data structure decisions

**Why `mapping(address => UserInfo)` instead of an array of users?**

Arrays of users require iteration. Any function that iterates over all stakers
costs O(n) gas and becomes unusable as TVL grows. The MasterChef accumulator
pattern (detailed in section 2) eliminates this entirely: per-user rewards are
computed in O(1) from a personal checkpoint. There is no need to keep a list of
users at all. A mapping keyed by address is the correct structure.

**Why `mapping(address => mapping(uint256 => WithdrawalRequest))` for requests?**

Users can have multiple concurrent withdrawal requests. An array per user would
require iteration to find a specific request by ID — O(n). A nested mapping gives
O(1) lookup by `(user, id)` and O(1) deletion. The tradeoff is that you can't
enumerate a user's requests without a companion index, which is why
`_userWithdrawalIds` exists as a separate array. That array is only used in view
functions and for swap-and-pop deletion — never iterated on a state-changing path.

**Why packed structs?**

`UserInfo` fits in two 32-byte storage slots:
- Slot 0: `stakedAmount` (uint128) + `rewardDebt` (uint128)
- Slot 1: `pendingRewards` (uint128) + `_reserved` (uint128)

Every stake, unstake, and claim reads and writes this struct. Packing halves the
number of `SLOAD`/`SSTORE` operations on the hot path. `uint128` holds up to
~3.4×10³⁸ — more than any realistic LP token supply.

`WithdrawalRequest` packs `amount` (uint128), `requestTime` (uint64), `flagged`
(bool), and padding into one slot, with `id` in the second. The padding is
explicit rather than implicit so the compiler doesn't silently reorder fields.

---

## 2. Reward accounting — the MasterChef accumulator

The standard DeFi approach for continuous reward distribution without iteration
is a global per-share accumulator:

```
accRewardPerShare += (blocksElapsed × rewardPerBlock × PRECISION) / totalStaked
```

`PRECISION = 1e18` keeps the math aligned with 18-decimal tokens and prevents
the division from discarding sub-token amounts prematurely.

Each user stores a `rewardDebt` — the value of `stakedAmount × accRewardPerShare
/ PRECISION` at the time of their last interaction. Their uncollected rewards at
any moment are:

```
earned = (stakedAmount × accRewardPerShare / PRECISION) − rewardDebt
```

The accumulator only ever goes up. The debt only moves when the user interacts.
The difference between them is exactly what was earned in the interval between
interactions, regardless of what other users did in the meantime.

### The call ordering problem

The trickiest correctness constraint in the contract is the sequence of internal
calls. Every state-changing function must follow this exact order:

1. `_updatePool()` — advance the accumulator to the current block
2. `_creditPendingRewards(user)` — move earned-since-last-checkpoint into `pendingRewards`
3. modify `stakedAmount` (if the operation changes it)
4. `_updateRewardDebt(user)` — snapshot the new debt

Steps 2 and 4 cannot be swapped. If debt is snapshotted before credit, all
rewards accrued since the last interaction are silently discarded. If `_updatePool`
is skipped, the credit is calculated against a stale accumulator and recent blocks
are missed.

`claimRewards` has no balance change, so step 3 is absent — but step 4 must still
run. Without it, `pendingReward()` returns 0 right after a claim (correct) but
returns a non-zero amount one call later (wrong) because the debt still points at
the pre-claim accumulator value.

### Dynamic reward rate

The reward rate is not a storage variable in the pool. It is fetched from
`IRewardOracle.rewardPerBlock()` on every `_updatePool` call. This means the
emission rate can change every block without any upgrade or migration to the pool.

The `MAX_REWARD_PER_BLOCK` cap (10²⁴) is a hard safety rail. A misconfigured or
compromised oracle causes a clean revert rather than silently corrupting
`accRewardPerShare`. A zero rate also reverts — a pool with zero emission is
broken and should fail loudly rather than silently not paying stakers.

---

## 3. Cooldown security model

### Why the withdrawal has to be two steps

An instant withdrawal makes monitoring useless — by the time an alert fires, the
funds are gone. The two-step flow creates a mandatory response window.

`requestWithdrawal` moves tokens out of the earning pool immediately. The user's
`stakedAmount` drops, `totalPendingWithdrawals` rises, and those tokens are
"spoken for" inside the contract. They cannot earn further rewards or be used as
collateral for a second request. Any rewards earned up to the request are
credited to `pendingRewards` and held there until `executeWithdrawal`.

`executeWithdrawal` runs only after 2 days. It deletes the request record and
transfers LP tokens plus pending rewards. The delete runs before the transfers
(Checks-Effects-Interactions), so even if the LP token fires a callback the
request is already gone — a second call hits `SP__WithdrawalNotFound`.

### The flagging mechanism — what the multisig can and cannot do

`flagWithdrawal(user, id)` is the multisig's only action. It resets `requestTime`
to `block.timestamp` and sets `flagged = true`. Since `unlockTime = requestTime +
COOLDOWN`, the effect is to push the unlock 2 days forward from the moment of
flagging.

The `flagged` bit is a one-shot lock. Once set, the multisig cannot flag the same
request again. This is deliberate: the multisig gets one extension per request,
not infinite extensions. A user can always wait out any single flag.

The multisig cannot cancel a request, reduce the amount, or redirect tokens.
Giving it that power would mean funds could be seized by whoever holds the
multisig key — that is unacceptable for a DeFi protocol. The flag-only mechanism
provides a defensive window without creating a new centralisation risk.

---

## 4. Re-entrancy — why the mutex alone is not enough

The contract uses two complementary defences.

**Defence 1: Checks-Effects-Interactions (CEI)**

Every function that makes an external call zeroes the relevant state before the
call. In `executeWithdrawal`:

```solidity
// Effects — happen first
delete _withdrawalRequests[msg.sender][id];
_removeWithdrawalId(msg.sender, id);
totalPendingWithdrawals -= lpAmount;
_userInfo[msg.sender].pendingRewards = 0;
rewardReserve -= rewardAmount;

// Interactions — happen after state is clean
IERC20(lpToken).transfer(msg.sender, lpAmount);
IERC20(rewardToken).transfer(msg.sender, rewardAmount);
```

If a token fires a re-entrancy callback, the request is already deleted and
pending rewards already zero. A second call finds nothing to exploit.

**Defence 2: Re-entrancy mutex**

`uint8 _locked`, 1 = open, 2 = locked. Every public state-changing function
carries `nonReentrant`, which sets `_locked = 2` on entry and resets it to 1 on
exit. Any re-entrant call hits `SP__Locked()`.

**Why both?**

`onTransferReceived` is called mid-transfer by the LP token, before the pool has
updated its own accounting. The tokens have moved but effects haven't happened
yet — CEI cannot protect against a callback that fires before the effects exist.
The mutex blocks that window.

CEI is still needed because in theory two interleaved re-entrancy paths through
different functions could still exploit inconsistent intermediate state if the
mutex were the only guard. With both defences, CEI ensures state consistency even
if the mutex is somehow bypassed, and the mutex closes the ERC-1363 callback
window that CEI alone can't cover.

---

## 5. ERC-1363 — why it was used and how it is secured

Standard ERC-20 staking is a two-transaction UX: approve, then stake. Two
confirmations, two gas payments, two chances for the user to stop halfway.
ERC-1363 collapses that into one: `transferAndCall(pool, amount)` transfers the
tokens and immediately calls `onTransferReceived` on the recipient in the same
transaction.

The pool implements `IERC1363Receiver`. The critical guard in `onTransferReceived`
is:

```solidity
if (msg.sender != lpToken) revert SP__NotLPToken(msg.sender);
```

Without this, anyone can call `onTransferReceived` directly without transferring
any tokens. The `msg.sender` must be the LP token contract itself — not a router,
not a user wallet, not any other contract.

The re-entrancy risk from ERC-1363 is real and distinct from the standard
external-call risk: the callback fires before the pool has recorded the deposit.
The mutex shuts that window. The two defences (mutex + CEI) are described in
detail in section 4.

---

## 6. Yul assembly — what it does and why it's here

Two internal functions use inline Yul: `_computeReward` and
`_computeRewardAddition`. Both implement a `mulDiv` — multiply two `uint256`
values and divide by a third — with explicit overflow protection.

The naive Solidity:

```solidity
result = (a * b) / c;
```

Works under Solidity 0.8 checked arithmetic, but "reverts on overflow" produces
a generic arithmetic panic (error code 0x11), not a named, auditable error. The
Yul version catches overflow before the multiply and reverts with a named custom
error:

```yul
let maxUint := 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
if gt(b, div(maxUint, a)) {
    // SP__MulOverflow() selector = 0x906c1881
    mstore(0x00, 0x906c188100000000000000000000000000000000000000000000000000000000)
    revert(0x00, 0x04)
}
```

The `0x906c1881` selector is the first four bytes of
`keccak256("SP__MulOverflow()")`. Writing it directly to memory and calling
`revert` is cheaper than constructing an ABI-encoded custom error at the Solidity
level.

**Why the inner Yul function pattern?**

The `leave` keyword only works inside a named Yul function, not at the top level
of an `assembly {}` block. The zero-input fast path (`if iszero(a) { leave }`)
needs `leave` to skip the overflow check when `a = 0`. Wrapping the logic in an
inner function (`function mulDiv(a, b, precision) -> res`) makes both the fast
path and the overflow path readable without an awkward `switch` ladder.

**Why is this on the hot path?**

`_computeReward` is called on every stake, every withdrawal request, and every
claim — the three most common operations in the system. The gas savings per call
are modest, but they compound across every user interaction for the protocol's
lifetime. More importantly, the explicit overflow check with a named error is
clearer in intent and more auditable than a Solidity arithmetic panic.

---

## 7. No OpenZeppelin — what had to be built from scratch

The assignment prohibited OZ. These are the pieces that are normally provided
for free:

**ERC20Base** — standard ERC-20: `transfer`, `transferFrom`, `approve`,
`allowance`, `balanceOf`, `totalSupply`. Decimals stored as `immutable uint8` so
each token can set its own without using a storage slot.

**ERC1363Token** — thin abstract layer on top of ERC20Base. Adds `transferAndCall`,
`transferFromAndCall`, `approveAndCall`. The callback helper (`_notifyTransferReceived`)
does a low-level call and checks the magic return value
(`0x88a7ca5c`). The contract-vs-EOA check uses `extcodesize` — zero size means
it's an EOA and can't receive the callback.

**Re-entrancy guard** — `uint8 _locked` (1 = open, 2 = locked). A `bool` costs
the same in the EVM but `uint8` makes the two-state intent explicit and can be
packed into the same slot as adjacent state variables.

**onlyOwner / onlyMultisig** — single-line modifiers. No role management
framework is needed because there are exactly two privileged roles and neither
can be delegated.

---

## 8. Gas optimization strategies

**Custom errors.** `revert SP__ZeroAmount()` encodes to 4 bytes. `revert("zero")`
encodes the string, easily 10× the gas. Every revert in the contract uses a
custom error.

**Packed structs.** `UserInfo` and `WithdrawalRequest` are laid out so their
fields share EVM storage words. Two fields per slot means one `SLOAD` reads both.
On a path called thousands of times per day, halving storage reads matters.

**Immutable variables.** `lpToken`, `rewardToken`, and `owner` are `immutable`.
They are baked into bytecode at deployment. A cold `SLOAD` costs 2100 gas; reading
an immutable costs 0.

**Storage caching.** `_updatePool` copies `lastRewardBlock` and `totalStaked` into
stack variables at the top of the function. Subsequent reads within the function
hit the stack (3 gas) rather than storage (100 gas warm).

**`unchecked` blocks.** Used only where overflow is structurally impossible:
- Loop increments (`unchecked { i++; }`) — `i < len` is checked each iteration.
- `accRewardPerShare` addition — the Yul block above has already confirmed the
  operands don't overflow.
- `nextWithdrawalId++` — an explicit `type(uint256).max` guard fires first.

**Skipping redundant `_updatePool` calls.** The function opens with:

```solidity
if (block.number == lastRewardBlock) return;
```

Two calls in the same block — common with batched transactions — skip the oracle
call, the multiplication, and the storage write entirely on the second call.

**`uint8` mutex.** Can be packed into the same storage slot as adjacent variables
rather than occupying its own slot, and the two-value encoding (`1`/`2` instead
of `false`/`true`) is more explicit about intent.

---

## 9. Security model — what the pool does and doesn't cover

### Covered

- **Re-entrancy** — mutex on every public entry point, CEI ordering throughout.
  State is zeroed before any external call (section 4).
- **Integer overflow** — `unchecked` blocks only where overflow is provably
  impossible. Everything else relies on Solidity 0.8 default checks or the
  explicit Yul guard (section 6).
- **Oracle rate manipulation** — `MAX_REWARD_PER_BLOCK` (10²⁴) hard cap. A
  malicious oracle reverts the pool rather than corrupting the accumulator.
- **Fake ERC-1363 callbacks** — `msg.sender == lpToken` check in
  `onTransferReceived` (section 5).
- **Withdrawal replay** — `delete _withdrawalRequests[user][id]` runs before any
  transfer. A replayed call hits `SP__WithdrawalNotFound`.
- **Zero-address misconfiguration** — every address in the constructor is checked
  against `address(0)`.
- **Reward insolvency** — `rewardReserve` is decremented before the transfer and
  checked first. If the accounting ever drifted, the function reverts with
  `SP__RewardInsolvency` rather than hitting a silent transfer failure.

### Not covered (honest caveats)

- **Malicious LP token** — the pool trusts the LP token to behave honestly. A
  token that returns `true` from `transfer` without moving tokens would corrupt
  the accounting. The assumption is that the LP token is the protocol's own
  contract, not an arbitrary third-party token.
- **Oracle downtime** — if the oracle reverts, `_updatePool` reverts too, halting
  all staking/unstaking/claiming until the oracle is fixed. This is intentional
  (fail loudly rather than silently miss rewards) but worth acknowledging.
- **MEV on rate changes** — a staker can front-run an oracle rate increase by
  staking in the same block the new rate takes effect. The accumulator handles
  this correctly (the new rate only applies to blocks after the checkpoint), but
  MEV searchers can still extract value from the rate delta.

---

## 10. Testing methodology

### Unit and fuzz tests (test/StakingPool.t.sol)

45 tests, organised into sections matching the contract's feature areas:

1. **Staking** — basic approve-and-stake, zero amount guard, missing approval,
   two independent users, ERC-1363 `transferAndCall` path
2. **Withdrawals** — request mechanics, cooldown enforcement, multisig flagging,
   double-flag prevention, successful execution after cooldown
3. **Rewards** — per-block accumulation, proportional split between stakers,
   dynamic oracle rate (without and with a pool checkpoint in between), standalone
   `claimRewards`, `pendingReward` view accuracy
4. **Admin** — `fundRewards`, `setOracle`, `setMultisig`, ownership guards on each
5. **Security and edge cases** — re-entrancy via malicious reward token,
   accumulator overflow guard, withdrawal ID overflow guard
6. **Fuzz tests** — parameterised stake amounts, withdraw amounts, multi-block
   reward accumulation with arbitrary block counts

Every test is fully self-contained. `setUp()` deploys a fresh set of contracts
for each test function. No state leaks between tests.

The re-entrancy test uses a `MaliciousRewardToken` that calls back into the pool
on `transfer`. It seeds `rewardReserve` directly via `vm.store` on slot 6 so it
doesn't need to go through the full `fundRewards` flow — this isolates the
re-entrancy precondition from the funding path.

### Stateful invariant suite (test/invariants/)

7 invariants, run for 500 sequences of 100 calls each (50,000 Handler invocations
total):

| ID | Invariant |
|----|-----------|
| I1 | `lpToken.balanceOf(pool) == totalStaked + totalPendingWithdrawals` |
| I2 | `totalStaked <= lpToken.balanceOf(pool)` |
| I3 | `rewardReserve <= rewardToken.balanceOf(pool)` |
| I4 | `accRewardPerShare` never decreases |
| I5 | No pending withdrawal is executable before its unlock time |
| I6 | Handler ghost variables match live pool state |
| I7 | All Handler action types were exercised (coverage check) |

The `Handler` contract wraps each pool action with `bound()` calls so the fuzzer
spends its sequences on interesting states rather than trivially-reverting inputs.
Ghost variables (`ghostTotalStaked`, `ghostTotalPending`) are updated in lockstep
with every pool call. If a bug causes the pool's internal counters to drift from
what actually happened, I6 catches it.

The `useActor(seed)` modifier picks a random actor from a fixed set of four
addresses and wraps the call in `vm.startPrank`/`vm.stopPrank`. This means the
fuzzer genuinely exercises concurrent multi-user states — two actors staking while
a third is in cooldown, for instance — rather than all calls coming from the same
address.

---

## 11. What I'd change for a real production deployment

**Timelock on admin functions.** `setOracle` and `setMultisig` take effect
immediately. In production these need at least a 48-hour on-chain timelock so
the community can observe and react before a change lands.

**Batched withdrawal execution.** Users with multiple pending requests call
`executeWithdrawal` once per request. A `executeWithdrawals(uint256[] calldata
ids)` would let them clear everything in one transaction and save significant
gas.

**Oracle rate smoothing.** The new rate applies from the very next `_updatePool`
call. A large rate increase is front-runnable — stake ahead of the oracle update,
capture the windfall, immediately withdraw. Interpolating between old and new
rates over N blocks would reduce this incentive without changing long-run emission.

**Emergency pause.** Currently the only way to halt the pool is to deploy a new
contract. A pause callable by the multisig — blocking new stakes but leaving
withdrawals open — would be a meaningful operational safety valve.

**Full invariant on `pendingReward` accuracy.** The invariant suite checks
internal counters but not that `pendingReward(user)` matches what the user
actually receives on claim. An invariant that snapshots `pendingReward`, calls
`claimRewards`, and checks the token balance delta would close that gap.

---

## 12. File layout

```
src/
  interfaces/
    IERC20.sol              minimal ERC-20 interface
    IERC1363.sol            ERC-1363 interface (transferAndCall, transferFromAndCall, approveAndCall)
    IERC1363Receiver.sol    callback interface implemented by the pool
    IRewardOracle.sol       single-function oracle interface
  tokens/
    ERC20Base.sol           hand-rolled ERC-20 (no OpenZeppelin)
    ERC1363Token.sol        ERC-1363 layer on top of ERC20Base
  oracle/
    MockRewardOracle.sol    static and variable-rate oracle used in tests
  StakingPool.sol           the main contract

test/
  mocks/
    MockLP.sol              ERC-1363 LP token with owner-only mint
    MockRewardToken.sol     plain ERC-20 reward token with owner-only mint
  invariants/
    Handler.sol             bounded actor contract for the fuzzer
    StakingInvariant.t.sol  the seven invariant functions
  StakingPool.t.sol         45 unit and fuzz tests
```
