// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IWETH is IERC20 {
    // Event declarations can be included if events are emitted in the implemented functions
    // event Deposit(address indexed account, uint256 amount);
    // event Withdrawal(address indexed account, uint256 amount);

    // @dev Mint WETH by depositing Ether
    function deposit() external payable;

    // @dev Withdraw Ether by burning WETH
    // @param amount The amount to withdraw
    function withdraw(uint256 amount) external;

    // @dev Mint tokens to an account
    // @param account The account to mint to
    // @param amount The amount of tokens to mint
    function mint(address account, uint256 amount) external;

    // @dev Burn tokens from an account
    // @param account The account to burn tokens for
    // @param amount The amount of tokens to burn
    function burn(address account, uint256 amount) external;
}
