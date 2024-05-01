// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IERC20} from "../tokens/interfaces/IERC20.sol";
import {SafeTransferLib} from "../libraries/SafeTransferLib.sol";
import {ReentrancyGuard} from "../utils/ReentrancyGuard.sol";
import {OwnableRoles} from "../auth/OwnableRoles.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {IVault} from "../markets/interfaces/IVault.sol";
import {IMarketFactory} from "../factory/interfaces/IMarketFactory.sol";

contract GlobalFeeDistributor is ReentrancyGuard, OwnableRoles {
    using SafeTransferLib for IERC20;

    error FeeDistributor_InvalidMarket();
    error FeeDistributor_InvalidRewardTracker();

    event FeesAccumulated(address indexed vault, uint256 wethAmount, uint256 usdcAmount);
    event Distribute(address indexed vault, uint256 wethAmount, uint256 usdcAmount);

    struct FeeParams {
        uint256 wethAmount;
        uint256 usdcAmount;
        uint256 wethTokensPerInterval;
        uint256 usdcTokensPerInterval;
        uint256 lastDistributionTime;
    }

    IMarketFactory public marketFactory;

    uint256 private constant SECONDS_PER_WEEK = 1 weeks;

    address public rewardTracker;
    address public weth;
    address public usdc;

    mapping(address vault => FeeParams) public accumulatedFees;

    constructor(address _marketFactory, address _rewardTracker, address _weth, address _usdc) {
        _initializeOwner(msg.sender);
        marketFactory = IMarketFactory(_marketFactory);
        rewardTracker = _rewardTracker;
        weth = _weth;
        usdc = _usdc;
    }

    /**
     * =================================== Core Functions ===================================
     */
    function accumulateFees(uint256 _wethAmount, uint256 _usdcAmount) external {
        if (!marketFactory.isMarket(msg.sender)) revert FeeDistributor_InvalidMarket();
        address vault = address(IMarket(msg.sender).VAULT());

        // Transfer in the WETH and USDC
        IERC20(weth).safeTransferFrom(msg.sender, address(this), _wethAmount);
        IERC20(usdc).safeTransferFrom(msg.sender, address(this), _usdcAmount);

        // Get remaining rewards from last distribution period
        (uint256 distributedWeth, uint256 distributedUsdc) = pendingRewards(vault);
        uint256 wethRemaining = accumulatedFees[vault].wethAmount - distributedWeth;
        uint256 usdcRemaining = accumulatedFees[vault].usdcAmount - distributedUsdc;

        // Accumulate the fees
        accumulatedFees[vault].wethAmount += _wethAmount;
        accumulatedFees[vault].usdcAmount += _usdcAmount;
        accumulatedFees[vault].lastDistributionTime = block.timestamp;

        // Set the Tokens per interval (week) for WETH and USDC
        accumulatedFees[vault].wethTokensPerInterval = _wethAmount + wethRemaining / SECONDS_PER_WEEK;
        accumulatedFees[vault].usdcTokensPerInterval = _usdcAmount + usdcRemaining / SECONDS_PER_WEEK;
        // Emit an event
        emit FeesAccumulated(vault, _wethAmount, _usdcAmount);
    }

    function distribute(address _vault) external returns (uint256 wethAmount, uint256 usdcAmount) {
        if (msg.sender != rewardTracker) revert FeeDistributor_InvalidRewardTracker();
        (wethAmount, usdcAmount) = pendingRewards(_vault);
        if (wethAmount == 0 && usdcAmount == 0) return (wethAmount, usdcAmount);

        accumulatedFees[_vault].lastDistributionTime = block.timestamp;

        uint256 wethBalance = accumulatedFees[_vault].wethAmount;
        uint256 usdcBalance = accumulatedFees[_vault].usdcAmount;

        if (wethAmount > wethBalance) wethAmount = wethBalance;
        if (usdcAmount > usdcBalance) usdcAmount = usdcBalance;

        accumulatedFees[_vault].wethAmount -= wethAmount;
        accumulatedFees[_vault].usdcAmount -= usdcAmount;

        if (wethAmount > 0) IERC20(weth).safeTransfer(msg.sender, wethAmount);
        if (usdcAmount > 0) IERC20(usdc).safeTransfer(msg.sender, usdcAmount);

        emit Distribute(_vault, wethAmount, usdcAmount);
    }

    /**
     * =================================== Getter Functions ===================================
     */
    function pendingRewards(address _vault) public view returns (uint256 wethAmount, uint256 usdcAmount) {
        FeeParams memory feeParams = accumulatedFees[_vault];
        uint256 timeSinceLastUpdate = block.timestamp - feeParams.lastDistributionTime;
        if (block.timestamp == feeParams.lastDistributionTime) return (0, 0);
        uint256 wethReward = feeParams.wethTokensPerInterval * timeSinceLastUpdate;
        uint256 usdcReward = feeParams.usdcTokensPerInterval * timeSinceLastUpdate;

        return (wethReward, usdcReward);
    }

    function tokensPerInterval(address _vault)
        external
        view
        returns (uint256 wethTokensPerInterval, uint256 usdcTokensPerInterval)
    {
        FeeParams memory feeParams = accumulatedFees[_vault];
        return (feeParams.wethTokensPerInterval, feeParams.usdcTokensPerInterval);
    }
}
