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
import {TradeEngine} from "./TradeEngine.sol";
import {IVault} from "../markets/interfaces/IVault.sol";

/// @notice Contract responsible for storing the state of active trades / requests
contract TradeStorage is ITradeStorage, OwnableRoles, ReentrancyGuard {
    using EnumerableSetLib for EnumerableSetLib.Bytes32Set;

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

    // Stored as percentages with 18 D.P (e.g 0.05e18 = 5%)
    uint64 public liquidationFee;
    uint64 public adlFee;
    uint64 public tradingFee;
    uint64 public feeForExecution;

    uint64 public minCancellationTime;
    uint256 public minCollateralUsd;

    constructor(IMarket _market, IVault _vault, IReferralStorage _referralStorage, IPriceFeed _priceFeed) {
        _initializeOwner(msg.sender);
        market = _market;
        vault = _vault;
        referralStorage = _referralStorage;
        priceFeed = _priceFeed;
    }

    /**
     * =========================================== Setter Functions ===========================================
     */
    function initialize(
        uint64 _liquidationFee,
        uint64 _positionFee,
        uint64 _adlFee,
        uint64 _feeForExecution,
        uint256 _minCollateralUsd,
        uint64 _minCancellationTime
    ) external onlyOwner {
        if (isInitialized) revert TradeStorage_AlreadyInitialized();
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
     * =========================================== Order Functions ===========================================
     */
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

    function createOrder(Position.Request memory _request) external onlyRoles(_ROLE_3) returns (bytes32 orderKey) {
        orders[orderKey] = _request;
    }

    /**
     * =========================================== Callback Functions ===========================================
     */

    /// @dev - Should only be callable within the TradeEngine library
    function deletePosition(bytes32 _positionKey, bool _isLong) external {
        if (!_isCallback()) revert TradeStorage_InvalidCallback();
        delete openPositions[_positionKey];
        bool success = openPositionKeys[_isLong].remove(_positionKey);
        if (!success) revert TradeStorage_PositionRemovalFailed();
    }

    /// @dev - Should only be callable within the TradeEngine library
    function createPosition(Position.Data calldata _position, bytes32 _positionKey) external {
        if (!_isCallback()) revert TradeStorage_InvalidCallback();
        openPositions[_positionKey] = _position;
        bool success = openPositionKeys[_position.isLong].add(_positionKey);
        if (!success) revert TradeStorage_PositionAdditionFailed();
    }

    /// @dev - Should only be callable within the TradeEngine library
    function deleteOrder(bytes32 _orderKey, bool _isLimit) external {
        if (!_isCallback()) revert TradeStorage_InvalidCallback();
        _deleteOrder(_orderKey, _isLimit);
    }

    /// @dev - Should only be callable within the TradeEngine library
    function updatePosition(Position.Data calldata _position, bytes32 _positionKey) external {
        if (!_isCallback()) revert TradeStorage_InvalidCallback();
        openPositions[_positionKey] = _position;
    }

    /**
     * =========================================== Execution Functions ===========================================
     */

    /// @dev needs to accept request id for limit order cases
    /// the request id at the time of request won't be the same as the request id at execution time
    /// @notice the main function responsible for execution of position requests
    function executePositionRequest(bytes32 _orderKey, bytes32 _limitRequestKey, address _feeReceiver)
        external
        onlyRoles(_ROLE_1)
        nonReentrant
        returns (Execution.FeeState memory feeState, Position.Request memory request)
    {
        Position.Settlement memory params;
        params.orderKey = _orderKey;
        params.limitRequestKey = _limitRequestKey;
        params.feeReceiver = _feeReceiver;
        return
            TradeEngine.executePositionRequest(market, priceFeed, IPositionManager(msg.sender), referralStorage, params);
    }

    function liquidatePosition(bytes32 _positionKey, bytes32 _requestKey, address _liquidator)
        external
        onlyRoles(_ROLE_1)
        nonReentrant
    {
        TradeEngine.liquidatePosition(market, priceFeed, referralStorage, _positionKey, _requestKey, _liquidator);
    }

    function executeAdl(bytes32 _positionKey, bytes32 _requestKey, address _feeReceiver)
        external
        onlyRoles(_ROLE_1)
        nonReentrant
    {
        TradeEngine.executeAdl(market, priceFeed, referralStorage, _positionKey, _requestKey, _feeReceiver);
    }

    /**
     * =========================================== Private Functions ===========================================
     */
    function _deleteOrder(bytes32 _orderKey, bool _isLimit) private {
        bool success = _isLimit ? limitOrderKeys.remove(_orderKey) : marketOrderKeys.remove(_orderKey);
        if (!success) revert TradeStorage_OrderRemovalFailed();
        delete orders[_orderKey];
        emit OrderRequestCancelled(_orderKey);
    }

    /// @dev Attaches a Conditional Order to a live Position
    function _attachConditionalOrder(Position.Request calldata _request, bytes32 _orderKey) private {
        bytes32 positionKey = Position.generateKey(_request);

        Position.Data memory position = openPositions[positionKey];

        if (position.user == address(0)) revert TradeStorage_InactivePosition();

        if (_request.requestType == Position.RequestType.STOP_LOSS) {
            if (position.stopLossKey != bytes32(0)) revert TradeStorage_StopLossAlreadySet();
            position.stopLossKey = _orderKey;
            openPositions[positionKey] = position;
        } else if (_request.requestType == Position.RequestType.TAKE_PROFIT) {
            if (position.takeProfitKey != bytes32(0)) revert TradeStorage_TakeProfitAlreadySet();
            position.takeProfitKey = _orderKey;
            openPositions[positionKey] = position;
        }
    }

    function _isCallback() private view returns (bool) {
        return msg.sender == address(this);
    }

    /**
     * =========================================== Getter Functions ===========================================
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
