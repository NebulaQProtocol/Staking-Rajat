// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IRewardOracle} from "../interfaces/IRewardOracle.sol";

// Mock reward oracle for testing. Supports two modes:
//
//   Static mode      — a fixed rate set by the owner via setRate().
//                      This is what most unit tests use.
//
//   Variable mode    — rate = baseRate + (block.number % moduloRange) * delta
//                      Lets tests simulate a rate that genuinely changes
//                      every block by combining this with vm.roll.
//
// The deployer is the sole owner. No role management needed — this contract
// is test infrastructure, not production code.
contract MockRewardOracle is IRewardOracle {

    // -------------------------------------------------------------------------
    // Custom errors
    // -------------------------------------------------------------------------

    error Oracle__OnlyOwner();
    error Oracle__ZeroRate();
    error Oracle__ZeroModulo();

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event RateUpdated(uint256 newRate);
    event VariableRateConfigured(uint256 baseRate, uint256 delta, uint256 moduloRange);

    // -------------------------------------------------------------------------
    // Storage
    // -------------------------------------------------------------------------

    address public immutable owner;

    uint256 private _staticRate;
    bool    private _useVariableRate;

    uint256 private _baseRate;
    uint256 private _delta;
    uint256 private _moduloRange;

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    constructor(uint256 initialRate) {
        if (initialRate == 0) revert Oracle__ZeroRate();
        owner       = msg.sender;
        _staticRate = initialRate;
    }

    // -------------------------------------------------------------------------
    // IRewardOracle
    // -------------------------------------------------------------------------

    function rewardPerBlock() external view override returns (uint256 rate) {
        if (_useVariableRate) {
            // block.number % _moduloRange is in [0, _moduloRange - 1], so
            // the result is always >= _baseRate as long as baseRate > 0.
            unchecked {
                rate = _baseRate + ((block.number % _moduloRange) * _delta);
            }
            if (rate == 0) revert Oracle__ZeroRate();
        } else {
            rate = _staticRate;
        }
    }

    // -------------------------------------------------------------------------
    // Admin — static mode
    // -------------------------------------------------------------------------

    function setRate(uint256 newRate) external {
        if (msg.sender != owner) revert Oracle__OnlyOwner();
        if (newRate == 0)        revert Oracle__ZeroRate();
        _staticRate      = newRate;
        _useVariableRate = false;
        emit RateUpdated(newRate);
    }

    // -------------------------------------------------------------------------
    // Admin — variable mode
    // -------------------------------------------------------------------------

    function setVariableRate(uint256 baseRate, uint256 delta, uint256 moduloRange) external {
        if (msg.sender != owner) revert Oracle__OnlyOwner();
        if (baseRate == 0)       revert Oracle__ZeroRate();
        if (moduloRange == 0)    revert Oracle__ZeroModulo();
        _baseRate        = baseRate;
        _delta           = delta;
        _moduloRange     = moduloRange;
        _useVariableRate = true;
        emit VariableRateConfigured(baseRate, delta, moduloRange);
    }
}
