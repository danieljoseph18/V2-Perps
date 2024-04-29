// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {ERC20} from "../../src/tokens/ERC20.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("USDC", "USDC", 6) {}

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }
}
