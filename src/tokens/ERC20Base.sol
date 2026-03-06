// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "../interfaces/IERC20.sol";

// Minimal ERC-20 base written from scratch — no OpenZeppelin.
//
// Designed to be inherited, not deployed directly. Concrete tokens
// (MockLP, MockRewardToken, etc.) decide who can call _mint and _burn.
//
// A few deliberate choices worth noting:
//   - Custom errors instead of require strings. Saves gas on every revert
//     and makes them easier to match in tests.
//   - _decimals is immutable so it's embedded in bytecode rather than
//     sitting in a storage slot that needs an SLOAD.
//   - _transfer is a single internal function shared by transfer() and
//     transferFrom() so the zero-address and balance checks only live
//     in one place.
//   - Infinite approval (type(uint256).max) is respected in _spendAllowance
//     and never decremented.
abstract contract ERC20Base is IERC20 {

    // -------------------------------------------------------------------------
    // Custom errors
    // -------------------------------------------------------------------------

    error ERC20__InsufficientBalance(address account, uint256 have, uint256 need);
    error ERC20__InsufficientAllowance(address owner, address spender, uint256 have, uint256 need);
    error ERC20__TransferToZeroAddress();
    error ERC20__TransferFromZeroAddress();
    error ERC20__ApproveToZeroAddress();
    error ERC20__ApproveFromZeroAddress();
    error ERC20__MintToZeroAddress();
    error ERC20__BurnFromZeroAddress();
    error ERC20__BurnExceedsBalance(address account, uint256 have, uint256 need);

    // -------------------------------------------------------------------------
    // Storage
    // -------------------------------------------------------------------------

    string private _name;
    string private _symbol;
    uint8  private immutable _decimals;

    uint256 private _totalSupply;

    mapping(address => uint256)                     private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        _name     = name_;
        _symbol   = symbol_;
        _decimals = decimals_;
    }

    // -------------------------------------------------------------------------
    // IERC20 — view functions
    // -------------------------------------------------------------------------

    function name()        external view override returns (string memory) { return _name; }
    function symbol()      external view override returns (string memory) { return _symbol; }
    function decimals()    external view override returns (uint8)         { return _decimals; }
    function totalSupply() external view override returns (uint256)       { return _totalSupply; }

    function balanceOf(address account) external view override returns (uint256) {
        return _balances[account];
    }

    function allowance(address owner, address spender) external view override returns (uint256) {
        return _allowances[owner][spender];
    }

    // -------------------------------------------------------------------------
    // IERC20 — state-changing functions
    // -------------------------------------------------------------------------

    function transfer(address to, uint256 amount) external override returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        _spendAllowance(from, msg.sender, amount);
        _transfer(from, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    // -------------------------------------------------------------------------
    // Internal helpers
    // -------------------------------------------------------------------------

    function _transfer(address from, address to, uint256 amount) internal {
        if (from == address(0)) revert ERC20__TransferFromZeroAddress();
        if (to   == address(0)) revert ERC20__TransferToZeroAddress();

        uint256 fromBalance = _balances[from];
        if (fromBalance < amount) {
            revert ERC20__InsufficientBalance(from, fromBalance, amount);
        }

        // Both sides are safe: we just checked fromBalance >= amount, and
        // total supply never grows beyond what _mint produces.
        unchecked {
            _balances[from]  = fromBalance - amount;
            _balances[to]   += amount;
        }

        emit Transfer(from, to, amount);
    }

    function _approve(address owner, address spender, uint256 amount) internal {
        if (owner   == address(0)) revert ERC20__ApproveFromZeroAddress();
        if (spender == address(0)) revert ERC20__ApproveToZeroAddress();
        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    // Decrease allowance by `amount`. Does nothing if the allowance is set to
    // the infinite sentinel (type(uint256).max).
    function _spendAllowance(address owner, address spender, uint256 amount) internal {
        uint256 current = _allowances[owner][spender];
        if (current != type(uint256).max) {
            if (current < amount) {
                revert ERC20__InsufficientAllowance(owner, spender, current, amount);
            }
            unchecked {
                _allowances[owner][spender] = current - amount;
            }
        }
    }

    function _mint(address to, uint256 amount) internal {
        if (to == address(0)) revert ERC20__MintToZeroAddress();
        _totalSupply += amount;
        unchecked { _balances[to] += amount; }
        emit Transfer(address(0), to, amount);
    }

    function _burn(address from, uint256 amount) internal {
        if (from == address(0)) revert ERC20__BurnFromZeroAddress();
        uint256 bal = _balances[from];
        if (bal < amount) revert ERC20__BurnExceedsBalance(from, bal, amount);
        unchecked {
            _balances[from]  = bal - amount;
            _totalSupply    -= amount;
        }
        emit Transfer(from, address(0), amount);
    }

    // Internal balance read used by derived contracts that need the value
    // without paying for an external call.
    function _balanceOf(address account) internal view returns (uint256) {
        return _balances[account];
    }
}
