// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Position} from "../../positions/Position.sol";
import {Execution} from "../Execution.sol";
import {IPriceFeed} from "../../oracle/interfaces/IPriceFeed.sol";
import {IMarket} from "../../markets/interfaces/IMarket.sol";

interface ITradeStorage {
    event TradeStorageInitialized(uint256 indexed _liquidationFee, uint256 indexed _tradingFee);
    event FeesSet(uint256 indexed _liquidationFee, uint256 indexed _tradingFee);

    error TradeStorage_AlreadyInitialized();
    error TradeStorage_OrderAlreadyExists();
    error TradeStorage_OrderAdditionFailed();
    error TradeStorage_PositionAdditionFailed();
    error TradeStorage_OrderRemovalFailed();
    error TradeStorage_PositionRemovalFailed();
    error TradeStorage_InvalidExecutionTime();

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
    function executeAdl(bytes32 _positionKey, bytes32 _requestId, address _feeReceiver) external;
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
    function minCollateralUsd() external view returns (uint256);
    function liquidationFee() external view returns (uint256);

    function deleteOrder(bytes32 _orderKey, bool _isLimit) external;
    function updateMarketState(
        Execution.State memory _state,
        string memory _ticker,
        uint256 _sizeDelta,
        bool _isLong,
        bool _isIncrease
    ) external;
    function updatePosition(Position.Data calldata _position, bytes32 _positionKey) external;
    function createPosition(Position.Data calldata _position, bytes32 _positionKey) external;
    function payFees(
        uint256 _borrowAmount,
        uint256 _positionFee,
        uint256 _affiliateRebate,
        address _referrer,
        bool _isLong
    ) external;
    function createOrder(Position.Request memory _request) external returns (bytes32 orderKey);
    function reserveLiquidity(
        uint256 _sizeDeltaUsd,
        uint256 _collateralDelta,
        uint256 _collateralPrice,
        uint256 _collateralBaseUnit,
        address _user,
        bool _isLong
    ) external;
    function unreserveLiquidity(
        uint256 _sizeDeltaUsd,
        uint256 _collateralDelta,
        uint256 _collateralPrice,
        uint256 _collateralBaseUnit,
        address _user,
        bool _isLong
    ) external;
    function deletePosition(bytes32 _positionKey, bool _isLong) external;
}
