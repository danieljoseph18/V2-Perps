//  ,----,------------------------------,------.
//   | ## |                              |    - |
//   | ## |                              |    - |
//   |    |------------------------------|    - |
//   |    ||............................||      |
//   |    ||,-                        -.||      |
//   |    ||___                      ___||    ##|
//   |    ||---`--------------------'---||      |
//   `--mb'|_|______________________==__|`------'

//    ____  ____  ___ _   _ _____ _____ ____
//   |  _ \|  _ \|_ _| \ | |_   _|___ /|  _ \
//   | |_) | |_) || ||  \| | | |   |_ \| |_) |
//   |  __/|  _ < | || |\  | | |  ___) |  _ <
//   |_|   |_| \_\___|_| \_| |_| |____/|_| \_\

// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/*
    Contract acts as a Wrapper for USDC to make it 18 decimals
*/
contract WUSDC is ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error WUSDC_ZeroAddress();

    IERC20 public immutable USDC;

    event Deposit(address indexed user, uint256 indexed usdcAmount, uint256 indexed wusdcAmount);
    event Withdraw(address indexed user, uint256 indexed wusdcAmount, uint256 indexed usdcAmount);

    // We assume USDC has 6 decimals
    uint256 private constant DECIMALS_DIFFERENCE = 1e12;

    constructor(address _usdc) ERC20("Wrapped USDC", "WUSDC") {
        if (_usdc == address(0)) revert WUSDC_ZeroAddress();
        USDC = IERC20(_usdc);
    }

    /// @dev Accounts for Token Decimals (from 6 dec => 18)
    function deposit(uint256 _usdcAmount) external nonReentrant returns (uint256) {
        // Transfer USDC from user to contract
        USDC.safeTransferFrom(msg.sender, address(this), _usdcAmount);

        // Calculate the amount of WUSDC to mint (with 18 decimals)
        uint256 wusdcAmount = _usdcAmount * DECIMALS_DIFFERENCE;

        // Mint the user the equivalent of WUSDC
        _mint(msg.sender, wusdcAmount);

        emit Deposit(msg.sender, _usdcAmount, wusdcAmount);

        return wusdcAmount;
    }

    /// @dev Needs to account for Token Decimals (from 18 dec => 6)
    function withdraw(uint256 _wusdcAmount) external nonReentrant returns (uint256) {
        // Burn WUSDC first to protect against reentrancy
        _burn(msg.sender, _wusdcAmount);

        // Calculate the amount of USDC to transfer (with 6 decimals)
        uint256 usdcAmount = _wusdcAmount / DECIMALS_DIFFERENCE;

        // Transfer out equivalent of USDC
        USDC.safeTransfer(msg.sender, usdcAmount);

        emit Withdraw(msg.sender, _wusdcAmount, usdcAmount);

        return usdcAmount;
    }
}
