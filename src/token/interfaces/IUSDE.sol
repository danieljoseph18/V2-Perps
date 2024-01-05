// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IUSDE is IERC20 {
    /// @dev This event is emitted when a deposit is made
    /// @param user The address of the user making the deposit
    /// @param usdcAmount The amount of USDC being deposited
    /// @param usdeAmount The amount of USDE minted to the user
    event Deposit(address indexed user, uint256 indexed usdcAmount, uint256 indexed usdeAmount);

    /// @dev This event is emitted when a withdrawal is made
    /// @param user The address of the user making the withdrawal
    /// @param usdeAmount The amount of USDE being withdrawn
    /// @param usdcAmount The amount of USDC transferred to the user
    event Withdraw(address indexed user, uint256 indexed usdeAmount, uint256 indexed usdcAmount);

    /// @dev Function to deposit USDC and mint USDE
    /// @param _usdcAmount The amount of USDC to deposit
    /// @return The amount of USDE minted
    function deposit(uint256 _usdcAmount) external returns (uint256);

    /// @dev Function to withdraw USDC by burning USDE
    /// @param usdeAmount The amount of USDE to burn
    /// @return The amount of USDC withdrawn
    function withdraw(uint256 usdeAmount) external returns (uint256);

    /// @dev Getter for the USDC token address
    /// @return The address of the USDC token contract
    function USDC() external view returns (IERC20);
}
