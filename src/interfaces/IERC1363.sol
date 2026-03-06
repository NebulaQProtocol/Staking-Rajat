// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// ERC-1363 "payable token" interface.
//
// The spec adds three families of functions on top of ERC-20:
//   transferAndCall      — transfer tokens to a contract, then call onTransferReceived on it
//   transferFromAndCall  — same but using the allowance mechanism
//   approveAndCall       — set an allowance, then call onApprovalReceived on the spender
//
// This lets a single transaction atomically move tokens into a contract and
// trigger its logic, removing the approve-then-call two-step pattern.
//
// Interface ID: 0xb0202a11
// Spec: https://eips.ethereum.org/EIPS/eip-1363
interface IERC1363 {

    // Transfer + notify recipient
    function transferAndCall(address to, uint256 amount) external returns (bool);
    function transferAndCall(address to, uint256 amount, bytes calldata data) external returns (bool);

    // TransferFrom + notify recipient
    function transferFromAndCall(address from, address to, uint256 amount) external returns (bool);
    function transferFromAndCall(address from, address to, uint256 amount, bytes calldata data) external returns (bool);

    // Approve + notify spender
    function approveAndCall(address spender, uint256 amount) external returns (bool);
    function approveAndCall(address spender, uint256 amount, bytes calldata data) external returns (bool);
}
