// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {ITradeStorage} from "./interfaces/ITradeStorage.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {RoleValidation} from "../access/RoleValidation.sol";
import {Funding} from "../libraries/Funding.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Position} from "../positions/Position.sol";
import {mulDiv} from "@prb/math/Common.sol";
import {Execution} from "./Execution.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {ReentrancyGuard} from "@solmate/utils/ReentrancyGuard.sol";
import {IReferralStorage} from "../referrals/interfaces/IReferralStorage.sol";
import {MarketUtils} from "../markets/MarketUtils.sol";
import {Referral} from "../referrals/Referral.sol";
import {IPriceFeed} from "../oracle/interfaces/IPriceFeed.sol";
import {TradeLogic} from "./TradeLogic.sol";

contract TradeStorage is ITradeStorage, RoleValidation, ReentrancyGuard {
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using SignedMath for int256;

    IMarket public market;
    IReferralStorage public referralStorage;
    IPriceFeed public priceFeed;

    uint256 private constant MAX_TIME_TO_EXPIRATION = 3 minutes;
    uint256 private constant MIN_TIME_TO_EXPIRATION = 20 seconds;

    // User Enumerable Sets instead of a custom map to allow for easier querying.
    mapping(bytes32 _key => Position.Request _order) private orders;
    EnumerableSet.Bytes32Set private marketOrderKeys;
    EnumerableSet.Bytes32Set private limitOrderKeys;

    mapping(bytes32 _positionKey => Position.Data) private openPositions;
    mapping(bool _isLong => EnumerableSet.Bytes32Set _positionKeys) internal openPositionKeys;

    bool private isInitialized;
    uint256 public liquidationFee; // Stored as a percentage with 18 D.P (e.g 0.05e18 = 5%)
    uint256 private adlFee; // Stored as a percentage with 18 D.P (e.g 0.05e18 = 5%)
    uint256 public minCollateralUsd;

    uint256 public tradingFee;
    uint256 public feeForExecution; // Percentage of the Trading Fee, 18 D.P
    // @gas - consider changing to uint64
    uint256 public minCancellationTime;
    // Minimum time a keeper must execute their reserved transaction before it is
    // made available to the broader network.
    uint256 public minTimeForExecution;

    constructor(IMarket _market, IReferralStorage _referralStorage, IPriceFeed _priceFeed, address _roleStorage)
        RoleValidation(_roleStorage)
    {
        market = _market;
        referralStorage = _referralStorage;
        priceFeed = _priceFeed;
    }

    /**
     * ===================================== Setter Functions =====================================
     */
    function initialize(
        uint256 _liquidationFee, // 0.05e18 = 5%
        uint256 _positionFee, // 0.001e18 = 0.1%
        uint256 _adlFee, // Percentage of the output amount that goes to the ADL executor, 18 D.P
        uint256 _feeForExecution, // Percentage of the Trading Fee that goes to the keeper, 18 D.P
        uint256 _minCollateralUsd, // 2e30 = 2 USD
        uint256 _minCancellationTime, // e.g 1 minutes
        uint256 _minTimeForExecution // e.g 1 minutes
    ) external onlyMarketFactory {
        if (isInitialized) revert TradeStorage_AlreadyInitialized();
        liquidationFee = _liquidationFee;
        tradingFee = _positionFee;
        minCollateralUsd = _minCollateralUsd;
        minCancellationTime = _minCancellationTime;
        minTimeForExecution = _minTimeForExecution;
        adlFee = _adlFee;
        feeForExecution = _feeForExecution;
        isInitialized = true;
        emit TradeStorageInitialized(_liquidationFee, _positionFee);
    }

    // Time until a position request can be cancelled by a user
    function setMinCancellationTime(uint256 _minCancellationTime) external onlyConfigurator(address(market)) {
        if (_minCancellationTime > MAX_TIME_TO_EXPIRATION || _minCancellationTime < MIN_TIME_TO_EXPIRATION) {
            revert TradeStorage_InvalidExecutionTime();
        }
        minCancellationTime = _minCancellationTime;
    }

    // Time until a position request can be executed by the broader keeper network
    function setMinTimeForExecution(uint256 _minTimeForExecution) external onlyConfigurator(address(market)) {
        if (_minTimeForExecution > MAX_TIME_TO_EXPIRATION || _minTimeForExecution < MIN_TIME_TO_EXPIRATION) {
            revert TradeStorage_InvalidExecutionTime();
        }
        minTimeForExecution = _minTimeForExecution;
    }

    function setFees(uint256 _liquidationFee, uint256 _positionFee, uint256 _adlFee, uint256 _feeForExecution)
        external
        onlyConfigurator(address(market))
    {
        TradeLogic.validateFees(_liquidationFee, _positionFee, _adlFee, _feeForExecution);
        liquidationFee = _liquidationFee;
        tradingFee = _positionFee;
        adlFee = _adlFee;
        feeForExecution = _feeForExecution;
        emit FeesSet(_liquidationFee, _positionFee);
    }

    /**
     * ===================================== Order Functions =====================================
     */

    /// @dev Adds Order to EnumerableSet
    function createOrderRequest(Position.Request calldata _request) external onlyRouter {
        TradeLogic.createOrderRequest(_request);
    }

    function cancelOrderRequest(bytes32 _orderKey, bool _isLimit) external onlyPositionManager {
        TradeLogic.cancelOrderRequest(_orderKey, _isLimit);
    }

    /**
     * ===================================== Execution Functions =====================================
     */

    /// @dev needs to accept request id for limit order cases
    /// the request id at request time won't be the same as the request id at execution time
    function executePositionRequest(bytes32 _orderKey, bytes32 _requestId, address _feeReceiver)
        external
        onlyPositionManager
        nonReentrant
        returns (Execution.State memory state, Position.Request memory request)
    {
        return
            TradeLogic.executePositionRequest(market, priceFeed, referralStorage, _orderKey, _requestId, _feeReceiver);
    }

    function liquidatePosition(bytes32 _positionKey, bytes32 _requestId, address _liquidator)
        external
        onlyPositionManager
        nonReentrant
    {
        TradeLogic.liquidatePosition(market, priceFeed, _positionKey, _requestId, _liquidator);
    }

    function executeAdl(bytes32 _positionKey, bytes32 _requestId, uint256 _sizeDelta, address _feeReceiver)
        external
        onlyPositionManager
        nonReentrant
    {
        TradeLogic.executeAdl(market, priceFeed, _positionKey, _requestId, _sizeDelta, _feeReceiver, adlFee);
    }

    /**
     * ===================================== Callback Functions =====================================
     */
    function deleteOrder(bytes32 _orderKey, bool _isLimit) external onlyCallback {
        bool success = _isLimit ? limitOrderKeys.remove(_orderKey) : marketOrderKeys.remove(_orderKey);
        if (!success) revert TradeStorage_OrderRemovalFailed();
        delete orders[_orderKey];
    }

    function updateMarketState(
        Execution.State memory _state,
        string memory _ticker,
        uint256 _sizeDelta,
        bool _isLong,
        bool _isIncrease
    ) external onlyCallback {
        // Update the Market State
        market.updateMarketState(
            _ticker,
            _sizeDelta,
            _state.indexPrice,
            _state.impactedPrice,
            _state.collateralPrice,
            _state.indexBaseUnit,
            _isLong,
            _isIncrease
        );
        // If Price Impact is Negative, add to the impact Pool
        // If Price Impact is Positive, Subtract from the Impact Pool
        // Impact Pool Delta = -1 * Price Impact
        if (_state.priceImpactUsd == 0) return;
        market.updateImpactPool(_ticker, -_state.priceImpactUsd);
    }

    function updatePosition(Position.Data calldata _position, bytes32 _positionKey) external onlyCallback {
        openPositions[_positionKey] = _position;
    }

    function createPosition(Position.Data calldata _position, bytes32 _positionKey) external onlyCallback {
        openPositions[_positionKey] = _position;
        bool success = openPositionKeys[_position.isLong].add(_positionKey);
        if (!success) revert TradeStorage_PositionAdditionFailed();
    }

    function payFees(
        uint256 _borrowAmount,
        uint256 _positionFee,
        uint256 _affiliateRebate,
        address _referrer,
        bool _isLong
    ) external onlyCallback {
        // Pay Fees to LPs for Side (Position + Borrow)
        market.accumulateFees(_borrowAmount + _positionFee, _isLong);
        // Pay Affiliate Rebate to Referrer
        if (_affiliateRebate > 0) {
            referralStorage.accumulateAffiliateRewards(address(market), _referrer, _isLong, _affiliateRebate);
        }
    }

    function createOrder(Position.Request memory _request) external onlyCallback returns (bytes32 orderKey) {
        // Generate the Key
        orderKey = Position.generateOrderKey(_request);
        // Create a Storage Pointer to the Order Set
        EnumerableSet.Bytes32Set storage orderSet = _request.input.isLimit ? limitOrderKeys : marketOrderKeys;
        // Check if the Order already exists
        if (orderSet.contains(orderKey)) revert TradeStorage_OrderAlreadyExists();
        // Add the Order to the Set
        bool success = orderSet.add(orderKey);
        if (!success) revert TradeStorage_OrderAdditionFailed();
        orders[orderKey] = _request;
    }

    function reserveLiquidity(
        uint256 _sizeDeltaUsd,
        uint256 _collateralDelta,
        uint256 _collateralPrice,
        uint256 _collateralBaseUnit,
        address _user,
        bool _isLong
    ) external onlyCallback {
        // Convert Size Delta USD to Collateral Tokens
        uint256 reserveDelta = mulDiv(_sizeDeltaUsd, _collateralBaseUnit, _collateralPrice);
        // Reserve an Amount of Liquidity Equal to the Position Size
        market.updateLiquidityReservation(reserveDelta, _isLong, true);
        // Register the Collateral in
        market.updateCollateralAmount(_collateralDelta, _user, _isLong, true);
    }

    function unreserveLiquidity(
        uint256 _sizeDeltaUsd,
        uint256 _collateralDelta,
        uint256 _collateralPrice,
        uint256 _collateralBaseUnit,
        address _user,
        bool _isLong
    ) external onlyCallback {
        // Convert Size Delta USD to Collateral Tokens
        uint256 reserveDelta = (mulDiv(_sizeDeltaUsd, _collateralBaseUnit, _collateralPrice)); // Could use collateral delta * leverage for gas savings?
        // Unreserve an Amount of Liquidity Equal to the Position Size
        market.updateLiquidityReservation(reserveDelta, _isLong, false);
        // Register the Collateral out
        market.updateCollateralAmount(_collateralDelta, _user, _isLong, false);
    }

    function deletePosition(bytes32 _positionKey, bool _isLong) external onlyCallback {
        delete openPositions[_positionKey];
        bool success = openPositionKeys[_isLong].remove(_positionKey);
        if (!success) revert TradeStorage_PositionRemovalFailed();
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

    function getPosition(bytes32 _positionKey) external view returns (Position.Data memory) {
        return openPositions[_positionKey];
    }

    function getOrder(bytes32 _orderKey) external view returns (Position.Request memory) {
        return orders[_orderKey];
    }

    function getOrderAtIndex(uint256 _index, bool _isLimit) external view returns (bytes32) {
        return _isLimit ? limitOrderKeys.at(_index) : marketOrderKeys.at(_index);
    }
}
