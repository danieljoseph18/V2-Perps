// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {Position} from "../../positions/Position.sol";
import {Trade} from "../Trade.sol";

interface ITradeStorage {
    event OrderRequestCreated(bytes32 indexed _orderKey, Position.Request indexed _request);
    event OrderRequestCancelled(bytes32 indexed _orderKey);
    event TradeExecuted(Position.Execution indexed _executionParams);
    event DecreaseTokenTransfer(address indexed _user, uint256 indexed _principle, int256 indexed _pnl);
    event LiquidatePosition(
        bytes32 indexed _positionKey, address indexed _liquidator, uint256 indexed _amountLiquidated, bool _isLong
    );
    event FeesProcessed(bytes32 indexed _positionKey, uint256 indexed _fundingFee, uint256 indexed _borrowFee);
    event FundingFeesClaimed(address _user, uint256 _fundingFees);
    event TradeStorageInitialised(
        uint256 indexed _liquidationFee, uint256 indexed _tradingFee, uint256 indexed _executionFee
    );
    event FeesSet(uint256 indexed _liquidationFee, uint256 indexed _tradingFee);
    event CollateralEdited(bytes32 indexed _positionKey, uint256 indexed _collateralDelta, bool indexed _isIncrease);
    event IncreasePosition(bytes32 indexed _positionKey, uint256 indexed _collateralDelta, uint256 indexed _sizeDelta);
    event DecreasePosition(bytes32 indexed _positionKey, uint256 indexed _collateralDelta, uint256 indexed _sizeDelta);
    event DeleteRequest(bytes32 indexed _positionKey, bool indexed _isLimit);
    event EditPosition(
        bytes32 indexed _positionKey,
        uint256 indexed _collateralDelta,
        uint256 indexed _sizeDelta,
        int256 _pnlDelta,
        bool _isIncrease
    );
    event PositionCreated(bytes32 indexed _positionKey, Position.Data indexed _position);
    event FundingFeeProcessed(address indexed _user, uint256 indexed _fundingFee);
    event FundingParamsUpdated(bytes32 indexed _positionKey, Position.FundingParams indexed _fundingParams);
    event BorrowingFeesProcessed(address indexed _user, uint256 indexed _borrowingFee);
    event BorrowingParamsUpdated(bytes32 indexed _positionKey, Position.BorrowingParams indexed _borrowingParams);
    event TakeProfitSet(
        bytes32 indexed _positionKey, uint256 indexed _takeProfitPrice, uint256 indexed _takeProfitSize
    );
    event StopLossSet(bytes32 indexed _positionKey, uint256 indexed _stopLossPrice, uint256 indexed _stopLossSize);

    function initialise(uint256 _liquidationFee, uint256 _tradingFee, uint256 _executionFee, uint256 _minCollateralUsd)
        external;
    function createOrderRequest(Position.Request calldata _request) external;
    function cancelOrderRequest(bytes32 _orderKey, bool _isLimit) external;
    function executeCollateralIncrease(Position.Execution memory _params, Trade.ExecuteCache memory _cache) external;
    function executeCollateralDecrease(Position.Execution memory _params, Trade.ExecuteCache memory _cache) external;
    function createNewPosition(Position.Execution memory _params, Trade.ExecuteCache memory _cache) external;
    function increaseExistingPosition(Position.Execution memory _params, Trade.ExecuteCache memory _cache) external;
    function decreaseExistingPosition(Position.Execution memory _params, Trade.ExecuteCache memory _cache) external;
    function liquidatePosition(Trade.ExecuteCache memory _cache, bytes32 _positionKey, address _liquidator) external;
    function setFees(uint256 _liquidationFee, uint256 _tradingFee) external;
    function claimFundingFees(bytes32 _positionKey) external;
    function getOpenPositionKeys(address _market, bool _isLong) external view returns (bytes32[] memory);
    function getOrderKeys(bool _isLimit) external view returns (bytes32[] memory orderKeys);
    function getRequestQueueLengths() external view returns (uint256 marketLen, uint256 limitLen);

    // Getters for public variables
    function liquidationFeeUsd() external view returns (uint256);
    function minCollateralUsd() external view returns (uint256);
    function tradingFee() external view returns (uint256);
    function executionFee() external view returns (uint256);
    function getOrder(bytes32 _key) external view returns (Position.Request memory _order);
    function getPosition(bytes32 _positionKey) external view returns (Position.Data memory);
}
