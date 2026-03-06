// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// The oracle is the single source of truth for the per-block reward emission.
// StakingPool calls this on every pool update and treats the result as an
// untrusted external value — it validates non-zero before using it.
//
// Keeping the interface this small limits the attack surface: the staking
// contract can never accidentally mutate oracle state.
interface IRewardOracle {
    // Returns how many reward tokens (18 decimals) are distributed per block
    // across all stakers combined. Must never return 0.
    function rewardPerBlock() external view returns (uint256 rate);
}
