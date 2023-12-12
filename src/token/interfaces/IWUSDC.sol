// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.21;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IWUSDC is IERC20 {
    /// @dev This event is emitted when a deposit is made
    /// @param user The address of the user making the deposit
    /// @param usdcAmount The amount of USDC being deposited
    /// @param wusdcAmount The amount of WUSDC minted to the user
    event Deposit(address indexed user, uint256 usdcAmount, uint256 wusdcAmount);

    /// @dev This event is emitted when a withdrawal is made
    /// @param user The address of the user making the withdrawal
    /// @param wusdcAmount The amount of WUSDC being withdrawn
    /// @param usdcAmount The amount of USDC transferred to the user
    event Withdraw(address indexed user, uint256 wusdcAmount, uint256 usdcAmount);

    /// @dev Function to deposit USDC and mint WUSDC
    /// @param _usdcAmount The amount of USDC to deposit
    /// @return The amount of WUSDC minted
    function deposit(uint256 _usdcAmount) external returns (uint256);

    /// @dev Function to withdraw USDC by burning WUSDC
    /// @param _wusdcAmount The amount of WUSDC to burn
    /// @return The amount of USDC withdrawn
    function withdraw(uint256 _wusdcAmount) external returns (uint256);

    /// @dev Getter for the USDC token address
    /// @return The address of the USDC token contract
    function USDC() external view returns (address);
}
