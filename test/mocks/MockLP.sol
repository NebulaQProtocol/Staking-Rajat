// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC1363Token} from "../../src/tokens/ERC1363Token.sol";

// ERC-1363 LP token used in tests.
// mint() is locked to the deployer so tests can control token supply
// without worrying about unauthorized minting.
contract MockLP is ERC1363Token {

    address public immutable minter;

    error MockLP__OnlyMinter();

    constructor(string memory name_, string memory symbol_)
        ERC1363Token(name_, symbol_, 18)
    {
        minter = msg.sender;
    }

    function mint(address to, uint256 amount) external {
        if (msg.sender != minter) revert MockLP__OnlyMinter();
        _mint(to, amount);
    }
}
