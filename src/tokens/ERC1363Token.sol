// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20Base}        from "./ERC20Base.sol";
import {IERC1363}         from "../interfaces/IERC1363.sol";
import {IERC1363Receiver} from "../interfaces/IERC1363Receiver.sol";

// ERC-1363 "payable token" built on top of ERC20Base.
//
// The spec adds three new entry points:
//   transferAndCall      — transfer then notify the recipient
//   transferFromAndCall  — transferFrom then notify the recipient
//   approveAndCall       — approve then notify the spender
//
// In every case the token transfer happens first. By the time the callback
// fires, the receiver's balance is already updated, so the transferred tokens
// cannot be double-spent through re-entrancy on the token layer. The *calling*
// contract (StakingPool) is still responsible for protecting its own state
// against re-entrancy triggered through the callback — it uses a mutex for that.
//
// Magic selector for IERC1363Receiver.onTransferReceived:
//   bytes4(keccak256("onTransferReceived(address,address,uint256,bytes)")) = 0x88a7ca5c
abstract contract ERC1363Token is ERC20Base, IERC1363 {

    // -------------------------------------------------------------------------
    // Custom errors
    // -------------------------------------------------------------------------

    // The callback target didn't return the expected magic value, or the call
    // itself reverted.
    error ERC1363__CallbackFailed(address target);

    // transferAndCall/transferFromAndCall was aimed at an EOA, which can't
    // implement the callback interface.
    error ERC1363__ReceiverNotContract(address target);

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    bytes4 private constant _TRANSFER_RECEIVED_MAGIC =
        bytes4(keccak256("onTransferReceived(address,address,uint256,bytes)"));

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    constructor(string memory name_, string memory symbol_, uint8 decimals_)
        ERC20Base(name_, symbol_, decimals_)
    {}

    // -------------------------------------------------------------------------
    // IERC1363 — transferAndCall
    // -------------------------------------------------------------------------

    function transferAndCall(address to, uint256 amount) external override returns (bool) {
        return _transferAndCall(msg.sender, to, amount, "");
    }

    function transferAndCall(address to, uint256 amount, bytes calldata data)
        external override returns (bool)
    {
        return _transferAndCall(msg.sender, to, amount, data);
    }

    // -------------------------------------------------------------------------
    // IERC1363 — transferFromAndCall
    // -------------------------------------------------------------------------

    function transferFromAndCall(address from, address to, uint256 amount)
        external override returns (bool)
    {
        return _transferFromAndCall(from, to, amount, "");
    }

    function transferFromAndCall(address from, address to, uint256 amount, bytes calldata data)
        external override returns (bool)
    {
        return _transferFromAndCall(from, to, amount, data);
    }

    // -------------------------------------------------------------------------
    // IERC1363 — approveAndCall
    // Not used by the staking protocol but required by the full ERC-1363 spec.
    // -------------------------------------------------------------------------

    function approveAndCall(address spender, uint256 amount) external override returns (bool) {
        return _approveAndCall(msg.sender, spender, amount, "");
    }

    function approveAndCall(address spender, uint256 amount, bytes calldata data)
        external override returns (bool)
    {
        return _approveAndCall(msg.sender, spender, amount, data);
    }

    // -------------------------------------------------------------------------
    // Internal implementations
    // -------------------------------------------------------------------------

    function _transferAndCall(
        address from, address to, uint256 amount, bytes memory data
    ) internal returns (bool) {
        _transfer(from, to, amount);
        _checkAndCallTransferReceived(from, from, to, amount, data);
        return true;
    }

    function _transferFromAndCall(
        address from, address to, uint256 amount, bytes memory data
    ) internal returns (bool) {
        _spendAllowance(from, msg.sender, amount);
        _transfer(from, to, amount);
        _checkAndCallTransferReceived(msg.sender, from, to, amount, data);
        return true;
    }

    function _approveAndCall(
        address owner, address spender, uint256 amount, bytes memory data
    ) internal returns (bool) {
        _approve(owner, spender, amount);
        _checkAndCallApprovalReceived(owner, spender, amount, data);
        return true;
    }

    // Call onTransferReceived on `to` and verify the magic return value.
    // Reverts if `to` is an EOA (no code) or returns the wrong selector.
    function _checkAndCallTransferReceived(
        address operator, address from, address to, uint256 amount, bytes memory data
    ) private {
        if (to.code.length == 0) revert ERC1363__ReceiverNotContract(to);

        bytes4 retval = IERC1363Receiver(to).onTransferReceived(operator, from, amount, data);
        if (retval != _TRANSFER_RECEIVED_MAGIC) revert ERC1363__CallbackFailed(to);
    }

    // Call onApprovalReceived on `spender` and verify the magic return value.
    // Magic: bytes4(keccak256("onApprovalReceived(address,uint256,bytes)")) = 0x7b04a2d0
    function _checkAndCallApprovalReceived(
        address owner, address spender, uint256 amount, bytes memory data
    ) private {
        if (spender.code.length == 0) revert ERC1363__ReceiverNotContract(spender);

        bytes4 expectedSelector = bytes4(keccak256("onApprovalReceived(address,uint256,bytes)"));
        (bool success, bytes memory result) = spender.call(
            abi.encodeWithSelector(expectedSelector, owner, amount, data)
        );
        if (!success || result.length < 32) revert ERC1363__CallbackFailed(spender);
        bytes4 retval = abi.decode(result, (bytes4));
        if (retval != expectedSelector) revert ERC1363__CallbackFailed(spender);
    }
}
