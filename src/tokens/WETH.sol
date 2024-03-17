// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IWETH} from "./interfaces/IWETH.sol";

contract WETH is IWETH, ERC20 {
    constructor() ERC20("Wrapped Ether", "WETH") {}

    error TransferFailed(address account, uint256 amount);

    // @dev mint WETH by depositing the Ether
    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    // @dev withdraw the Ether by burning WETH
    // @param amount the amount to withdraw
    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool success,) = msg.sender.call{value: amount}("");
        if (!success) {
            revert TransferFailed(msg.sender, amount);
        }
    }

    // @dev mint tokens to an account
    // @param account the account to mint to
    // @param amount the amount of tokens to mint
    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }

    // @dev burn tokens from an account
    // @param account the account to burn tokens for
    // @param amount the amount of tokens to burn
    function burn(address account, uint256 amount) external {
        _burn(account, amount);
    }
}
