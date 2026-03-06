# THOUGHTS.md — NQ-Swap Staking Pool

Two questions drove every structural decision in this codebase. This document
answers both of them directly, with the actual tradeoffs made — not the ones that
sound good in retrospect.

---

## 1. Data structure choices — why mappings everywhere, and why not arrays

### User staking state — `mapping(address => UserInfo)` not a user array

The first question was whether to keep a list of all stakers. The answer is no,
and the reason is the reward accounting model itself.

The pool uses a MasterChef-style global accumulator: `accRewardPerShare` grows
monotonically every block and represents total rewards earned per LP token since
genesis. Each user stores one checkpoint value, `rewardDebt`, taken at their last
interaction. Their uncollected rewards at any moment are:

```
earned = (stakedAmount × accRewardPerShare / PRECISION) − rewardDebt
```

This is an O(1) calculation per user that requires no knowledge of any other
user. There is nothing to iterate. If you keep an array of stakers, you pay to
maintain that array — writing to it on every stake and removing from it on every
full withdrawal — and you never actually use it for anything that matters. The
mapping gives O(1) read and write per user, and the address is a natural key
because every staker is identified by their wallet.

The tradeoff with a mapping is that you lose enumeration. You cannot loop over
all stakers. That is not a tradeoff here — it is the goal. Any function that
loops over all stakers would hit the block gas limit as TVL grows and become
permanently unusable. The MasterChef accumulator was designed precisely to make
that loop unnecessary.

---

### Withdrawal requests — `mapping(address => mapping(uint256 => WithdrawalRequest))`

A user can have multiple concurrent withdrawal requests. The data structure needs
to support three operations efficiently:

1. **Create** a new request by ID — O(1), simple mapping write
2. **Look up** a specific request by `(user, id)` — O(1), direct nested mapping
   access
3. **Delete** a specific request after execution — O(1), `delete` on the mapping
   key

An array of `WithdrawalRequest` per user would make operation 2 and 3 O(n) —
you would need to scan the array to find the request by ID, then shift elements
to fill the gap after deletion. With a mapping, all three are constant time.

The cost of this choice is that mappings are not enumerable. To let users (and
front-ends) list their pending requests, a companion `_userWithdrawalIds` array
per user stores just the IDs. This array is append-only on request creation and
uses swap-and-pop on deletion. It is never read on any state-changing path —
only in view functions (`getUserWithdrawalIds`) and in `_removeWithdrawalId`
after the withdrawal has already been executed. The O(n) swap-and-pop there is
acceptable because users realistically have one or two concurrent requests, not
thousands.

---

### Packed structs — why the field order matters

`UserInfo` is laid out as:

```
Slot 0: stakedAmount (uint128) | rewardDebt (uint128)
Slot 1: pendingRewards (uint128) | _reserved (uint128)
```

`stakedAmount` and `rewardDebt` are always read and written together — every
stake, unstake, and claim touches both in the same function call. Packing them
into one slot means one `SLOAD` (100 gas warm, 2100 gas cold) covers both. If
they were separate `uint256` variables in separate slots, every hot-path function
would pay for two storage reads instead of one.

`WithdrawalRequest` packs `amount` (uint128), `requestTime` (uint64), `flagged`
(bool), and explicit padding into one slot, with `id` in the second. `_pad` is
written explicitly as `uint56` rather than left implicit so that the Solidity
compiler cannot silently reorder fields if the struct is ever extended. The layout
is documented in the source and verified with `forge inspect storageLayout`.

---

### Why `uint128` instead of `uint256` for token amounts

`uint128` holds up to approximately `3.4 × 10^38`. At 18 decimal places that is
`3.4 × 10^20` full tokens — more than the total supply of any realistic ERC-20.
Using `uint128` for `totalStaked`, `totalPendingWithdrawals`, `rewardReserve`,
and `nextWithdrawalId` allows two variables to share one 32-byte storage slot.
The explicit overflow guard (`if currentId == type(uint128).max`) and the Yul
`_add128`/`_sub128` helpers ensure the narrower type never silently wraps.

---

## 2. Re-entrancy mitigation — two defences, neither relying on OpenZeppelin

The contract has no inheritance from OpenZeppelin. The re-entrancy protection
is built from two independent mechanisms. They cover different attack surfaces
and are both necessary.

---

### Defence 1 — Checks-Effects-Interactions (CEI)

CEI is a code ordering discipline, not a library. The rule is: validate inputs
first, then update all state, then make external calls. If an external call
triggers a re-entrant callback, the callback reads already-zeroed state and has
nothing to steal.

In `executeWithdrawal`, the sequence is:

```solidity
// 1. Checks
WithdrawalRequest memory req = _withdrawalRequests[msg.sender][id];
if (req.amount == 0) revert SP__WithdrawalNotFound(...);
if (block.timestamp < unlockTime) revert SP__CooldownNotElapsed(...);

// 2. Effects — ALL state changes happen before any transfer
delete _withdrawalRequests[msg.sender][id];   // ← request gone
_removeWithdrawalId(msg.sender, id);
totalPendingWithdrawals = _sub128(...);
u.pendingRewards = 0;                          // ← rewards zeroed
rewardReserve = _sub128(...);                  // ← reserve decremented

// 3. Interactions — external calls last
IERC20(lpToken).transfer(msg.sender, lpAmount);
IERC20(rewardToken).transfer(msg.sender, rewardAmount);
```

If the reward token fires a callback on `transfer` that calls back into
`executeWithdrawal` for the same `id`, the re-entrant call finds
`req.amount == 0` and reverts immediately with `SP__WithdrawalNotFound`. If it
calls `claimRewards` instead, it finds `pendingRewards == 0` and returns
immediately. There is nothing left to take.

The same ordering is applied in `claimRewards`: `pendingRewards` is zeroed and
`rewardReserve` is decremented before `IERC20(rewardToken).transfer` is called.

---

### Defence 2 — Re-entrancy mutex (`uint8 _locked`)

A `uint8` storage variable, initialised to `1` (open) in the constructor. The
`nonReentrant` modifier sets it to `2` on entry and back to `1` on exit:

```solidity
modifier nonReentrant() {
    if (_locked == 2) revert SP__Locked();
    _locked = 2;
    _;
    _locked = 1;
}
```

Every public state-changing function (`stake`, `onTransferReceived`,
`requestWithdrawal`, `executeWithdrawal`, `claimRewards`) carries this modifier.
Any re-entrant call — regardless of which function it targets — hits `_locked == 2`
and reverts before touching any state.

`uint8` rather than `bool` for two reasons. First, `uint8` can be packed into
the same storage slot as adjacent variables (it sits in slot 9 alongside nothing
else here, but the principle matters for future extensions). Second, the
`1`/`2` encoding is more explicit about the two-state machine than `false`/`true`
and avoids the EVM's quirk where booleans sometimes occupy a full word in memory.

---

### Why both defences are necessary — they cover different threats

**CEI alone is not sufficient** because of `onTransferReceived`. This callback is
called by the LP token contract in the middle of a `transferAndCall`. At the
moment it fires, the tokens have already moved to the pool but the pool's
accounting (`stakedAmount`, `totalStaked`, `rewardDebt`) has not been updated
yet. CEI requires effects to happen before interactions — but here the interaction
(the callback) is the trigger for the effects. There is no way to apply CEI to
a callback that fires before your own code runs. The mutex is the only thing that
closes this window.

**The mutex alone is not sufficient** because it only blocks a second entry into
a `nonReentrant` function. It cannot prevent cross-function re-entrancy through
`flagWithdrawal` (which does not carry `nonReentrant` since it is multisig-only
and makes no external calls). More broadly, relying solely on the mutex means a
single missed `nonReentrant` annotation on any future function would open a
re-entrancy hole. CEI provides a defence-in-depth layer that protects even
functions without the modifier.

---

### The `msg.sender == lpToken` guard — re-entrancy via fake callbacks

There is a third re-entrancy-adjacent attack that neither CEI nor the mutex
directly addresses: calling `onTransferReceived` directly, without any actual
token transfer, to credit a fraudulent stake.

```solidity
function onTransferReceived(
    address,
    address from,
    uint256 amount,
    bytes calldata
) external override nonReentrant returns (bytes4) {
    if (msg.sender != lpToken) revert SP__NotLPToken(msg.sender);
    ...
}
```

The `msg.sender` check is the guard. When `transferAndCall` is called on the LP
token, the LP token contract is the one that invokes `onTransferReceived`, so
`msg.sender` is the LP token's address. A direct call from any other address —
an attacker's EOA, a different contract, a malicious router — has a different
`msg.sender` and reverts immediately. Without this check, an attacker could call
`onTransferReceived(attacker, attacker, 1_000_000e18, "")` directly and receive
a million-token stake credit backed by zero actual tokens.

---

### Summary of re-entrancy coverage

| Threat | Covered by |
|---|---|
| Re-entrant call to `executeWithdrawal` or `claimRewards` from a malicious token's `transfer` callback | CEI (state is zeroed before transfer) + mutex (re-entry blocked) |
| Re-entrant call to `stake` or `requestWithdrawal` from a malicious LP token's `transferAndCall` callback | Mutex (fires before any accounting update) |
| Direct call to `onTransferReceived` with no real token transfer | `msg.sender == lpToken` guard |
| Cross-function re-entrancy through a function without `nonReentrant` | CEI (state is consistent before any external call) |
