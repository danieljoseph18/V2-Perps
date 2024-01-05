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
pragma solidity 0.8.23;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/*
    Extended version of USDC -> Makes it 18 decimals
*/
contract USDE is ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable USDC;

    event Deposit(address indexed user, uint256 indexed usdcAmount, uint256 indexed usdeAmount);
    event Withdraw(address indexed user, uint256 indexed usdeAmount, uint256 indexed usdcAmount);

    uint256 private constant DECIMALS_DIFFERENCE = 1e12;

    constructor(address _usdc) ERC20("USDC Extended", "USDE") {
        require(_usdc != address(0), "USDE: Zero Address");
        USDC = IERC20(_usdc);
    }

    /// @dev Accounts for Token Decimals (from 6 dec => 18)
    function deposit(uint256 _usdcAmount) external nonReentrant returns (uint256 usdeAmount) {
        // Deposit USDC to the contract
        uint256 usdcBalanceBefore = USDC.balanceOf(address(this));
        USDC.safeTransferFrom(msg.sender, address(this), _usdcAmount);
        require(USDC.balanceOf(address(this)) == usdcBalanceBefore + _usdcAmount, "USDE: Deposit Failed");

        // Calculate the amount of USDE to mint (with 18 decimals)
        usdeAmount = _usdcAmount * DECIMALS_DIFFERENCE;

        // Mint the user the equivalent of USDE
        uint256 balBefore = balanceOf(msg.sender);

        _mint(msg.sender, usdeAmount);

        require(balanceOf(msg.sender) == balBefore + usdeAmount, "USDE: Mint Failed");

        emit Deposit(msg.sender, _usdcAmount, usdeAmount);
    }

    /// @dev Accounts for Token Decimals (from 18 dec => 6)
    function withdraw(uint256 usdeAmount) external nonReentrant returns (uint256) {
        require(balanceOf(msg.sender) >= usdeAmount, "USDE: Insufficient Balance");
        // Burn USDE first to protect against reentrancy
        _burn(msg.sender, usdeAmount);

        // Calculate the amount of USDC to transfer (with 6 decimals)
        uint256 usdcAmount = usdeAmount / DECIMALS_DIFFERENCE;

        // Transfer out equivalent of USDC
        USDC.safeTransfer(msg.sender, usdcAmount);

        emit Withdraw(msg.sender, usdeAmount, usdcAmount);

        return usdcAmount;
    }
}
