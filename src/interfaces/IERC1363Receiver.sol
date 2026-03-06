// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// Any contract that wants to receive ERC-1363 tokens via transferAndCall or
// transferFromAndCall must implement this interface.
//
// StakingPool implements it so users can stake LP tokens in a single transaction
// instead of the usual two-step approve + stake.
//
// Magic return value: bytes4(keccak256("onTransferReceived(address,address,uint256,bytes)"))
//                   = 0x88a7ca5c
//
// If the callback returns anything other than this magic value, the token
// contract reverts the entire transfer.
interface IERC1363Receiver {
    // Called by the token contract after a successful transfer.
    // Must return 0x88a7ca5c or the whole thing rolls back.
    function onTransferReceived(
        address operator,
        address from,
        uint256 amount,
        bytes calldata data
    ) external returns (bytes4);
}
