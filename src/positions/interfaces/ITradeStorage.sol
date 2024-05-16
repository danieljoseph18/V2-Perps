// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Position} from "../../positions/Position.sol";
import {Execution} from "../Execution.sol";
import {IPriceFeed} from "../../oracle/interfaces/IPriceFeed.sol";
import {IMarket} from "../../markets/interfaces/IMarket.sol";
import {IVault} from "../../markets/interfaces/IVault.sol";
import {MarketId, MarketIdLibrary} from "../../types/MarketId.sol";

interface ITradeStorage {
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
    error TradeStorage_InvalidCallback();

    function initialize(address _tradeEngine, address _marketFactory) external;
    function initializePool(MarketId _id, address _vault) external;

    function createOrderRequest(MarketId _id, Position.Request calldata _request) external returns (bytes32 orderKey);
    function cancelOrderRequest(MarketId _id, bytes32 _orderKey, bool _isLimit) external;
    function executePositionRequest(MarketId _id, bytes32 _orderKey, bytes32 _limitRequestKey, address _feeReceiver)
        external
        returns (Execution.FeeState memory feeState, Position.Request memory request);
    function liquidatePosition(MarketId _id, bytes32 _positionKey, bytes32 _requestKey, address _liquidator) external;
    function executeAdl(MarketId _id, bytes32 _positionKey, bytes32 _requestKey, address _feeReceiver) external;
    function getOpenPositionKeys(MarketId _id, bool _isLong) external view returns (bytes32[] memory);
    function getOrderKeys(MarketId _id, bool _isLimit) external view returns (bytes32[] memory orderKeys);

    // Getters for public variables
    function market() external view returns (IMarket);
    function priceFeed() external view returns (IPriceFeed);
    function minCancellationTime() external view returns (uint64);

    function getOrder(MarketId _id, bytes32 _key) external view returns (Position.Request memory _order);
    function getOrder(
        MarketId _id,
        string memory _ticker,
        address _user,
        bool _isLong,
        bool _isIncrease,
        uint256 _limitPrice
    ) external view returns (Position.Request memory);
    function getPosition(MarketId _id, bytes32 _positionKey) external view returns (Position.Data memory);
    function getOrderAtIndex(MarketId _id, uint256 _index, bool _isLimit) external view returns (bytes32);
    function deleteOrder(MarketId _id, bytes32 _orderKey, bool _isLimit) external;
    function updatePosition(MarketId _id, Position.Data calldata _position, bytes32 _positionKey) external;
    function createPosition(MarketId _id, Position.Data calldata _position, bytes32 _positionKey) external;
    function createOrder(MarketId _id, Position.Request memory _request) external returns (bytes32 orderKey);
    function setStopLoss(MarketId _id, bytes32 _stopLossKey, bytes32 _requestKey) external;
    function setTakeProfit(MarketId _id, bytes32 _takeProfitKey, bytes32 _requestKey) external;
    function deletePosition(MarketId _id, bytes32 _positionKey, bool _isLong) external;
}
