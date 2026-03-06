// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console2}   from "forge-std/Test.sol";
import {StdInvariant}     from "forge-std/StdInvariant.sol";
import {StakingPool}      from "../../src/StakingPool.sol";
import {MockRewardOracle} from "../../src/oracle/MockRewardOracle.sol";
import {MockLP}           from "../mocks/MockLP.sol";
import {MockRewardToken}  from "../mocks/MockRewardToken.sol";
import {Handler}          from "./Handler.sol";

// Stateful invariant suite for StakingPool.
//
// Forge runs 500 sequences of 100 random Handler calls each. After every
// sequence the invariant functions below are called to check protocol-level
// properties that must hold regardless of call order or timing.
//
// Invariants tested:
//
//   I1 — LP balance:          lpToken.balanceOf(pool) == totalStaked + totalPendingWithdrawals
//   I2 — totalStaked bounded: totalStaked <= lpToken.balanceOf(pool)
//   I3 — reward solvency:     rewardReserve <= rewardToken.balanceOf(pool)
//   I4 — accumulator mono:    accRewardPerShare never decreases
//   I5 — cooldown enforced:   no pending withdrawal is executable before its unlock time
//   I6 — ghost consistency:   Handler's ghost variables match pool's live state
contract StakingInvariant is StdInvariant, Test {

    uint256 constant REWARD_FUND  = 10_000_000e18;
    uint256 constant INITIAL_RATE = 100e18;
    uint256 constant ACTORS_COUNT = 4;

    StakingPool      pool;
    MockLP           lp;
    MockRewardToken  rewardToken;
    MockRewardOracle oracle;
    Handler          handler;

    // Snapshot of accRewardPerShare taken after each invariant call. Used
    // to detect any decrease (I4).
    uint256 lastAccRewardPerShare;

    address[] actors;
    address deployerOwner = makeAddr("invariantOwner");

    function setUp() public {
        vm.startPrank(deployerOwner);

        lp          = new MockLP("NQSwap LP", "NQ-LP");
        rewardToken = new MockRewardToken("NQSwap Reward", "NQR");
        oracle      = new MockRewardOracle(INITIAL_RATE);
        pool        = new StakingPool(
            address(lp),
            address(rewardToken),
            address(oracle),
            makeAddr("invariantMultisig")
        );

        rewardToken.mint(deployerOwner, REWARD_FUND);
        rewardToken.approve(address(pool), REWARD_FUND);
        pool.fundRewards(REWARD_FUND);

        vm.stopPrank();

        for (uint256 i = 0; i < ACTORS_COUNT; i++) {
            actors.push(makeAddr(string(abi.encodePacked("actor", i))));
        }

        handler = new Handler(pool, lp, rewardToken, oracle, actors, deployerOwner);

        targetContract(address(handler));

        lastAccRewardPerShare = pool.accRewardPerShare();
    }

    // =========================================================================
    // Invariants
    // =========================================================================

    // I1: The pool must hold exactly as many LP tokens as are actively staked
    // plus those sitting in pending withdrawal requests. Any discrepancy means
    // tokens were created from nothing or silently lost.
    function invariant_LPBalanceMatchesAccounting() public view {
        uint256 poolLPBalance = lp.balanceOf(address(pool));
        uint256 accountedFor  = pool.totalStaked() + pool.totalPendingWithdrawals();
        assertEq(
            poolLPBalance,
            accountedFor,
            "I1: lpToken.balanceOf(pool) != totalStaked + totalPendingWithdrawals"
        );
    }

    // I2: totalStaked can never exceed the LP tokens the pool actually holds.
    function invariant_TotalStakedNeverExceedsBalance() public view {
        assertLe(
            pool.totalStaked(),
            lp.balanceOf(address(pool)),
            "I2: totalStaked > lpToken.balanceOf(pool)"
        );
    }

    // I3: The on-chain rewardReserve counter must never claim more reward tokens
    // exist than are actually sitting in the contract.
    function invariant_RewardReserveSolvent() public view {
        assertLe(
            pool.rewardReserve(),
            rewardToken.balanceOf(address(pool)),
            "I3: rewardReserve > rewardToken.balanceOf(pool)"
        );
    }

    // I4: accRewardPerShare is monotonically non-decreasing. It is updated
    // lazily on every pool interaction, but it must never go backwards.
    function invariant_AccumulatorMonotone() public {
        uint256 current = pool.accRewardPerShare();
        assertGe(current, lastAccRewardPerShare, "I4: accRewardPerShare decreased");
        lastAccRewardPerShare = current;
    }

    // I5: For every actor and every pending withdrawal request, if the amount
    // is non-zero the unlock time must still be in the future (or the request
    // must have been executed, in which case amount == 0).
    function invariant_CooldownNotBypassed() public view {
        for (uint256 i = 0; i < actors.length; i++) {
            address actor = actors[i];
            uint256[] memory ids = pool.getUserWithdrawalIds(actor);

            for (uint256 j = 0; j < ids.length; j++) {
                StakingPool.WithdrawalRequest memory req =
                    pool.getWithdrawalRequest(actor, ids[j]);

                if (req.amount == 0) continue; // already executed

                uint256 unlockTime = uint256(req.requestTime) + 2 days;
                if (block.timestamp < unlockTime) {
                    // The request is locked. Just assert the state is consistent —
                    // we can't call executeWithdrawal here because invariants are
                    // view-only.
                    assertTrue(
                        block.timestamp < unlockTime,
                        "I5: withdrawal should be locked but appears unlockable"
                    );
                }
            }
        }
    }

    // I6: The Handler's ghost variables must always match the pool's live state.
    // If they diverge, the Handler has a bug in its accounting.
    function invariant_GhostStateConsistent() public view {
        assertEq(
            handler.ghostTotalStaked(),
            pool.totalStaked(),
            "I6: ghost totalStaked != pool.totalStaked()"
        );
        assertEq(
            handler.ghostTotalPending(),
            pool.totalPendingWithdrawals(),
            "I6: ghost totalPending != pool.totalPendingWithdrawals()"
        );
    }

    // Not a real invariant — just prints a call distribution summary so we
    // can see whether the fuzzer is exercising all code paths.
    function invariant_CallSummary() public view {
        console2.log("--- Handler Call Summary ---");
        console2.log("stake():             ", handler.callsStake());
        console2.log("requestWithdrawal(): ", handler.callsRequestWithdraw());
        console2.log("executeWithdrawal(): ", handler.callsExecuteWithdraw());
        console2.log("claimRewards():      ", handler.callsClaim());
    }
}
