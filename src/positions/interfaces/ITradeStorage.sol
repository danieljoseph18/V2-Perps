// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Position} from "../../positions/Position.sol";
import {Execution} from "../Execution.sol";
import {IPriceFeed} from "../../oracle/interfaces/IPriceFeed.sol";
import {IMarket} from "../../markets/interfaces/IMarket.sol";

interface ITradeStorage {
    event OrderRequestCreated(bytes32 indexed _orderKey);
    event OrderRequestCancelled(bytes32 indexed _orderKey);
    event LiquidatePosition(
        bytes32 indexed _positionKey, address indexed _liquidator, uint256 indexed _amountLiquidated, bool _isLong
    );
    event TradeStorageInitialized(uint256 indexed _liquidationFee, uint256 indexed _tradingFee);
    event FeesSet(uint256 indexed _liquidationFee, uint256 indexed _tradingFee);
    event CollateralEdited(bytes32 indexed _positionKey, uint256 indexed _collateralDelta, bool indexed _isIncrease);
    event PositionCreated(bytes32 indexed _positionKey);
    event AdlExecuted(address _market, bytes32 _positionKey, uint256 _sizeDelta, bool _isLong);
    event IncreasePosition(bytes32 indexed _positionKey, uint256 indexed _collateralDelta, uint256 indexed _sizeDelta);
    event DecreasePosition(bytes32 indexed _positionKey, uint256 indexed _collateralDelta, uint256 indexed _sizeDelta);

    error TradeStorage_AlreadyInitialized();
    error TradeStorage_InvalidLiquidationFee();
    error TradeStorage_InvalidTradingFee();
    error TradeStorage_OrderAlreadyExists();
    error TradeStorage_PositionDoesNotExist();
    error TradeStorage_OrderAdditionFailed();
    error TradeStorage_PositionAdditionFailed();
    error TradeStorage_InsufficientFreeLiquidity();
    error TradeStorage_OrderRemovalFailed();
    error TradeStorage_PositionRemovalFailed();
    error TradeStorage_StopLossAlreadySet();
    error TradeStorage_TakeProfitAlreadySet();
    error TradeStorage_InvalidRequestType();

    function initialize(
        uint256 _liquidationFee, // 0.05e18 = 5%
        uint256 _positionFee, // 0.001e18 = 0.1%
        uint256 _adlFee,
        uint256 _feeForExecution,
        uint256 _minCollateralUsd, // 2e30 = 2 USD
        uint256 _minCancellationTime, // e.g 1 minutes
        uint256 _minTimeForExecution // e.g 1 minutes
    ) external;
    function createOrderRequest(Position.Request calldata _request) external;
    function cancelOrderRequest(bytes32 _orderKey, bool _isLimit) external;
    function executePositionRequest(bytes32 _orderKey, bytes32 _requestId, address _feeReceiver)
        external
        returns (Execution.State memory state, Position.Request memory request);
    function liquidatePosition(bytes32 _positionKey, bytes32 _requestId, address _liquidator) external;
    function executeAdl(bytes32 _positionKey, bytes32 _requestId, uint256 _sizeDelta, address _feeReceiver) external;
    function setFees(uint256 _liquidationFee, uint256 _positionFee, uint256 _adlFee, uint256 _feeForExecution)
        external;
    function getOpenPositionKeys(bool _isLong) external view returns (bytes32[] memory);
    function getOrderKeys(bool _isLimit) external view returns (bytes32[] memory orderKeys);

    // Getters for public variables
    function tradingFee() external view returns (uint256);
    function feeForExecution() external view returns (uint256);
    function market() external view returns (IMarket);
    function getOrder(bytes32 _key) external view returns (Position.Request memory _order);
    function getPosition(bytes32 _positionKey) external view returns (Position.Data memory);
    function getOrderAtIndex(uint256 _index, bool _isLimit) external view returns (bytes32);
    function minCancellationTime() external view returns (uint256);
    function minTimeForExecution() external view returns (uint256);
    function priceFeed() external view returns (IPriceFeed);
}
