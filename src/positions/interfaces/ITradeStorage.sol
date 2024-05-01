// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Position} from "../../positions/Position.sol";
import {Execution} from "../Execution.sol";
import {IPriceFeed} from "../../oracle/interfaces/IPriceFeed.sol";
import {IMarket} from "../../markets/interfaces/IMarket.sol";

interface ITradeStorage {
    event TradeStorageInitialized(uint256 indexed _liquidationFee, uint256 indexed _tradingFee);
    event FeesSet(uint256 indexed _liquidationFee, uint256 indexed _tradingFee);
    event OrderRequestCancelled(bytes32 indexed _orderKey);

    error TradeStorage_AlreadyInitialized();
    error TradeStorage_OrderAlreadyExists();
    error TradeStorage_InactivePosition();
    error TradeStorage_OrderAdditionFailed();
    error TradeStorage_StopLossAlreadySet();
    error TradeStorage_TakeProfitAlreadySet();
    error TradeStorage_PositionAdditionFailed();
    error TradeStorage_OrderRemovalFailed();
    error TradeStorage_PositionRemovalFailed();
    error TradeStorage_InvalidExecutionTime();
    error TradeStorage_InvalidCallback();

    function initialize(
        uint64 _liquidationFee, // 0.05e18 = 5%
        uint64 _positionFee, // 0.001e18 = 0.1%
        uint64 _adlFee, // Percentage of the output amount that goes to the ADL executor, 18 D.P
        uint64 _feeForExecution, // Percentage of the Trading Fee that goes to the keeper, 18 D.P
        uint256 _minCollateralUsd, // 2e30 = 2 USD
        uint64 _minCancellationTime // e.g 1 minutes
    ) external;
    function createOrderRequest(Position.Request calldata _request) external;
    function cancelOrderRequest(bytes32 _orderKey, bool _isLimit) external;
    function executePositionRequest(bytes32 _orderKey, bytes32 _requestKey, address _feeReceiver)
        external
        returns (Execution.FeeState memory feeState, Position.Request memory request);
    function liquidatePosition(bytes32 _positionKey, bytes32 _requestKey, address _liquidator) external;
    function executeAdl(bytes32 _positionKey, bytes32 _requestKey, address _feeReceiver) external;
    function setFees(uint64 _liquidationFee, uint64 _positionFee, uint64 _adlFee, uint64 _feeForExecution) external;
    function getOpenPositionKeys(bool _isLong) external view returns (bytes32[] memory);
    function getOrderKeys(bool _isLimit) external view returns (bytes32[] memory orderKeys);

    // Getters for public variables
    function tradingFee() external view returns (uint64);
    function feeForExecution() external view returns (uint64);
    function market() external view returns (IMarket);
    function getOrder(bytes32 _key) external view returns (Position.Request memory _order);
    function getPosition(bytes32 _positionKey) external view returns (Position.Data memory);
    function getOrderAtIndex(uint256 _index, bool _isLimit) external view returns (bytes32);
    function minCancellationTime() external view returns (uint64);
    function priceFeed() external view returns (IPriceFeed);
    function minCollateralUsd() external view returns (uint256);
    function liquidationFee() external view returns (uint64);
    function adlFee() external view returns (uint64);
    function deleteOrder(bytes32 _orderKey, bool _isLimit) external;
    function updatePosition(Position.Data calldata _position, bytes32 _positionKey) external;
    function createPosition(Position.Data calldata _position, bytes32 _positionKey) external;
    function createOrder(Position.Request memory _request) external returns (bytes32 orderKey);
    function setStopLoss(bytes32 _stopLossKey, bytes32 _requestKey) external;
    function setTakeProfit(bytes32 _takeProfitKey, bytes32 _requestKey) external;
    function deletePosition(bytes32 _positionKey, bool _isLong) external;
}
