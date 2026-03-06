// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test}             from "forge-std/Test.sol";
import {StakingPool}      from "../../src/StakingPool.sol";
import {MockRewardOracle} from "../../src/oracle/MockRewardOracle.sol";
import {MockLP}           from "../mocks/MockLP.sol";
import {MockRewardToken}  from "../mocks/MockRewardToken.sol";

// Bounded actor for the invariant suite.
//
// The fuzzer calls these functions in random order. Each one wraps a real
// pool interaction with safe bounds so the fuzzer spends its time exploring
// interesting states rather than hammering on reverts. The only expected
// reverts are on stake() when an actor has run out of LP balance — those
// are correct and harmless.
//
// Ghost variables mirror the pool's key counters. The invariant contract
// compares them to the live pool state after every call sequence. If they
// ever diverge, something went wrong in the accounting.
contract Handler is Test {

    uint256 constant COOLDOWN       = 2 days;
    uint256 constant MINT_PER_ACTOR = 100_000e18;

    StakingPool      public pool;
    MockLP           public lp;
    MockRewardToken  public rewardToken;
    MockRewardOracle public oracle;

    address[] public actors;
    address   internal _currentActor;

    // Mirrors pool.totalStaked() and pool.totalPendingWithdrawals().
    // Updated in lockstep with every action so invariants can compare
    // them against the real values without an extra RPC call.
    uint256 public ghostTotalStaked;
    uint256 public ghostTotalPending;

    // Per-actor list of pending withdrawal IDs so executeWithdrawal has
    // something concrete to call with.
    mapping(address => uint256[]) internal _actorWithdrawalIds;

    // Call counters for the coverage reporter invariant.
    uint256 public callsStake;
    uint256 public callsRequestWithdraw;
    uint256 public callsExecuteWithdraw;
    uint256 public callsClaim;

    constructor(
        StakingPool      _pool,
        MockLP           _lp,
        MockRewardToken  _reward,
        MockRewardOracle _oracle,
        address[] memory _actors,
        address          _lpMinter
    ) {
        pool        = _pool;
        lp          = _lp;
        rewardToken = _reward;
        oracle      = _oracle;
        actors      = _actors;

        // MockLP.mint is restricted to its deployer, so prank as _lpMinter.
        for (uint256 i = 0; i < _actors.length; i++) {
            vm.prank(_lpMinter);
            lp.mint(_actors[i], MINT_PER_ACTOR);
        }
    }

    // Pick a random actor from the array and run the action as them.
    modifier useActor(uint256 actorSeed) {
        _currentActor = actors[actorSeed % actors.length];
        vm.startPrank(_currentActor);
        _;
        vm.stopPrank();
    }

    // =========================================================================
    // Actions
    // =========================================================================

    // Stake a random portion of the actor's remaining LP balance.
    // Reverts are expected once an actor exhausts their balance — that's fine.
    function stake(uint256 actorSeed, uint256 amount) external useActor(actorSeed) {
        amount = bound(amount, 1, lp.balanceOf(_currentActor));
        if (amount == 0) return;

        lp.approve(address(pool), amount);
        pool.stake(amount);

        ghostTotalStaked += amount;
        callsStake++;
    }

    // Request withdrawal of a random portion of the actor's staked balance.
    function requestWithdrawal(uint256 actorSeed, uint256 amount) external useActor(actorSeed) {
        (uint128 staked,,) = pool.userInfo(_currentActor);
        if (staked == 0) return;

        amount = bound(amount, 1, staked);

        uint256 id = pool.requestWithdrawal(amount);
        _actorWithdrawalIds[_currentActor].push(id);

        ghostTotalStaked  -= amount;
        ghostTotalPending += amount;
        callsRequestWithdraw++;
    }

    // Execute the oldest pending withdrawal for an actor if its cooldown has elapsed.
    function executeWithdrawal(uint256 actorSeed) external useActor(actorSeed) {
        uint256[] storage ids = _actorWithdrawalIds[_currentActor];
        if (ids.length == 0) return;

        uint256 id     = ids[0];
        uint256 unlock = pool.withdrawalUnlockTime(_currentActor, id);

        // Guard: request already gone (shouldn't happen but be safe).
        if (unlock == 0) {
            _removeFirst(ids);
            return;
        }

        // Skip silently if still locked — don't want a revert to count against
        // the actor.
        if (block.timestamp < unlock) return;

        StakingPool.WithdrawalRequest memory req =
            pool.getWithdrawalRequest(_currentActor, id);
        uint256 amount = req.amount;

        pool.executeWithdrawal(id);

        ghostTotalPending -= amount;
        _removeFirst(ids);
        callsExecuteWithdraw++;
    }

    // Claim pending rewards for a random actor.
    // Skip if there's nothing to claim or the reserve can't cover it.
    function claimRewards(uint256 actorSeed) external useActor(actorSeed) {
        uint256 pending = pool.pendingReward(_currentActor);
        if (pending == 0)                   return;
        if (pending > pool.rewardReserve()) return;

        pool.claimRewards();
        callsClaim++;
    }

    // Advance time so cooldowns can expire during a run.
    function warpTime(uint256 seconds_) external {
        seconds_ = bound(seconds_, 0, COOLDOWN * 2);
        vm.warp(block.timestamp + seconds_);
    }

    // Advance blocks to trigger reward accrual.
    function rollBlocks(uint256 blocks_) external {
        blocks_ = bound(blocks_, 1, 50);
        vm.roll(block.number + blocks_);
    }

    // =========================================================================
    // View helpers
    // =========================================================================

    function getActorWithdrawalIds(address actor)
        external view returns (uint256[] memory)
    {
        return _actorWithdrawalIds[actor];
    }

    // =========================================================================
    // Internal
    // =========================================================================

    // Swap-and-pop from the front. Not O(1) but withdrawal arrays are tiny.
    function _removeFirst(uint256[] storage arr) internal {
        if (arr.length == 0) return;
        for (uint256 i = 0; i < arr.length - 1; i++) {
            arr[i] = arr[i + 1];
        }
        arr.pop();
    }
}
