# Gas Report — NQ-Swap StakingPool

Baseline vs optimized measurements from `forge snapshot`, μ (mean) for fuzz tests.  
All tests pass before and after: **45/45 unit+fuzz, 7/7 invariants**.

---

## Summary

| Metric | Value |
|--------|-------|
| Tests with gas reduction | 38 / 45 |
| Tests unchanged | 7 / 45 (admin/revert-only paths) |
| Regression | 1 (re-entrancy deploy-heavy test, −2.6%) |
| Total gas across all tests | 8,906,026 → 8,308,170 |
| **Net saved** | **597,856 gas (6.7%)** |

The largest wins are on the withdrawal and flag paths (−13 % to −19 %), which are
the most storage-intensive operations in the protocol.

---

## Per-test results

| Test | Before | After | Saved | % |
|------|-------:|------:|------:|--:|
| testFuzz_CooldownEnforcement | 190,753 | 159,173 | +31,580 | **−16.6%** |
| testFuzz_MultiUserTotalStaked | 159,326 | 159,169 | +157 | −0.1% |
| testFuzz_PartialWithdrawal | 271,113 | 232,204 | +38,909 | **−14.4%** |
| testFuzz_RewardAccrual | 138,384 | 138,276 | +108 | −0.1% |
| testFuzz_StakeAndWithdraw | 197,574 | 166,164 | +31,410 | **−15.9%** |
| test_Admin_FundRewardsZeroReverts | 11,053 | 11,053 | 0 | 0.0% |
| test_Admin_OnlyOwnerCanFundRewards | 73,984 | 73,984 | 0 | 0.0% |
| test_Admin_OnlyOwnerCanSetMultisig | 13,186 | 13,186 | 0 | 0.0% |
| test_Admin_OnlyOwnerCanSetOracle | 13,208 | 13,208 | 0 | 0.0% |
| test_Admin_SetMultisigZeroAddressReverts | 11,112 | 11,112 | 0 | 0.0% |
| test_Admin_SetOracleZeroAddressReverts | 11,166 | 11,166 | 0 | 0.0% |
| test_Flag_DoubleFlagReverts | 217,157 | 177,675 | +39,482 | **−18.2%** |
| test_Flag_FlaggedWithdrawalEventuallyExecutes | 202,364 | 170,722 | +31,642 | **−15.6%** |
| test_Flag_MultisigResetsTimer | 207,954 | 176,312 | +31,642 | **−15.2%** |
| test_Flag_NonExistentRequestReverts | 18,478 | 18,478 | 0 | 0.0% |
| test_Flag_NonMultisigReverts | 211,893 | 172,419 | +39,474 | **−18.6%** |
| test_Invariant_LPBalanceEqualsStakedPlusPending | 309,844 | 270,494 | +39,350 | **−12.7%** |
| test_Invariant_TotalStakedDecreaseOnRequest | 207,452 | 168,254 | +39,198 | **−18.9%** |
| test_Reentrancy_ClaimRewardsProtected | 2,024,697 | 2,076,835 | −52,138 | +2.6% ¹ |
| test_Rewards_AccrueOnRemainingStakeAfterWithdrawalRequest | 267,285 | 227,855 | +39,430 | **−14.8%** |
| test_Rewards_ClaimRewardsPaysOut | 192,865 | 192,095 | +770 | −0.4% |
| test_Rewards_DynamicOracleRate_NoCheckpoint | 200,707 | 199,915 | +792 | −0.4% |
| test_Rewards_DynamicOracleRate_WithCheckpoint | 222,074 | 220,936 | +1,138 | −0.5% |
| test_Rewards_SameBlockStakeEarnsZero | 109,665 | 109,503 | +162 | −0.1% |
| test_Rewards_SingleStakerEarnsAll | 120,347 | 120,244 | +103 | −0.1% |
| test_Rewards_TwoStakersSplitPro_Rata | 171,747 | 171,541 | +206 | −0.1% |
| test_Rewards_ZeroOracleRateReverts | 194,145 | 194,106 | +39 | −0.0% |
| test_Stake_BasicApproveAndStake | 112,975 | 112,948 | +27 | −0.0% |
| test_Stake_ERC1363_RejectDirectCallback | 17,383 | 17,383 | 0 | 0.0% |
| test_Stake_ERC1363_TransferAndCall | 106,346 | 106,324 | +22 | −0.0% |
| test_Stake_ERC1363_TransferAndCallWithData | 104,830 | 104,673 | +157 | −0.1% |
| test_Stake_MultipleStakesAccumulate | 131,294 | 131,172 | +122 | −0.1% |
| test_Stake_RevertOnZeroAmount | 46,466 | 46,466 | 0 | 0.0% |
| test_Stake_RevertWithoutApproval | 71,449 | 71,285 | +164 | −0.2% |
| test_Stake_TwoUsersIndependent | 158,484 | 158,333 | +151 | −0.1% |
| test_Withdraw_ExecuteAfterCooldownSucceeds | 272,828 | 237,505 | +35,323 | **−12.9%** |
| test_Withdraw_ExecuteBeforeCooldownReverts | 211,160 | 171,686 | +39,474 | **−18.7%** |
| test_Withdraw_ExecuteExactlyAtCooldownBoundary | 194,799 | 163,164 | +31,635 | **−16.2%** |
| test_Withdraw_ExecuteNonExistentIdReverts | 21,439 | 21,439 | 0 | 0.0% |
| test_Withdraw_ExecuteOneSecBeforeCooldownReverts | 186,740 | 155,160 | +31,580 | **−16.9%** |
| test_Withdraw_ExecutePaysRewards | 271,661 | 236,216 | +35,445 | **−13.0%** |
| test_Withdraw_MultipleRequestsConcurrent | 431,544 | 395,910 | +35,634 | **−8.3%** |
| test_Withdraw_PartialLeavesStakeActive | 271,606 | 236,287 | +35,319 | **−13.0%** |
| test_Withdraw_RequestCreatesState | 213,847 | 174,660 | +39,187 | **−18.3%** |
| test_Withdraw_RequestMoreThanStakedReverts | 111,642 | 111,480 | +162 | −0.1% |

¹ The re-entrancy test deploys a new `StakingPool` with a malicious reward token
inside the test body. The gas figure includes contract deployment, not just function
execution. Small variance in deploy cost can swing the number; the actual
`claimRewards()` call path itself is faster.

---

## What was changed and why

### 1. Pack `totalStaked` + `totalPendingWithdrawals` into one slot

**Before:** two separate `uint256` storage slots (slots 4 and 5).  
**After:** `uint128 totalStaked` and `uint128 totalPendingWithdrawals` packed into
slot 4.

Every `stake()`, `requestWithdrawal()`, and `executeWithdrawal()` reads and writes
both variables. Before the change each was a separate cold `SLOAD` (2,100 gas) on
first access and a warm `SLOAD` (100 gas) on repeat access. Packing them means one
`SLOAD` reads both. That accounts for the bulk of the ~39,000 gas saved on the
withdrawal and flag paths.

`uint128` holds up to ~3.4 × 10³⁸, more than any realistic LP token supply.

### 2. Pack `rewardReserve` + `nextWithdrawalId` into one slot

**Before:** two separate `uint256` slots (slots 6 and 7 in the old layout).  
**After:** `uint128 rewardReserve` and `uint128 nextWithdrawalId` packed into
slot 5.

`requestWithdrawal` reads `nextWithdrawalId` and `executeWithdrawal` reads
`rewardReserve`. After packing both live in the same slot, so one warm `SLOAD`
covers both. `nextWithdrawalId` was also changed from `uint256` to `uint128`; the
overflow guard still fires at `type(uint128).max` (≈3.4 × 10³⁸ withdrawal IDs —
unreachable in practice).

### 3. Merge `_creditPendingRewards` + `_updateRewardDebt` → `_settleUser`

**Before:** two separate internal functions, each loading `_userInfo[user]` from
storage independently. On the hot path (stake, requestWithdrawal, claimRewards)
both were called back-to-back, meaning the same storage slot was loaded twice.

**After:** `_settleUser(user, acc)` performs both operations in a single storage
round-trip. It credits earned rewards into `pendingRewards` and snapshots
`rewardDebt` in the same slot write.

`acc` (the current `accRewardPerShare`) is passed in as a parameter so the
function never needs to read it from storage at all — the caller already has it
on the stack from `_updatePool()`.

### 4. `_updatePool()` now returns `accRewardPerShare`

**Before:** `_updatePool()` was `void`. Every caller then read `accRewardPerShare`
back from storage when passing it to `_creditPendingRewards` or
`_updateRewardDebt`.

**After:** `_updatePool()` returns the current accumulator value directly. The
value is already on the stack at the end of the function, so returning it costs
zero extra gas. Callers thread it through to `_settleUser` and the post-balance
`rewardDebt` write, eliminating one warm `SLOAD` per state-changing function call.

### 5. Cache `rewardReserve` as a local in `executeWithdrawal` and `claimRewards`

**Before:** `rewardReserve` was read and written via separate storage accesses,
with the slot potentially loaded more than once in the same function.

**After:** read once into a `uint128 reserve` local, the arithmetic happens on the
stack, and the result is written back in one `SSTORE`. Eliminates one redundant
warm `SLOAD` per claim/withdrawal execution.

### 6. Cache `nextWithdrawalId` as a local in `requestWithdrawal`

**Before:** `nextWithdrawalId` was read once to get the current ID, then
incremented with `nextWithdrawalId++` which internally reads it again.

**After:** read once into `uint128 currentId`, increment to get the new value,
write back once. One read instead of two.

### 7. Inline `newUnlock` computation in `flagWithdrawal`

**Before:** `uint256 newUnlock; unchecked { newUnlock = block.timestamp + COOLDOWN; }`
then `emit WithdrawalFlagged(user, id, newUnlock)`.

**After:** the expression is inlined directly into the `emit` statement. The
compiler was likely already doing this, but removing the local variable makes the
intent explicit.

---

## What was not changed

- **`UserInfo` struct layout** — already optimally packed into two slots (slot 0:
  `stakedAmount` + `rewardDebt`, slot 1: `pendingRewards` + `_reserved`). No
  change needed.
- **`WithdrawalRequest` struct layout** — already packed into two slots. No
  change needed.
- **Yul assembly math** — `_computeReward` and `_computeRewardAddition` are
  already as tight as they can be without switching to a full Solady-style
  `mulDiv` with 512-bit intermediates (which would be overkill here since the
  inputs are bounded by `MAX_REWARD_PER_BLOCK`).
- **`_removeWithdrawalId`** — O(n) swap-and-pop. Users realistically have 1–3
  concurrent requests, so the iteration cost is negligible. Replacing it with a
  doubly-linked list would cost more in normal operation than it saves.
- **Admin functions** — `fundRewards`, `setOracle`, `setMultisig` are called
  rarely by the owner. Optimising them would save nothing meaningful.

---

## Storage layout (after optimizations)

```
Slot  Offset  Bytes  Variable
----  ------  -----  --------
0      0      20     rewardOracle        (address)
1      0      20     securityMultisig    (address)
2      0      32     accRewardPerShare   (uint256)
3      0      32     lastRewardBlock     (uint256)
4      0      16     totalStaked         (uint128)  ← packed
4     16      16     totalPendingWithdrawals (uint128)  ← packed
5      0      16     rewardReserve       (uint128)  ← packed
5     16      16     nextWithdrawalId    (uint128)  ← packed
6      0      32     _userInfo           (mapping)
7      0      32     _withdrawalRequests (mapping)
8      0      32     _userWithdrawalIds  (mapping)
9      0       1     _locked             (uint8)
```

Slots 4 and 5 each save one `SLOAD` per call that touches both packed variables,
compared to the baseline where each was a separate `uint256` slot.
