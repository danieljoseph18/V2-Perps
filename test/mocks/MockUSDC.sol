// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDC is ERC20 {
    uint8 private constant _decimals = 6;

    constructor(uint256 initialSupply) ERC20("USDC", "USDC") {
        _mint(msg.sender, initialSupply);
    }

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }

    function decimals() public pure override returns (uint8) {
        return _decimals;
    }
}
