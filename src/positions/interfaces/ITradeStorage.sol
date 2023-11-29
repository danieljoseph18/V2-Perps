// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MarketStructs} from "../../markets/MarketStructs.sol";
import {IMarketStorage} from "../../markets/interfaces/IMarketStorage.sol";
import {ILiquidityVault} from "../../markets/interfaces/ILiquidityVault.sol";

interface ITradeStorage {
    function createOrderRequest(MarketStructs.PositionRequest calldata _positionRequest) external;

    function cancelOrderRequest(bytes32 _key, bool _isLimit) external;

    function executeTrade(MarketStructs.ExecutionParams calldata _executionParams)
        external
        returns (MarketStructs.Position memory);

    function executeDecreaseRequest(
        MarketStructs.PositionRequest calldata _decreaseRequest,
        uint256 _signedBlockPrice,
        address _executor,
        int256 _priceImpact
    ) external;

    function liquidatePosition(bytes32 _positionKey, address _liquidator) external;

    function setFees(uint256 _liquidationFee, uint256 _tradingFee) external;

    function getPositionFees(MarketStructs.Position calldata _position)
        external
        view
        returns (uint256, int256, uint256);

    function getOrderKeys() external view returns (bytes32[] memory, bytes32[] memory);

    function getRequestQueueLengths() external view returns (uint256, uint256);

    // Getters for public state variables
    function marketStorage() external view returns (IMarketStorage);
    function liquidationFeeUsd() external view returns (uint256);
    function tradingFee() external view returns (uint256);
    function minExecutionFee() external view returns (uint256);
    function minCollateralUsd() external view returns (uint256);
    function liquidityVault() external view returns (ILiquidityVault);
    function claimFundingFees(bytes32 _positionKey) external;
    function MIN_LEVERAGE() external pure returns (uint256);
    function MAX_LEVERAGE() external pure returns (uint256);
    function MAX_LIQUIDATION_FEE() external pure returns (uint256);
    function accumulatedRewards(address _user) external view returns (uint256);
    function openPositions(bytes32 _key) external view returns (MarketStructs.Position memory);
    function openPositionKeys(bytes32 _key, bool _isLong) external view returns (bytes32[] memory);
    function orders(bool _isLimit, bytes32 _key) external view returns (MarketStructs.PositionRequest memory);
    function updateCollateralBalance(bytes32 _marketKey, uint256 _amount, bool _isLong) external;
    function getNextPositionIndex(bytes32 _marketKey, bool _isLong) external view returns (uint256);
}
