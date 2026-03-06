// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// Minimal ERC-20 interface. Only covers the functions the staking protocol
// actually needs — transfer, transferFrom, approve, balanceOf, allowance,
// and the two events. The metadata functions (name, symbol, decimals,
// totalSupply) are included for completeness.
interface IERC20 {

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function name()        external view returns (string memory);
    function symbol()      external view returns (string memory);
    function decimals()    external view returns (uint8);
    function totalSupply() external view returns (uint256);

    function balanceOf(address account)                          external view returns (uint256);
    function allowance(address owner, address spender)           external view returns (uint256);

    function transfer(address to, uint256 amount)                external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount)            external returns (bool);
}
