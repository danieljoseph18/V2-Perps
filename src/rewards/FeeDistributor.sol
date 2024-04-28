// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IERC20} from "../tokens/interfaces/IERC20.sol";
import {SafeTransferLib} from "../libraries/SafeTransferLib.sol";
import {ReentrancyGuard} from "../utils/ReentrancyGuard.sol";
import {IFeeDistributor} from "./interfaces/IFeeDistributor.sol";
import {IRewardTracker} from "./interfaces/IRewardTracker.sol";
import {OwnableRoles} from "../auth/OwnableRoles.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {IVault} from "../markets/interfaces/IVault.sol";
import {IMarketFactory} from "../markets/interfaces/IMarketFactory.sol";

contract FeeDistributor is ReentrancyGuard, OwnableRoles {
    using SafeTransferLib for IERC20;

    error FeeDistributor_InvalidMarket();
    error FeeDistributor_InvalidRewardTracker();

    event FeesAccumulated(IMarket indexed market, uint256 wethAmount, uint256 usdcAmount);
    event Distribute(IMarket indexed market, uint256 wethAmount, uint256 usdcAmount);

    struct FeeParams {
        uint256 wethAmount;
        uint256 usdcAmount;
        uint256 wethTokensPerInterval;
        uint256 usdcTokensPerInterval;
        uint256 lastDistributionTime;
    }

    IMarketFactory public marketFactory;

    uint256 private constant SECONDS_PER_WEEK = 1 weeks;

    address public weth;
    address public usdc;

    mapping(IMarket market => FeeParams) public accumulatedFees;

    constructor(address _marketFactory, address _weth, address _usdc) {
        _initializeOwner(msg.sender);
        marketFactory = IMarketFactory(_marketFactory);
        weth = _weth;
        usdc = _usdc;
    }

    /**
     * =================================== Core Functions ===================================
     */
    function accumulateFees(uint256 _wethAmount, uint256 _usdcAmount) external {
        if (!marketFactory.isMarket(msg.sender)) revert FeeDistributor_InvalidMarket();
        IMarket market = IMarket(msg.sender);

        // Transfer in the WETH and USDC
        IERC20(weth).safeTransferFrom(msg.sender, address(this), _wethAmount);
        IERC20(usdc).safeTransferFrom(msg.sender, address(this), _usdcAmount);

        // Get remaining rewards from last distribution period
        (uint256 distributedWeth, uint256 distributedUsdc) = pendingRewards(market);
        uint256 wethRemaining = accumulatedFees[market].wethAmount - distributedWeth;
        uint256 usdcRemaining = accumulatedFees[market].usdcAmount - distributedUsdc;

        // Accumulate the fees
        accumulatedFees[market].wethAmount += _wethAmount;
        accumulatedFees[market].usdcAmount += _usdcAmount;
        accumulatedFees[market].lastDistributionTime = block.timestamp;

        // Set the Tokens per interval (week) for WETH and USDC
        accumulatedFees[market].wethTokensPerInterval = _wethAmount + wethRemaining / SECONDS_PER_WEEK;
        accumulatedFees[market].usdcTokensPerInterval = _usdcAmount + usdcRemaining / SECONDS_PER_WEEK;
        // Emit an event
        emit FeesAccumulated(market, _wethAmount, _usdcAmount);
    }

    function distribute(IMarket market) external returns (uint256 wethAmount, uint256 usdcAmount) {
        IVault vault = market.VAULT();
        if (msg.sender != address(vault.rewardTracker())) revert FeeDistributor_InvalidRewardTracker();
        (wethAmount, usdcAmount) = pendingRewards(market);
        if (wethAmount == 0 && usdcAmount == 0) return (wethAmount, usdcAmount);

        accumulatedFees[market].lastDistributionTime = block.timestamp;

        uint256 wethBalance = accumulatedFees[market].wethAmount;
        uint256 usdcBalance = accumulatedFees[market].usdcAmount;

        if (wethAmount > wethBalance) wethAmount = wethBalance;
        if (usdcAmount > usdcBalance) usdcAmount = usdcBalance;

        accumulatedFees[market].wethAmount -= wethAmount;
        accumulatedFees[market].usdcAmount -= usdcAmount;

        if (wethAmount > 0) IERC20(weth).safeTransfer(msg.sender, wethAmount);
        if (usdcAmount > 0) IERC20(usdc).safeTransfer(msg.sender, usdcAmount);

        emit Distribute(market, wethAmount, usdcAmount);
    }

    /**
     * =================================== Getter Functions ===================================
     */
    function pendingRewards(IMarket _market) public view returns (uint256 wethAmount, uint256 usdcAmount) {
        FeeParams memory feeParams = accumulatedFees[_market];
        uint256 timeSinceLastUpdate = block.timestamp - feeParams.lastDistributionTime;
        if (block.timestamp == feeParams.lastDistributionTime) return (0, 0);
        uint256 wethReward = feeParams.wethTokensPerInterval * timeSinceLastUpdate;
        uint256 usdcReward = feeParams.usdcTokensPerInterval * timeSinceLastUpdate;

        return (wethReward, usdcReward);
    }

    function tokensPerInterval(IMarket _market)
        external
        view
        returns (uint256 wethTokensPerInterval, uint256 usdcTokensPerInterval)
    {
        FeeParams memory feeParams = accumulatedFees[_market];
        return (feeParams.wethTokensPerInterval, feeParams.usdcTokensPerInterval);
    }
}
