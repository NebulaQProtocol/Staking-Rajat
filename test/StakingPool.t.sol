// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {StakingPool}       from "../src/StakingPool.sol";
import {MockRewardOracle}  from "../src/oracle/MockRewardOracle.sol";
import {MockLP}            from "./mocks/MockLP.sol";
import {MockRewardToken}   from "./mocks/MockRewardToken.sol";

// Unit + fuzz test suite for StakingPool.
//
// Each test is fully self-contained — setUp() deploys fresh contracts so
// state never leaks between tests. Fuzz tests run 1001 rounds each by
// default (configured in foundry.toml).
contract StakingPoolTest is Test {

    uint256 constant COOLDOWN     = 2 days;
    uint256 constant INITIAL_RATE = 100e18;       // 100 tokens per block
    uint256 constant REWARD_FUND  = 1_000_000e18; // 1M reward tokens pre-funded into the pool
    uint256 constant INITIAL_MINT = 10_000e18;    // LP tokens minted to each test actor

    address owner    = makeAddr("owner");
    address alice    = makeAddr("alice");
    address bob      = makeAddr("bob");
    address multisig = makeAddr("multisig");
    address attacker = makeAddr("attacker");

    MockLP           lp;
    MockRewardToken  reward;
    MockRewardOracle oracle;
    StakingPool      pool;

    function setUp() public {
        vm.startPrank(owner);

        lp     = new MockLP("NQSwap LP", "NQ-LP");
        reward = new MockRewardToken("NQSwap Reward", "NQR");
        oracle = new MockRewardOracle(INITIAL_RATE);

        pool = new StakingPool(
            address(lp),
            address(reward),
            address(oracle),
            multisig
        );

        reward.mint(owner, REWARD_FUND);
        reward.approve(address(pool), REWARD_FUND);
        pool.fundRewards(REWARD_FUND);

        vm.stopPrank();

        // MockLP.mint is restricted to the deployer (owner), so prank here.
        vm.startPrank(owner);
        lp.mint(alice,    INITIAL_MINT);
        lp.mint(bob,      INITIAL_MINT);
        lp.mint(attacker, INITIAL_MINT);
        vm.stopPrank();
    }

    // =========================================================================
    // Section 1: Staking
    // =========================================================================

    // Basic flow: approve then stake.
    function test_Stake_BasicApproveAndStake() public {
        uint256 amount = 1_000e18;

        vm.startPrank(alice);
        lp.approve(address(pool), amount);
        pool.stake(amount);
        vm.stopPrank();

        (uint128 staked,,) = pool.userInfo(alice);
        assertEq(staked, amount, "staked amount mismatch");
        assertEq(pool.totalStaked(), amount, "totalStaked mismatch");
        assertEq(lp.balanceOf(address(pool)), amount, "pool LP balance mismatch");
        assertEq(lp.balanceOf(alice), INITIAL_MINT - amount, "alice LP balance mismatch");
    }

    // Staking zero should always revert — there's no point accepting a no-op.
    function test_Stake_RevertOnZeroAmount() public {
        vm.startPrank(alice);
        lp.approve(address(pool), 1e18);
        vm.expectRevert(StakingPool.SP__ZeroAmount.selector);
        pool.stake(0);
        vm.stopPrank();
    }

    // If the user forgot to approve, transferFrom reverts inside the pool.
    function test_Stake_RevertWithoutApproval() public {
        vm.prank(alice);
        vm.expectRevert();
        pool.stake(1_000e18);
    }

    // Two users staking independently shouldn't interfere with each other.
    function test_Stake_TwoUsersIndependent() public {
        _stake(alice, 1_000e18);
        _stake(bob,   2_000e18);

        (uint128 aliceStaked,,) = pool.userInfo(alice);
        (uint128 bobStaked,,)   = pool.userInfo(bob);

        assertEq(aliceStaked, 1_000e18);
        assertEq(bobStaked,   2_000e18);
        assertEq(pool.totalStaked(), 3_000e18);
    }

    // ERC-1363 lets users stake in a single transaction: transferAndCall
    // moves the tokens AND triggers onTransferReceived all at once.
    function test_Stake_ERC1363_TransferAndCall() public {
        uint256 amount = 500e18;

        vm.prank(alice);
        lp.transferAndCall(address(pool), amount);

        (uint128 staked,,) = pool.userInfo(alice);
        assertEq(staked, amount, "ERC-1363 stake not recorded");
        assertEq(pool.totalStaked(), amount);
        assertEq(lp.balanceOf(address(pool)), amount);
    }

    // transferAndCall with extra bytes should work the same — the pool
    // ignores the data payload.
    function test_Stake_ERC1363_TransferAndCallWithData() public {
        uint256 amount = 300e18;

        vm.prank(bob);
        lp.transferAndCall(address(pool), amount, bytes("some data"));

        (uint128 staked,,) = pool.userInfo(bob);
        assertEq(staked, amount);
    }

    // An attacker can call onTransferReceived directly. Without the
    // msg.sender == lpToken check they could fake a stake for free.
    function test_Stake_ERC1363_RejectDirectCallback() public {
        // Attacker tries to fake a stake by calling the callback directly.
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(StakingPool.SP__NotLPToken.selector, attacker));
        pool.onTransferReceived(attacker, attacker, 1_000e18, "");
    }

    // Staking twice should sum, not replace.
    function test_Stake_MultipleStakesAccumulate() public {
        _stake(alice, 500e18);
        _stake(alice, 500e18);

        (uint128 staked,,) = pool.userInfo(alice);
        assertEq(staked, 1_000e18);
        assertEq(pool.totalStaked(), 1_000e18);
    }

    // =========================================================================
    // Section 2: Reward accounting
    // =========================================================================

    // When there's only one staker they should receive 100% of emissions.
    function test_Rewards_SingleStakerEarnsAll() public {
        uint256 stakeAmount = 1_000e18;
        _stake(alice, stakeAmount);

        // Advance 10 blocks at INITIAL_RATE (100e18 / block).
        vm.roll(block.number + 10);

        uint256 pending = pool.pendingReward(alice);
        uint256 expected = 10 * INITIAL_RATE; // 1000e18
        assertEq(pending, expected, "single staker reward mismatch");
    }

    // 1000 vs 3000 staked → 25%/75% split.
    function test_Rewards_TwoStakersSplitPro_Rata() public {
        // Alice stakes 1000, Bob stakes 3000 → 25%/75% split.
        _stake(alice, 1_000e18);
        _stake(bob,   3_000e18);

        vm.roll(block.number + 100);

        uint256 alicePending = pool.pendingReward(alice);
        uint256 bobPending   = pool.pendingReward(bob);
        uint256 totalReward  = 100 * INITIAL_RATE;

        // Alice: 25%, Bob: 75%
        assertApproxEqRel(alicePending, totalReward / 4,     1e15, "alice share wrong"); // 0.1% tolerance
        assertApproxEqRel(bobPending,   totalReward * 3 / 4, 1e15, "bob share wrong");
    }

    // The pool only distributes rewards for blocks that have already passed.
    // Staking and checking pending in the same block should return zero.
    function test_Rewards_SameBlockStakeEarnsZero() public {
        _stake(alice, 1_000e18);
        // No block advancement — still on the block of the stake.
        uint256 pending = pool.pendingReward(alice);
        assertEq(pending, 0, "same-block stake should earn zero");
    }

    // After claiming, pendingReward should be zero. If it isn't, the debt
    // checkpoint wasn't updated correctly and the user could claim twice.
    function test_Rewards_ClaimRewardsPaysOut() public {
        _stake(alice, 1_000e18);
        vm.roll(block.number + 10);

        uint256 expectedReward = 10 * INITIAL_RATE;
        uint256 rewardBefore   = reward.balanceOf(alice);

        vm.prank(alice);
        pool.claimRewards();

        uint256 rewardAfter = reward.balanceOf(alice);
        assertEq(rewardAfter - rewardBefore, expectedReward, "reward payout mismatch");

        // Pending should now be zero.
        assertEq(pool.pendingReward(alice), 0, "pending should be 0 after claim");
    }

    // ─── 2.5 Dynamic oracle rate changes mid-stream ───────────────────────
    //
    //  Design note: StakingPool uses a single global accumulator that is
    //  updated lazily — it fetches the *current* oracle rate at update time
    //  and applies it to all blocks since the last checkpoint.  This means
    //  that if the oracle rate changes between two checkpoints, the NEW rate
    //  is retroactively applied to the entire un-checkpointed window.
    //
    //  The correct way to apply two distinct rates is to force a pool
    //  checkpoint (via claimRewards / stake / requestWithdrawal) BEFORE
    //  changing the oracle rate.  This test validates both behaviours:
    //  (a) rate-change without checkpoint → new rate applied to full window
    //  (b) rate-change after checkpoint   → each segment uses its own rate

    function test_Rewards_DynamicOracleRate_NoCheckpoint() public {
        // Without an intermediate checkpoint, the new rate is applied to
        // the full 10-block window when the pool is finally updated.
        _stake(alice, 1_000e18);

        // 5 blocks elapse — no checkpoint yet.
        vm.roll(block.number + 5);

        // Change oracle rate to 200e18 WITHOUT forcing a checkpoint.
        vm.prank(owner);
        oracle.setRate(200e18);

        // 5 more blocks.
        vm.roll(block.number + 5);

        // Claim forces _updatePool: it sees 10 blocks at current rate 200e18.
        uint256 before = reward.balanceOf(alice);
        vm.prank(alice);
        pool.claimRewards();

        uint256 earned   = reward.balanceOf(alice) - before;
        uint256 expected = 10 * 200e18; // 2000e18 — new rate applied to full window
        assertEq(earned, expected, "no-checkpoint: new rate must cover full window");
    }

    function test_Rewards_DynamicOracleRate_WithCheckpoint() public {
        // If you checkpoint (claim) before changing the oracle rate, each
        // segment of blocks is settled at the rate that was active at the
        // time of that checkpoint. This is the intended usage.
        _stake(alice, 1_000e18);

        vm.roll(block.number + 5);
        vm.prank(alice);
        pool.claimRewards(); // settles the first 5 blocks at 100e18

        uint256 firstClaim = reward.balanceOf(alice);
        assertEq(firstClaim, 5 * 100e18, "first segment mismatch");

        vm.prank(owner);
        oracle.setRate(200e18);

        vm.roll(block.number + 5);

        uint256 before = reward.balanceOf(alice);
        vm.prank(alice);
        pool.claimRewards();

        uint256 secondEarned = reward.balanceOf(alice) - before;
        assertEq(secondEarned, 5 * 200e18, "second segment: must use new rate");
    }

    // Deploying a zero-returning oracle and wiring it to the pool should
    // cause the next pool update to revert.
    function test_Rewards_ZeroOracleRateReverts() public {
        _stake(alice, 1_000e18);
        vm.roll(block.number + 1);

        // Set oracle to 0 — should trigger revert when pool update is called.
        vm.prank(owner);
        oracle.setRate(1); // Can't set 0 via setRate (oracle enforces), so we deploy a new zero oracle.

        // Deploy a custom zero-rate oracle directly.
        ZeroOracle zeroOracle = new ZeroOracle();
        vm.prank(owner);
        pool.setOracle(address(zeroOracle));

        vm.roll(block.number + 1);

        vm.prank(alice);
        vm.expectRevert(StakingPool.SP__ZeroRewardRate.selector);
        pool.claimRewards();
    }

    // Once you request a partial withdrawal, the unstaked tokens stop earning.
    // This checks that the remaining stake keeps accruing normally.
    function test_Rewards_AccrueOnRemainingStakeAfterWithdrawalRequest() public {
        _stake(alice, 2_000e18);
        vm.roll(block.number + 5);

        vm.prank(alice);
        pool.requestWithdrawal(1_000e18);

        vm.roll(block.number + 5);

        uint256 pending = pool.pendingReward(alice);
        // 5 blocks sole staker at 1000e18 each = 500e18 earned (sole staker,
        // so alice gets 100% of 100e18/block). Then 1000e18 staked for 5 more
        // blocks = another 500e18. Total ~1000e18.
        assertApproxEqRel(pending, 1_000e18, 1e15);
    }

    // =========================================================================
    // Section 3: Withdrawal cooldown
    // =========================================================================

    // Requesting a withdrawal should immediately reduce staked balance and
    // create a withdrawal record.
    function test_Withdraw_RequestCreatesState() public {
        _stake(alice, 1_000e18);

        vm.prank(alice);
        uint256 id = pool.requestWithdrawal(400e18);

        StakingPool.WithdrawalRequest memory req = pool.getWithdrawalRequest(alice, id);
        assertEq(req.amount, 400e18);
        assertEq(req.flagged, false);

        (uint128 staked,,) = pool.userInfo(alice);
        assertEq(staked, 600e18, "staked should decrease at request time");
        assertEq(pool.totalStaked(), 600e18);
        assertEq(pool.totalPendingWithdrawals(), 400e18);
    }

    // Trying to execute immediately (cooldown not elapsed) must revert.
    function test_Withdraw_ExecuteBeforeCooldownReverts() public {
        _stake(alice, 1_000e18);
        vm.prank(alice);
        uint256 id = pool.requestWithdrawal(500e18);

        // Try immediately — should revert.
        vm.prank(alice);
        vm.expectRevert(); // SP__CooldownNotElapsed
        pool.executeWithdrawal(id);
    }

    // The normal happy path: request, wait 2 days, execute, get LP back.
    function test_Withdraw_ExecuteAfterCooldownSucceeds() public {
        uint256 amount = 1_000e18;
        _stake(alice, amount);
        vm.roll(block.number + 1);

        vm.prank(alice);
        uint256 id = pool.requestWithdrawal(amount);

        // Warp past cooldown.
        vm.warp(block.timestamp + COOLDOWN + 1);

        uint256 lpBefore = lp.balanceOf(alice);

        vm.prank(alice);
        pool.executeWithdrawal(id);

        assertEq(lp.balanceOf(alice), lpBefore + amount, "LP not returned");
        assertEq(pool.totalPendingWithdrawals(), 0);

        // Withdrawal request should be deleted.
        StakingPool.WithdrawalRequest memory req = pool.getWithdrawalRequest(alice, id);
        assertEq(req.amount, 0, "request not cleared");
    }

    // executeWithdrawal also flushes any pending rewards into the user's wallet.
    function test_Withdraw_ExecutePaysRewards() public {
        _stake(alice, 1_000e18);
        vm.roll(block.number + 10);

        vm.prank(alice);
        uint256 id = pool.requestWithdrawal(1_000e18);

        vm.warp(block.timestamp + COOLDOWN + 1);

        uint256 rewardBefore = reward.balanceOf(alice);

        vm.prank(alice);
        pool.executeWithdrawal(id);

        uint256 earned = reward.balanceOf(alice) - rewardBefore;
        assertGt(earned, 0, "should receive rewards on withdrawal execution");
    }

    // Withdrawing part of a position should leave the rest earning normally.
    function test_Withdraw_PartialLeavesStakeActive() public {
        _stake(alice, 2_000e18);
        vm.roll(block.number + 5);

        vm.prank(alice);
        uint256 id = pool.requestWithdrawal(1_000e18);

        (uint128 staked,,) = pool.userInfo(alice);
        assertEq(staked, 1_000e18, "remaining staked should be 1000");

        // Execute partial withdrawal.
        vm.warp(block.timestamp + COOLDOWN + 1);
        vm.prank(alice);
        pool.executeWithdrawal(id);

        // Alice still has 1000 staked.
        (uint128 stakedAfter,,) = pool.userInfo(alice);
        assertEq(stakedAfter, 1_000e18);
        assertEq(pool.totalStaked(), 1_000e18);
    }

    // Users can have multiple withdrawal requests in flight at once. Each gets
    // its own ID and can be executed independently.
    function test_Withdraw_MultipleRequestsConcurrent() public {
        _stake(alice, 3_000e18);
        vm.roll(block.number + 1);

        vm.startPrank(alice);
        uint256 id1 = pool.requestWithdrawal(1_000e18);
        uint256 id2 = pool.requestWithdrawal(1_000e18);
        uint256 id3 = pool.requestWithdrawal(1_000e18);
        vm.stopPrank();

        assertEq(pool.totalPendingWithdrawals(), 3_000e18);
        assertEq(pool.totalStaked(), 0);

        // Execute all after cooldown.
        vm.warp(block.timestamp + COOLDOWN + 1);

        vm.startPrank(alice);
        pool.executeWithdrawal(id1);
        pool.executeWithdrawal(id2);
        pool.executeWithdrawal(id3);
        vm.stopPrank();

        assertEq(pool.totalPendingWithdrawals(), 0);
        // All LP returned.
        assertEq(lp.balanceOf(alice), INITIAL_MINT);
    }

    // Can't request more than you have staked.
    function test_Withdraw_RequestMoreThanStakedReverts() public {
        _stake(alice, 500e18);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(StakingPool.SP__InsufficientStake.selector, alice, 500e18, 501e18)
        );
        pool.requestWithdrawal(501e18);
    }

    // Executing a withdrawal ID that doesn't exist (wrong ID or wrong user) reverts.
    function test_Withdraw_ExecuteNonExistentIdReverts() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(StakingPool.SP__WithdrawalNotFound.selector, alice, 999)
        );
        pool.executeWithdrawal(999);
    }

    // The unlock check is block.timestamp >= unlockTime (inclusive). Executing
    // at exactly the unlock timestamp should work.
    function test_Withdraw_ExecuteExactlyAtCooldownBoundary() public {
        _stake(alice, 1_000e18);
        vm.prank(alice);
        uint256 id = pool.requestWithdrawal(1_000e18);

        uint256 unlock = pool.withdrawalUnlockTime(alice, id);

        // Warp to exactly unlock time.
        vm.warp(unlock);
        vm.prank(alice);
        pool.executeWithdrawal(id); // Should NOT revert.
    }

    // One second before unlock should still revert.
    function test_Withdraw_ExecuteOneSecBeforeCooldownReverts() public {
        _stake(alice, 1_000e18);
        vm.prank(alice);
        uint256 id = pool.requestWithdrawal(1_000e18);

        uint256 unlock = pool.withdrawalUnlockTime(alice, id);
        vm.warp(unlock - 1);

        vm.prank(alice);
        vm.expectRevert(); // SP__CooldownNotElapsed
        pool.executeWithdrawal(id);
    }

    // =========================================================================
    // Section 4: Security multisig flagging
    // =========================================================================

    // Flagging a withdrawal resets requestTime to now, pushing the unlock
    // forward. The original unlock time no longer works.
    function test_Flag_MultisigResetsTimer() public {
        _stake(alice, 1_000e18);
        vm.prank(alice);
        uint256 id = pool.requestWithdrawal(1_000e18);

        uint256 originalUnlock = pool.withdrawalUnlockTime(alice, id);

        // Warp halfway through cooldown, then flag.
        vm.warp(block.timestamp + 1 days);
        vm.prank(multisig);
        pool.flagWithdrawal(alice, id);

        uint256 newUnlock = pool.withdrawalUnlockTime(alice, id);
        assertGt(newUnlock, originalUnlock, "new unlock should be later than original");

        // Alice can NOT withdraw yet (cooldown reset).
        vm.warp(originalUnlock);
        vm.prank(alice);
        vm.expectRevert(); // SP__CooldownNotElapsed
        pool.executeWithdrawal(id);

        // Alice CAN withdraw after new unlock.
        vm.warp(newUnlock);
        vm.prank(alice);
        pool.executeWithdrawal(id); // Should succeed.
    }

    // Any address other than the multisig calling flagWithdrawal must revert.
    function test_Flag_NonMultisigReverts() public {
        _stake(alice, 1_000e18);
        vm.prank(alice);
        uint256 id = pool.requestWithdrawal(500e18);

        vm.prank(attacker);
        vm.expectRevert(StakingPool.SP__OnlyMultisig.selector);
        pool.flagWithdrawal(alice, id);
    }

    // Flagging a request that doesn't exist must revert cleanly.
    function test_Flag_NonExistentRequestReverts() public {
        vm.prank(multisig);
        vm.expectRevert(
            abi.encodeWithSelector(StakingPool.SP__WithdrawalNotFound.selector, alice, 0)
        );
        pool.flagWithdrawal(alice, 0);
    }

    // The flagged bit prevents the multisig from resetting the same request
    // twice in a row. One flag per request.
    function test_Flag_DoubleFlagReverts() public {
        _stake(alice, 1_000e18);
        vm.prank(alice);
        uint256 id = pool.requestWithdrawal(500e18);

        vm.prank(multisig);
        pool.flagWithdrawal(alice, id); // First flag: OK.

        vm.prank(multisig);
        vm.expectRevert(
            abi.encodeWithSelector(StakingPool.SP__WithdrawalAlreadyFlagged.selector, id)
        );
        pool.flagWithdrawal(alice, id); // Second flag: should revert.
    }

    // Flagging only delays — the user can always execute once the new timer expires.
    function test_Flag_FlaggedWithdrawalEventuallyExecutes() public {
        _stake(alice, 1_000e18);
        vm.prank(alice);
        uint256 id = pool.requestWithdrawal(1_000e18);

        // Flag right away.
        vm.prank(multisig);
        pool.flagWithdrawal(alice, id);

        // Warp past new cooldown.
        vm.warp(block.timestamp + COOLDOWN + 1);

        uint256 lpBefore = lp.balanceOf(alice);
        vm.prank(alice);
        pool.executeWithdrawal(id);

        assertEq(lp.balanceOf(alice), lpBefore + 1_000e18);
    }

    // =========================================================================
    // Section 5: Admin / access control
    // =========================================================================

    function test_Admin_OnlyOwnerCanFundRewards() public {
        // Mint reward tokens to alice via owner (minter), then alice tries to fund — must revert.
        vm.prank(owner);
        reward.mint(alice, 1_000e18);

        vm.startPrank(alice);
        reward.approve(address(pool), 1_000e18);
        vm.expectRevert(StakingPool.SP__OnlyOwner.selector);
        pool.fundRewards(1_000e18);
        vm.stopPrank();
    }

    function test_Admin_OnlyOwnerCanSetOracle() public {
        vm.prank(attacker);
        vm.expectRevert(StakingPool.SP__OnlyOwner.selector);
        pool.setOracle(address(oracle));
    }

    function test_Admin_OnlyOwnerCanSetMultisig() public {
        vm.prank(attacker);
        vm.expectRevert(StakingPool.SP__OnlyOwner.selector);
        pool.setMultisig(address(multisig));
    }

    function test_Admin_SetOracleZeroAddressReverts() public {
        vm.prank(owner);
        vm.expectRevert(StakingPool.SP__ZeroAddress.selector);
        pool.setOracle(address(0));
    }

    function test_Admin_SetMultisigZeroAddressReverts() public {
        vm.prank(owner);
        vm.expectRevert(StakingPool.SP__ZeroAddress.selector);
        pool.setMultisig(address(0));
    }

    function test_Admin_FundRewardsZeroReverts() public {
        vm.prank(owner);
        vm.expectRevert(StakingPool.SP__ZeroAmount.selector);
        pool.fundRewards(0);
    }

    // =========================================================================
    // Section 6: Re-entrancy protection
    // =========================================================================

    // Attack path:
    //   alice calls claimRewards() → pool sets _locked=2 → calls reward.transfer()
    //   → MaliciousRewardToken re-enters claimRewards() → hits _locked=2 → SP__Locked
    //
    // We use a fresh pool backed by MaliciousRewardToken so the token can
    // call back into the pool during its own transfer().
    function test_Reentrancy_ClaimRewardsProtected() public {
        MaliciousRewardToken malReward = new MaliciousRewardToken();

        vm.prank(owner);
        StakingPool malPool = new StakingPool(
            address(lp),
            address(malReward),
            address(oracle),
            multisig
        );

        malReward.setTarget(address(malPool));

        // Fund the pool's reward reserve. malReward has an open mint, so we
        // mint directly to the pool address then poke the rewardReserve slot
        // via vm.store (slot 5, verified with `forge inspect StakingPool storageLayout`).
        //
        // rewardReserve is uint128 at slot 5 offset 0 (low 128 bits).
        // nextWithdrawalId is uint128 at slot 5 offset 16 (high 128 bits).
        // Packed word = (nextWithdrawalId << 128) | rewardReserve.
        // nextWithdrawalId starts at 0, so the word is just the reserve value.
        malReward.mint(address(malPool), 1_000_000e18);
        vm.store(address(malPool), bytes32(uint256(5)), bytes32(uint256(1_000_000e18)));

        // Alice stakes LP into the malicious pool.
        vm.startPrank(alice);
        lp.approve(address(malPool), 1_000e18);
        malPool.stake(1_000e18);
        vm.stopPrank();

        // Advance blocks so alice has pending rewards.
        vm.roll(block.number + 10);

        // claimRewards → malReward.transfer → re-enters claimRewards → SP__Locked.
        vm.prank(alice);
        vm.expectRevert(StakingPool.SP__Locked.selector);
        malPool.claimRewards();

        // Pool LP balance must be intact — nothing drained.
        assertEq(lp.balanceOf(address(malPool)), 1_000e18, "LP drained by re-entrancy");
    }

    // =========================================================================
    // Section 7: Invariant spot-checks (unit level)
    // =========================================================================

    function test_Invariant_LPBalanceEqualsStakedPlusPending() public {
        _stake(alice, 1_000e18);
        _stake(bob,   2_000e18);
        vm.roll(block.number + 5);

        vm.prank(alice);
        pool.requestWithdrawal(500e18);

        uint256 poolLP = lp.balanceOf(address(pool));
        assertEq(
            poolLP,
            pool.totalStaked() + pool.totalPendingWithdrawals(),
            "LP balance invariant broken"
        );
    }

    function test_Invariant_TotalStakedDecreaseOnRequest() public {
        _stake(alice, 1_000e18);
        uint256 tsBefore = pool.totalStaked();

        vm.prank(alice);
        pool.requestWithdrawal(400e18);

        assertEq(pool.totalStaked(), tsBefore - 400e18);
    }

    // =========================================================================
    // Section 8: Fuzz tests
    // =========================================================================

    // Stake any amount, then do a full withdrawal after cooldown. LP balance
    // must always be fully returned.
    function testFuzz_StakeAndWithdraw(uint128 amount) public {
        // Bound to a meaningful range: [1, INITIAL_MINT].
        amount = uint128(bound(uint256(amount), 1, INITIAL_MINT));

        _stake(alice, amount);

        vm.prank(alice);
        uint256 id = pool.requestWithdrawal(amount);

        vm.warp(block.timestamp + COOLDOWN + 1);

        uint256 lpBefore = lp.balanceOf(alice);
        vm.prank(alice);
        pool.executeWithdrawal(id);

        assertEq(lp.balanceOf(alice), lpBefore + amount, "fuzz: LP not returned");
        assertEq(pool.totalPendingWithdrawals(), 0);
        assertEq(pool.totalStaked(), 0);
    }

    // Over arbitrary block counts and reward rates, the accumulator should
    // produce exactly blocks * rate rewards (within 1 wei per block rounding).
    function testFuzz_RewardAccrual(uint256 blocks, uint256 rate) public {
        // Bound: blocks [1,1000], rate [1e15, 1e24] (within MAX_REWARD_PER_BLOCK).
        blocks = bound(blocks, 1, 1_000);
        rate   = bound(rate, 1e15, 1e24);

        vm.prank(owner);
        oracle.setRate(rate);

        // Use a stakeAmount that is a round divisor to minimise accumulator
        // rounding: 1e18 means accRPS increments by exactly rate per block.
        uint256 stakeAmount = 1e18;
        vm.prank(owner);
        lp.mint(alice, stakeAmount); // top-up so alice has enough

        _stake(alice, stakeAmount);

        vm.roll(block.number + blocks);

        uint256 pending  = pool.pendingReward(alice);
        uint256 expected = blocks * rate;

        // Allow up to `blocks` wei of integer-division rounding loss.
        assertApproxEqAbs(pending, expected, blocks, "fuzz: reward accrual mismatch");
    }

    // For any time offset, withdrawal must fail before unlock and succeed after.
    function testFuzz_CooldownEnforcement(uint256 timeOffset) public {
        // Bound timeOffset to something realistic.
        timeOffset = bound(timeOffset, 0, COOLDOWN * 3);

        _stake(alice, 1_000e18);
        vm.prank(alice);
        uint256 id = pool.requestWithdrawal(1_000e18);

        uint256 unlock = pool.withdrawalUnlockTime(alice, id);
        vm.warp(block.timestamp + timeOffset);

        if (block.timestamp < unlock) {
            vm.prank(alice);
            vm.expectRevert(); // must revert before unlock
            pool.executeWithdrawal(id);
        } else {
            vm.prank(alice);
            pool.executeWithdrawal(id); // must succeed at or after unlock
        }
    }

    // Partial withdrawal should leave exactly stakeAmt - withdrawAmt staked,
    // and the LP balance invariant must hold throughout.
    function testFuzz_PartialWithdrawal(uint128 stakeAmt, uint128 withdrawAmt) public {
        stakeAmt    = uint128(bound(uint256(stakeAmt),    2, INITIAL_MINT));
        withdrawAmt = uint128(bound(uint256(withdrawAmt), 1, stakeAmt - 1));

        _stake(alice, stakeAmt);
        vm.roll(block.number + 1);

        vm.prank(alice);
        pool.requestWithdrawal(withdrawAmt);

        (uint128 remaining,,) = pool.userInfo(alice);
        assertEq(remaining, stakeAmt - withdrawAmt, "fuzz: remaining stake wrong");
        assertEq(pool.totalStaked(), stakeAmt - withdrawAmt);
        assertEq(pool.totalPendingWithdrawals(), withdrawAmt);
        assertEq(
            lp.balanceOf(address(pool)),
            pool.totalStaked() + pool.totalPendingWithdrawals(),
            "fuzz: LP balance invariant broken"
        );
    }

    // totalStaked must always equal the sum of each user's staked balance.
    function testFuzz_MultiUserTotalStaked(uint128 aliceAmt, uint128 bobAmt) public {
        aliceAmt = uint128(bound(uint256(aliceAmt), 1, INITIAL_MINT));
        bobAmt   = uint128(bound(uint256(bobAmt),   1, INITIAL_MINT));

        _stake(alice, aliceAmt);
        _stake(bob,   bobAmt);

        (uint128 aStaked,,) = pool.userInfo(alice);
        (uint128 bStaked,,) = pool.userInfo(bob);

        assertEq(uint256(aStaked) + uint256(bStaked), pool.totalStaked(), "fuzz: totalStaked invariant broken");
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _stake(address user, uint256 amount) internal {
        vm.startPrank(user);
        lp.approve(address(pool), amount);
        pool.stake(amount);
        vm.stopPrank();
    }
}

// Helper contracts defined here so the test file has no external dependencies.

// Returns 0 from rewardPerBlock() — used to verify the pool reverts when the
// oracle rate is zero.
contract ZeroOracle {
    function rewardPerBlock() external pure returns (uint256) { return 0; }
}

// A minimal ERC-20 that re-enters the pool's claimRewards() inside transfer().
// Used to verify the mutex blocks double-claim attacks.
contract MaliciousRewardToken {
    mapping(address => uint256) public balanceOf;
    address public target;

    function setTarget(address _target) external { target = _target; }
    function mint(address to, uint256 amount) external { balanceOf[to] += amount; }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to]         += amount;
        // Re-enter while _locked == 2. Pool must reject with SP__Locked.
        if (target != address(0)) {
            StakingPool(target).claimRewards();
        }
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        balanceOf[from] -= amount;
        balanceOf[to]   += amount;
        return true;
    }
}

// Kept for reference — not active in any test.
contract ReentrancyAttacker {
    constructor(address, address) {}
    function attack() external {}
}
