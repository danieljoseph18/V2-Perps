// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IERC20} from "./IERC20.sol";

interface IWETH is IERC20 {
    // Event declarations can be included if events are emitted in the implemented functions
    // event Deposit(address indexed account, uint256 amount);
    // event Withdrawal(address indexed account, uint256 amount);

    // @dev Mint WETH by depositing Ether
    function deposit() external payable;

    // @dev Withdraw Ether by burning WETH
    // @param amount The amount to withdraw
    function withdraw(uint256 amount) external;
}
