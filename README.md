# NQ-Swap Staking Pool

A production-quality, decentralised staking and liquidity-mining protocol written in Solidity 0.8.24 with **zero OpenZeppelin dependencies**. Built as a Smart Contract Engineer skill assessment.

Users deposit ERC-1363 LP tokens, earn dynamically-priced reward tokens, and withdraw after a mandatory 2-day cooldown — during which a security multisig can flag suspicious activity and reset the timer.

---

## Table of Contents

1. [What the protocol does](#what-the-protocol-does)
2. [Architecture overview](#architecture-overview)
3. [Contract reference](#contract-reference)
4. [Storage layout](#storage-layout)
5. [Security model](#security-model)
6. [How to build, test, and report gas](#how-to-build-test-and-report-gas)
7. [Deployment notes](#deployment-notes)
8. [Further reading](#further-reading)

---

## What the protocol does

NQ-Swap follows the canonical MasterChef liquidity-mining pattern, extended with a security-first withdrawal flow:

1. **Stake** — a user calls `stake(amount)` (approve+call) or uses the single-transaction path `lpToken.transferAndCall(pool, amount)` (ERC-1363). Their LP tokens are locked in the pool and they begin earning rewards immediately.

2. **Earn** — a global accumulator `accRewardPerShare` tracks cumulative reward tokens earned per unit of staked LP token since deployment. The pool queries a pluggable `IRewardOracle` every time the accumulator is updated, so the emission rate can change without touching the pool contract.

3. **Request withdrawal** — `requestWithdrawal(amount)` moves the nominated LP tokens out of the earning set and queues a `WithdrawalRequest`. Any rewards earned up to that moment are credited into the user's `pendingRewards` balance. The 2-day cooldown clock starts.

4. **Claim rewards** — `claimRewards()` pays out `pendingRewards` at any time, independent of any withdrawal.

5. **Execute withdrawal** — once the cooldown expires, `executeWithdrawal(id)` returns the LP tokens and any remaining pending rewards in one transaction. State is fully cleared before any token transfer (CEI order + re-entrancy mutex).

6. **Flag** — the security multisig can call `flagWithdrawal(user, id)` to reset the cooldown on a suspicious request. The multisig **cannot** cancel or seize tokens — it can only delay.

---

## Architecture overview

```
┌──────────────────────────────────────────────────────────┐
│                        User                              │
│  stake() / transferAndCall()  requestWithdrawal()        │
│  claimRewards()               executeWithdrawal()        │
└─────────────────────┬────────────────────────────────────┘
                      │
                      ▼
┌──────────────────────────────────────────────────────────┐
│                    StakingPool                           │
│                                                          │
│  • MasterChef accumulator (accRewardPerShare)            │
│  • Two-step withdrawal with 2-day cooldown               │
│  • ERC-1363 onTransferReceived callback                  │
│  • Re-entrancy mutex (nonReentrant) + CEI ordering       │
│  • Yul muldiv with overflow protection                   │
│  • Packed storage slots (uint128 pairs)                  │
│                                                          │
└────────────┬──────────────────────────┬──────────────────┘
             │                          │
             ▼                          ▼
   ┌──────────────────┐      ┌──────────────────────┐
   │  IRewardOracle   │      │  Security Multisig   │
   │  rewardPerBlock()│      │  flagWithdrawal()    │
   └──────────────────┘      └──────────────────────┘
             │
             ▼
   ┌──────────────────┐      ┌──────────────────────┐
   │  LP Token        │      │  Reward Token        │
   │  (ERC-1363)      │      │  (ERC-20)            │
   └──────────────────┘      └──────────────────────┘
```

### Directory layout

```
src/
├── StakingPool.sol             # Core protocol contract
├── interfaces/
│   ├── IERC20.sol              # Minimal ERC-20 interface
│   ├── IERC1363.sol            # ERC-1363 transferAndCall interface
│   ├── IERC1363Receiver.sol    # onTransferReceived callback interface
│   └── IRewardOracle.sol       # rewardPerBlock() oracle interface
├── tokens/
│   ├── ERC20Base.sol           # Hand-rolled ERC-20 implementation
│   └── ERC1363Token.sol        # ERC-1363 extension layer
└── oracle/
    └── MockRewardOracle.sol    # Static and variable-rate test oracle

test/
├── StakingPool.t.sol           # 45 unit + fuzz tests
├── mocks/
│   ├── MockLP.sol              # ERC-1363 LP token (owner-mintable)
│   └── MockRewardToken.sol     # Plain ERC-20 reward token
└── invariants/
    ├── Handler.sol             # Bounded actor for stateful fuzzer
    └── StakingInvariant.t.sol  # 7 invariant assertions

thoughts.md                     # Full engineering design document
GAS_REPORT.md                   # Before/after gas measurements
```

---

## Contract reference

### `StakingPool`

The only stateful contract in the system. Implements `IERC1363Receiver`.

| Function | Access | Description |
|---|---|---|
| `stake(uint256)` | public | Approve-then-stake LP tokens |
| `onTransferReceived(address,address,uint256,bytes)` | LP token only | ERC-1363 single-tx stake |
| `requestWithdrawal(uint256)` | public | Queue a withdrawal, starts cooldown |
| `executeWithdrawal(uint256)` | public | Finalise after cooldown expires |
| `claimRewards()` | public | Claim pending rewards without unstaking |
| `flagWithdrawal(address,uint256)` | multisig only | Reset cooldown on a suspicious request |
| `fundRewards(uint256)` | owner only | Deposit reward tokens into the pool |
| `setOracle(address)` | owner only | Replace the reward oracle |
| `setMultisig(address)` | owner only | Replace the security multisig |
| `pendingReward(address)` | view | Off-chain reward estimate for a user |
| `userInfo(address)` | view | User's staked amount, debt, pending rewards |
| `getWithdrawalRequest(address,uint256)` | view | Full details of a withdrawal request |
| `getUserWithdrawalIds(address)` | view | All active withdrawal IDs for a user |
| `withdrawalUnlockTime(address,uint256)` | view | Timestamp when a request becomes executable |

**Constructor parameters:**

```solidity
constructor(
    address _lpToken,          // ERC-1363 LP token
    address _rewardToken,      // ERC-20 reward token
    address _rewardOracle,     // IRewardOracle implementation
    address _securityMultisig  // address with flagWithdrawal power
)
```

**Key constants:**

| Constant | Value | Purpose |
|---|---|---|
| `PRECISION` | `1e18` | Accumulator scaling factor |
| `COOLDOWN` | `172800` (2 days) | Minimum withdrawal wait |
| `MAX_REWARD_PER_BLOCK` | `1e24` | Oracle rate hard cap |

**Custom errors** (gas-efficient, no string reasons):

`SP__ZeroAmount`, `SP__ZeroRewardRate`, `SP__RewardRateTooHigh`, `SP__InsufficientStake`, `SP__WithdrawalNotFound`, `SP__CooldownNotElapsed`, `SP__OnlyMultisig`, `SP__WithdrawalAlreadyFlagged`, `SP__RewardInsolvency`, `SP__Locked`, `SP__WithdrawalIdOverflow`, `SP__InvalidLPToken`, `SP__NotLPToken`, `SP__MulOverflow`, `SP__ZeroAddress`, `SP__FundingFailed`, `SP__OnlyOwner`

---

### `ERC1363Token` / `ERC20Base`

Hand-rolled ERC-20 + ERC-1363 implementation. No external dependencies. Used as the base for `MockLP` in tests. In a production deployment the LP token would come from an AMM (e.g. Uniswap v2 pair) and the reward token would be a standard ERC-20 — these implementations are provided to satisfy the "no OpenZeppelin" requirement and to make the test suite fully self-contained.

### `MockRewardOracle`

Implements `IRewardOracle`. Supports a fixed rate (set at construction) and a variable rate that the test suite can override mid-run via `setRate(uint256)`. Replace with a Chainlink-backed or governance-controlled oracle before mainnet.

---

## Storage layout

`StakingPool` storage after all gas optimisations (verified with `forge inspect StakingPool storageLayout`):

| Slot | Variable(s) | Type | Notes |
|---|---|---|---|
| 0 | `rewardOracle` | `address` | Mutable, owner-only |
| 1 | `securityMultisig` | `address` | Mutable, owner-only |
| 2 | `accRewardPerShare` | `uint256` | Monotonically increasing |
| 3 | `lastRewardBlock` | `uint256` | Updated every pool checkpoint |
| 4 | `totalStaked` \| `totalPendingWithdrawals` | `uint128` \| `uint128` | **Packed** — one SLOAD covers both |
| 5 | `rewardReserve` \| `nextWithdrawalId` | `uint128` \| `uint128` | **Packed** — one SLOAD covers both |
| 6 | `_userInfo` | `mapping(address => UserInfo)` | |
| 7 | `_withdrawalRequests` | `mapping(address => mapping(uint256 => WithdrawalRequest))` | |
| 8 | `_userWithdrawalIds` | `mapping(address => uint256[])` | Enumeration index only |
| 9 | `_locked` | `uint8` | Re-entrancy mutex (1=open, 2=locked) |

`UserInfo` (two packed slots per user):

```
Slot 0: stakedAmount (uint128) | rewardDebt (uint128)
Slot 1: pendingRewards (uint128) | _reserved (uint128)
```

`WithdrawalRequest` (two packed slots per request):

```
Slot 0: amount (uint128) | requestTime (uint64) | flagged (bool) | _pad (uint56)
Slot 1: id (uint256)
```

---

## Security model

### Re-entrancy

Two layers of protection, neither relying on the other:

1. **CEI (Checks-Effects-Interactions)** — all state is zeroed and all arithmetic is finalised before any external `transfer` call. Even if the mutex were absent a re-entrant call would read zeroed state and have nothing to steal.

2. **`nonReentrant` mutex** — a `uint8` flag (1=open, 2=locked) blocks every re-entrant entry. `uint8` rather than `bool` because the compiler stores booleans as a full 32-byte word in some contexts; `uint8` packs more predictably.

### Oracle rate manipulation

`_updatePool` caps the oracle return value at `MAX_REWARD_PER_BLOCK = 1e24`. A compromised oracle returning `type(uint256).max` triggers `SP__RewardRateTooHigh` and the pool freezes rather than silently overflows. The oracle also cannot return zero (triggers `SP__ZeroRewardRate`) to prevent a griefing vector where the pool appears live but pays nothing.

### Fake ERC-1363 callbacks

`onTransferReceived` checks `msg.sender == lpToken`. Any direct call to this function from an address other than the registered LP token reverts with `SP__NotLPToken`. This prevents an attacker from crediting stakes backed by no real tokens.

### Accumulator overflow

`_computeReward` and `_computeRewardAddition` are implemented in Yul. The overflow check is explicit: `if b > maxUint / a → revert`. This is the standard muldiv overflow guard, written in assembly to avoid redundant checks on this hot path while keeping the semantics of 0.8.x checked arithmetic everywhere else.

### Withdrawal replay

`executeWithdrawal` deletes the `WithdrawalRequest` record from `_withdrawalRequests` and removes the ID from `_userWithdrawalIds` **before** any `transfer` calls. A second call on the same ID finds `req.amount == 0` and reverts with `SP__WithdrawalNotFound`.

### Multisig power boundary

The security multisig can:
- Call `flagWithdrawal` to reset a pending withdrawal's cooldown clock
- Call it only once per request (the `flagged` bit prevents double-flagging)

The multisig **cannot**:
- Cancel or seize any user's funds
- Change any protocol parameter
- Prevent a withdrawal from ever executing — it can only delay by one additional `COOLDOWN` period

### Reward insolvency guard

`claimRewards` and `executeWithdrawal` both check `pending <= rewardReserve` before transferring. If the accounting ever drifts (e.g. due to a direct `transfer` to the contract not going through `fundRewards`), the transaction reverts with `SP__RewardInsolvency` rather than silently paying from tokens it doesn't own.

---

## How to build, test, and report gas

**Prerequisites:** [Foundry](https://book.getfoundry.sh/getting-started/installation) installed and on `$PATH`.

### Build

```shell
forge build
```

Compiles all contracts under `src/` and `test/` with the Solidity 0.8.24 compiler, optimizer enabled at 200 runs.

### Run the full test suite

```shell
forge test -vv
```

Expected output: **52 tests passing** (45 unit+fuzz, 7 invariants), 0 failures.

To see per-test gas in the terminal:

```shell
forge test -vv --gas-report
```

To run only the unit/fuzz suite:

```shell
forge test --match-path test/StakingPool.t.sol -vv
```

To run only the invariant suite:

```shell
forge test --match-path test/invariants/StakingInvariant.t.sol -vv
```

To run a single test by name:

```shell
forge test --match-test testFuzz_PartialWithdrawal -vvv
```

### Fuzz configuration

Fuzz runs and invariant depth are configured in `foundry.toml`:

```toml
[profile.default.fuzz]
runs   = 1000
seed   = "0xdeadbeef"

[profile.default.invariant]
runs  = 500
depth = 100
```

Increase `runs` for a more thorough campaign before deploying.

### Gas snapshot

```shell
# Take a fresh snapshot (writes to .gas-snapshot)
forge snapshot

# Compare against the checked-in optimised baseline
forge snapshot --diff .gas-snapshot-optimized
```

A positive diff means a regression; a negative diff means additional savings. The checked-in `.gas-snapshot-optimized` reflects the state after all optimisations described in `GAS_REPORT.md`.

### Inspect storage layout

```shell
forge inspect StakingPool storageLayout
```

Use this to verify the packed slot assignments match the table in this README after any future changes to the state variable declarations.

### Format

```shell
forge fmt
```

---

## Deployment notes

This project does not ship a deploy script — the assessment scope is the protocol contracts and their tests. The following notes apply to any real deployment:

1. **Deploy order:** `ERC1363Token` (LP) → reward token → oracle → `StakingPool`.

2. **Fund the pool:** After deployment the owner must call `rewardToken.approve(pool, amount)` then `pool.fundRewards(amount)` before any rewards can be paid. The pool reverts with `SP__RewardInsolvency` on any claim until funded.

3. **Oracle:** Replace `MockRewardOracle` with a governance-controlled or Chainlink-backed implementation before mainnet. The interface is a single function: `function rewardPerBlock() external view returns (uint256)`.

4. **Multisig:** Set `_securityMultisig` to a real Gnosis Safe or equivalent. Rotatable at any time by the owner via `setMultisig(address)`.

5. **Immutables:** `lpToken`, `rewardToken`, and `owner` are set at construction and **cannot be changed**. Choose them carefully.

6. **No upgradability:** The pool is intentionally non-upgradeable. If a critical bug is found, deploy a new pool and migrate liquidity. The simplicity trades off flexibility for a smaller attack surface.

7. **Production gaps (known):** See `thoughts.md` §12 for an explicit list of features intentionally excluded from this assessment scope (fee-on-transfer token handling, multiple reward tokens, governance, emergency pause, etc.).

---

## Further reading

| Document | Contents |
|---|---|
| [`thoughts.md`](./thoughts.md) | Full engineering design document: pre-code threat modelling, data structure decisions, re-entrancy rationale, accumulator mechanics, Yul assembly explanation, testing methodology, known production gaps |
| [`GAS_REPORT.md`](./GAS_REPORT.md) | Per-test before/after gas table, explanation of each optimisation, storage layout diagram, net savings summary (−6.7%, 597,856 gas) |

---

## Test coverage summary

| Suite | Tests | Status |
|---|---|---|
| Unit + fuzz (`StakingPool.t.sol`) | 45 | ✅ All passing |
| Invariant (`StakingInvariant.t.sol`) | 7 | ✅ All passing |
| **Total** | **52** | ✅ |

**Invariants verified:**

| ID | Assertion |
|---|---|
| I1 | `lpToken.balanceOf(pool) == totalStaked + totalPendingWithdrawals` |
| I2 | `totalStaked <= lpToken.balanceOf(pool)` |
| I3 | `rewardReserve <= rewardToken.balanceOf(pool)` |
| I4 | `accRewardPerShare` never decreases |
| I5 | No pending withdrawal is executable before its unlock time |
| I6 | Handler ghost variables match pool live state |
| I7 | `nextWithdrawalId` only increases |
