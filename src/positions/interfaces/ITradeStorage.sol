// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Position} from "../../positions/Position.sol";
import {Execution} from "../Execution.sol";
import {IPriceFeed} from "../../oracle/interfaces/IPriceFeed.sol";

interface ITradeStorage {
    event OrderRequestCreated(bytes32 indexed _orderKey, Position.Request indexed _request);
    event OrderRequestCancelled(bytes32 indexed _orderKey);
    event TradeExecuted(Position.Settlement indexed _executionParams);
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
    event BorrowingFeesProcessed(address indexed _user, uint256 indexed _borrowingFee);
    event BorrowingParamsUpdated(bytes32 indexed _positionKey, Position.BorrowingParams indexed _borrowingParams);
    event TakeProfitSet(
        bytes32 indexed _positionKey, uint256 indexed _takeProfitPrice, uint256 indexed _takeProfitPercentage
    );
    event StopLossSet(
        bytes32 indexed _positionKey, uint256 indexed _stopLossPrice, uint256 indexed _stopLossPercentage
    );

    error TradeStorage_AlreadyInitialised();
    error TradeStorage_InvalidLiquidationFee();
    error TradeStorage_InvalidTradingFee();
    error TradeStorage_OrderAlreadyExists();
    error TradeStorage_PositionDoesNotExist();
    error TradeStorage_OrderDoesNotExist();
    error TradeStorage_PositionExists();
    error TradeStorage_NotLiquidatable();
    error TradeStorage_OrderAdditionFailed();
    error TradeStorage_PositionAdditionFailed();
    error TradeStorage_KeyAdditionFailed();
    error TradeStorage_InsufficientFreeLiquidity();

    function initialise(
        uint256 _liquidationFee,
        uint256 _tradingFee,
        uint256 _executionFee,
        uint256 _minCollateralUsd,
        uint256 _minCancellationTime
    ) external;
    function createOrderRequest(Position.Request calldata _request) external;
    function createEditOrder(Position.Conditionals memory _conditionals, bytes32 _positionKey) external;
    function cancelOrderRequest(bytes32 _orderKey, bool _isLimit) external;
    function executeCollateralIncrease(Position.Settlement memory _params, Execution.State memory _state) external;
    function executeCollateralDecrease(Position.Settlement memory _params, Execution.State memory _state) external;
    function createNewPosition(Position.Settlement memory _params, Execution.State memory _state) external;
    function increaseExistingPosition(Position.Settlement memory _params, Execution.State memory _state) external;
    function decreaseExistingPosition(Position.Settlement memory _params, Execution.State memory _state) external;
    function liquidatePosition(Execution.State memory _state, bytes32 _positionKey, address _liquidator) external;
    function setFees(uint256 _liquidationFee, uint256 _tradingFee) external;
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
    function getOrderAtIndex(uint256 _index, bool _isLimit) external view returns (bytes32);
    function minBlockDelay() external view returns (uint256);
}
