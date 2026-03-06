// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20Base} from "../../src/tokens/ERC20Base.sol";

// Plain ERC-20 reward token used in tests.
// Doesn't need ERC-1363 callbacks — rewards are transferred out, not in.
// mint() is locked to the deployer for the same reason as MockLP.
contract MockRewardToken is ERC20Base {

    address public immutable minter;

    error MockReward__OnlyMinter();

    constructor(string memory name_, string memory symbol_)
        ERC20Base(name_, symbol_, 18)
    {
        minter = msg.sender;
    }

    function mint(address to, uint256 amount) external {
        if (msg.sender != minter) revert MockReward__OnlyMinter();
        _mint(to, amount);
    }
}
