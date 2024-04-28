// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {ITradeStorage} from "./interfaces/ITradeStorage.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {OwnableRoles} from "../auth/OwnableRoles.sol";
import {Funding} from "../libraries/Funding.sol";
import {EnumerableSetLib} from "../libraries/EnumerableSetLib.sol";
import {Position} from "../positions/Position.sol";
import {Execution} from "./Execution.sol";
import {ReentrancyGuard} from "../utils/ReentrancyGuard.sol";
import {IReferralStorage} from "../referrals/interfaces/IReferralStorage.sol";
import {MarketUtils} from "../markets/MarketUtils.sol";
import {Referral} from "../referrals/Referral.sol";
import {IPriceFeed} from "../oracle/interfaces/IPriceFeed.sol";
import {IPositionManager} from "../router/interfaces/IPositionManager.sol";
import {ITradeEngine} from "./interfaces/ITradeEngine.sol";
import {IVault} from "../markets/interfaces/IVault.sol";

/// @notice Contract responsible for storing the state of active trades / requests
contract TradeStorage is ITradeStorage, OwnableRoles, ReentrancyGuard {
    using EnumerableSetLib for EnumerableSetLib.Bytes32Set;

    ITradeEngine public tradeEngine;
    IMarket public market;
    IVault public vault;
    IReferralStorage public referralStorage;
    IPriceFeed public priceFeed;

    uint8 private constant MAX_TIME_TO_EXPIRATION = 3 minutes;
    uint8 private constant MIN_TIME_TO_EXPIRATION = 20 seconds;

    mapping(bytes32 _key => Position.Request _order) private orders;
    EnumerableSetLib.Bytes32Set private marketOrderKeys;
    EnumerableSetLib.Bytes32Set private limitOrderKeys;

    mapping(bytes32 _positionKey => Position.Data) private openPositions;
    mapping(bool _isLong => EnumerableSetLib.Bytes32Set _positionKeys) private openPositionKeys;

    bool private isInitialized;
    uint64 public liquidationFee; // Stored as a percentage with 18 D.P (e.g 0.05e18 = 5%)
    uint64 public adlFee; // Stored as a percentage with 18 D.P (e.g 0.05e18 = 5%)
    uint64 public tradingFee;
    uint64 public feeForExecution; // Percentage of the Trading Fee, 18 D.P
    uint256 public minCollateralUsd;
    uint64 public minCancellationTime;

    constructor(IMarket _market, IVault _vault, IReferralStorage _referralStorage, IPriceFeed _priceFeed) {
        _initializeOwner(msg.sender);
        market = _market;
        vault = _vault;
        referralStorage = _referralStorage;
        priceFeed = _priceFeed;
    }

    /**
     * ===================================== Setter Functions =====================================
     */
    function initialize(
        ITradeEngine _tradeEngine,
        uint64 _liquidationFee, // 0.05e18 = 5%
        uint64 _positionFee, // 0.001e18 = 0.1%
        uint64 _adlFee, // Percentage of the output amount that goes to the ADL executor, 18 D.P
        uint64 _feeForExecution, // Percentage of the Trading Fee that goes to the keeper, 18 D.P
        uint256 _minCollateralUsd, // 2e30 = 2 USD
        uint64 _minCancellationTime // e.g 1 minutes
    ) external onlyOwner {
        if (isInitialized) revert TradeStorage_AlreadyInitialized();
        tradeEngine = _tradeEngine;
        liquidationFee = _liquidationFee;
        tradingFee = _positionFee;
        minCollateralUsd = _minCollateralUsd;
        minCancellationTime = _minCancellationTime;
        adlFee = _adlFee;
        feeForExecution = _feeForExecution;
        isInitialized = true;
        emit TradeStorageInitialized(_liquidationFee, _positionFee);
    }

    // Time until a position request can be cancelled by a user
    function setMinCancellationTime(uint64 _minCancellationTime) external onlyRoles(_ROLE_2) {
        if (_minCancellationTime > MAX_TIME_TO_EXPIRATION || _minCancellationTime < MIN_TIME_TO_EXPIRATION) {
            revert TradeStorage_InvalidExecutionTime();
        }
        minCancellationTime = _minCancellationTime;
    }

    function setFees(uint64 _liquidationFee, uint64 _positionFee, uint64 _adlFee, uint64 _feeForExecution)
        external
        onlyRoles(_ROLE_2)
    {
        Position.validateFees(_liquidationFee, _positionFee, _adlFee, _feeForExecution);
        liquidationFee = _liquidationFee;
        tradingFee = _positionFee;
        adlFee = _adlFee;
        feeForExecution = _feeForExecution;
        emit FeesSet(_liquidationFee, _positionFee);
    }

    function updatePriceFeed(IPriceFeed _priceFeed) external onlyOwner {
        priceFeed = _priceFeed;
    }

    /**
     * ===================================== Order Functions =====================================
     */

    /// @dev Adds Order to EnumerableSetLib
    function createOrderRequest(Position.Request calldata _request) external onlyRoles(_ROLE_3) {
        EnumerableSetLib.Bytes32Set storage orderSet = _request.input.isLimit ? limitOrderKeys : marketOrderKeys;

        bytes32 orderKey = Position.generateOrderKey(_request);
        if (orderSet.contains(orderKey)) revert TradeStorage_OrderAlreadyExists();

        bool success = orderSet.add(orderKey);
        if (!success) revert TradeStorage_OrderAdditionFailed();

        orders[orderKey] = _request;

        if (_request.requestType >= Position.RequestType.STOP_LOSS) _attachConditionalOrder(_request, orderKey);
    }

    function cancelOrderRequest(bytes32 _orderKey, bool _isLimit) external onlyRoles(_ROLE_1) {
        _deleteOrder(_orderKey, _isLimit);
    }

    function setStopLoss(bytes32 _stopLossKey, bytes32 _requestKey) external onlyRoles(_ROLE_3) {
        orders[_requestKey].stopLossKey = _stopLossKey;
    }

    function setTakeProfit(bytes32 _takeProfitKey, bytes32 _requestKey) external onlyRoles(_ROLE_3) {
        orders[_requestKey].takeProfitKey = _takeProfitKey;
    }

    function deletePosition(bytes32 _positionKey, bool _isLong) external onlyRoles(_ROLE_5) {
        delete openPositions[_positionKey];
        bool success = openPositionKeys[_isLong].remove(_positionKey);
        if (!success) revert TradeStorage_PositionRemovalFailed();
    }

    function createPosition(Position.Data calldata _position, bytes32 _positionKey) external onlyRoles(_ROLE_5) {
        openPositions[_positionKey] = _position;
        bool success = openPositionKeys[_position.isLong].add(_positionKey);
        if (!success) revert TradeStorage_PositionAdditionFailed();
    }

    function deleteOrder(bytes32 _orderKey, bool _isLimit) external onlyRoles(_ROLE_5) {
        _deleteOrder(_orderKey, _isLimit);
    }

    function updatePosition(Position.Data calldata _position, bytes32 _positionKey) external onlyRoles(_ROLE_5) {
        openPositions[_positionKey] = _position;
    }

    function createOrder(Position.Request memory _request) external onlyRoles(_ROLE_3) returns (bytes32 orderKey) {
        orders[orderKey] = _request;
    }

    /**
     * ===================================== Execution Functions =====================================
     */

    /// @dev needs to accept request id for limit order cases
    /// the request id at request time won't be the same as the request id at execution time
    /// @notice Executes a Request for a Position
    /// Called by keepers --> Routes the execution down the correct path.
    function executePositionRequest(bytes32 _orderKey, bytes32 _requestKey, address _feeReceiver)
        external
        onlyRoles(_ROLE_1)
        nonReentrant
        returns (Execution.FeeState memory feeState, Position.Request memory request)
    {
        return tradeEngine.executePositionRequest(
            vault, priceFeed, IPositionManager(msg.sender), referralStorage, _orderKey, _requestKey, _feeReceiver
        );
    }

    function liquidatePosition(bytes32 _positionKey, bytes32 _requestKey, address _liquidator)
        external
        onlyRoles(_ROLE_1)
        nonReentrant
    {
        tradeEngine.liquidatePosition(vault, referralStorage, priceFeed, _positionKey, _requestKey, _liquidator);
    }

    function executeAdl(bytes32 _positionKey, bytes32 _requestKey, address _feeReceiver)
        external
        onlyRoles(_ROLE_1)
        nonReentrant
    {
        tradeEngine.executeAdl(vault, referralStorage, priceFeed, _positionKey, _requestKey, _feeReceiver);
    }

    /**
     * ===================================== Private Functions =====================================
     */
    function _deleteOrder(bytes32 _orderKey, bool _isLimit) private {
        bool success = _isLimit ? limitOrderKeys.remove(_orderKey) : marketOrderKeys.remove(_orderKey);
        if (!success) revert TradeStorage_OrderRemovalFailed();
        delete orders[_orderKey];
        emit OrderRequestCancelled(_orderKey);
    }

    /// @dev - Attaches a Conditional Order to a live Position --> Let's us ensure SL / TP orders only affect the position they're assigned to.
    function _attachConditionalOrder(Position.Request calldata _request, bytes32 _orderKey) private {
        bytes32 positionKey = Position.generateKey(_request);
        Position.Data memory position = openPositions[positionKey];
        if (position.user == address(0)) revert TradeStorage_InactivePosition();
        // If Request is a SL, tie to the Stop Loss Key for the Position
        if (_request.requestType == Position.RequestType.STOP_LOSS) {
            if (position.stopLossKey != bytes32(0)) revert TradeStorage_StopLossAlreadySet();
            position.stopLossKey = _orderKey;
            openPositions[positionKey] = position;
        } else if (_request.requestType == Position.RequestType.TAKE_PROFIT) {
            // If Request is a TP, tie to the Take Profit Key for the Position
            if (position.takeProfitKey != bytes32(0)) revert TradeStorage_TakeProfitAlreadySet();
            position.takeProfitKey = _orderKey;
            openPositions[positionKey] = position;
        }
    }

    /**
     * ===================================== Getter Functions =====================================
     */
    function getOpenPositionKeys(bool _isLong) external view returns (bytes32[] memory) {
        return openPositionKeys[_isLong].values();
    }

    function getOrderKeys(bool _isLimit) external view returns (bytes32[] memory orderKeys) {
        orderKeys = _isLimit ? limitOrderKeys.values() : marketOrderKeys.values();
    }

    /// @notice - Get the position data for a given position key. Reverts if invalid.
    function getPosition(bytes32 _positionKey) external view returns (Position.Data memory position) {
        position = openPositions[_positionKey];
    }

    /// @notice - Get the request data for a given order key. Reverts if invalid.
    function getOrder(bytes32 _orderKey) external view returns (Position.Request memory order) {
        order = orders[_orderKey];
    }

    function getOrderAtIndex(uint256 _index, bool _isLimit) external view returns (bytes32) {
        return _isLimit ? limitOrderKeys.at(_index) : marketOrderKeys.at(_index);
    }
}
