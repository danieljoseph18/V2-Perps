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
import {PositionInvariants} from "./PositionInvariants.sol";
import {ReentrancyGuard} from "@solmate/utils/ReentrancyGuard.sol";
import {IReferralStorage} from "../referrals/interfaces/IReferralStorage.sol";
import {MarketUtils} from "../markets/MarketUtils.sol";

/// @dev Needs TradeStorage Role & Fee Accumulator
/// @dev Need to add liquidity reservation for positions
contract TradeStorage is ITradeStorage, RoleValidation, ReentrancyGuard {
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using SignedMath for int256;

    IMarket public market;
    IReferralStorage public referralStorage;

    uint256 constant PRECISION = 1e18;
    uint256 constant MAX_LIQUIDATION_FEE = 0.5e18; // 50%
    uint256 constant MAX_TRADING_FEE = 0.01e18; // 1%
    uint256 constant ADJUSTMENT_FEE = 0.001e18; // 0.1%
    uint256 constant MIN_COLLATERAL = 1000;

    mapping(bytes32 _key => Position.Request _order) private orders;
    EnumerableSet.Bytes32Set private marketOrderKeys;
    EnumerableSet.Bytes32Set private limitOrderKeys;

    mapping(bytes32 _positionKey => Position.Data) private openPositions;
    mapping(bool _isLong => EnumerableSet.Bytes32Set _positionKeys) internal openPositionKeys;

    bool private isInitialized;

    uint256 public liquidationFee; // Stored as a percentage with 18 D.P (e.g 0.05e18 = 5%)
    uint256 public minCollateralUsd;
    uint256 public tradingFee;
    uint256 public minBlockDelay;

    constructor(IMarket _market, IReferralStorage _referralStorage, address _roleStorage)
        RoleValidation(_roleStorage)
    {
        market = _market;
        referralStorage = _referralStorage;
    }

    function initialize(
        uint256 _liquidationFee, // 0.05e18 = 5%
        uint256 _positionFee, // 0.001e18 = 0.1%
        uint256 _minCollateralUsd, // 2e18 = 2 USD
        uint256 _minBlockDelay // e.g 1 minutes
    ) external onlyMarketMaker {
        if (isInitialized) revert TradeStorage_AlreadyInitialized();
        liquidationFee = _liquidationFee;
        tradingFee = _positionFee;
        minCollateralUsd = _minCollateralUsd;
        minBlockDelay = _minBlockDelay;
        isInitialized = true;
        emit TradeStorageInitialized(_liquidationFee, _positionFee);
    }

    function setMinBlockDelay(uint256 _minBlockDelay) external onlyConfigurator(address(market)) {
        minBlockDelay = _minBlockDelay;
    }

    function setFees(uint256 _liquidationFee, uint256 _positionFee) external onlyConfigurator(address(market)) {
        if (!(_liquidationFee <= MAX_LIQUIDATION_FEE && _liquidationFee != 0)) {
            revert TradeStorage_InvalidLiquidationFee();
        }
        if (!(_positionFee <= MAX_TRADING_FEE && _positionFee != 0)) revert TradeStorage_InvalidTradingFee();
        liquidationFee = _liquidationFee;
        tradingFee = _positionFee;
        emit FeesSet(_liquidationFee, _positionFee);
    }

    /// @dev Adds Order to EnumerableSet
    function createOrderRequest(Position.Request calldata _request) external onlyRouter {
        // Generate the Key
        bytes32 orderKey = Position.generateOrderKey(_request);
        // Create a Storage Pointer to the Order Set
        EnumerableSet.Bytes32Set storage orderSet = _request.input.isLimit ? limitOrderKeys : marketOrderKeys;
        // Check if the Order already exists
        if (orderSet.contains(orderKey)) revert TradeStorage_OrderAlreadyExists();
        // Add the Order to the Set
        bool success = orderSet.add(orderKey);
        if (!success) revert TradeStorage_OrderAdditionFailed();
        orders[orderKey] = _request;
        // If SL / TP, tie to the position
        if (_request.requestType == Position.RequestType.STOP_LOSS) {
            bytes32 positionKey = Position.generateKey(_request);
            Position.Data memory position = openPositions[positionKey];
            if (position.user == address(0)) revert TradeStorage_PositionDoesNotExist();
            if (position.stopLossKey != bytes32(0)) revert TradeStorage_StopLossAlreadySet();
            openPositions[positionKey].stopLossKey = orderKey;
        } else if (_request.requestType == Position.RequestType.TAKE_PROFIT) {
            bytes32 positionKey = Position.generateKey(_request);
            Position.Data memory position = openPositions[positionKey];
            if (position.user == address(0)) revert TradeStorage_PositionDoesNotExist();
            if (position.takeProfitKey != bytes32(0)) revert TradeStorage_TakeProfitAlreadySet();
            openPositions[positionKey].takeProfitKey = orderKey;
        }
        // Fire Event
        emit OrderRequestCreated(orderKey, _request);
    }

    function cancelOrderRequest(bytes32 _orderKey, bool _isLimit) external onlyPositionManager {
        // Create a Storage Pointer to the Order Set
        EnumerableSet.Bytes32Set storage orderKeys = _isLimit ? limitOrderKeys : marketOrderKeys;
        // Check if the Order exists
        if (!orderKeys.contains(_orderKey)) revert TradeStorage_OrderDoesNotExist();
        // Remove the Order from the Set
        delete orders[_orderKey];
        bool success = orderKeys.remove(_orderKey);
        if (!success) revert TradeStorage_OrderRemovalFailed();
        // Fire Event
        emit OrderRequestCancelled(_orderKey);
    }

    function executeCollateralIncrease(Position.Settlement memory _params, Execution.State memory _state)
        external
        onlyPositionManager
        nonReentrant
    {
        // Check the Position exists
        bytes32 positionKey = Position.generateKey(_params.request);
        Position.Data memory positionBefore = openPositions[positionKey];
        if (!Position.exists(positionBefore)) revert TradeStorage_PositionDoesNotExist();
        // Delete the Order from Storage
        _deleteOrder(_params.orderKey, _params.request.input.isLimit);
        // Perform Execution in Library
        Position.Data memory positionAfter;
        (positionAfter, _state) = Execution.increaseCollateral(market, positionBefore, _params, _state);
        // Validate the Position Change
        PositionInvariants.validateCollateralIncrease(
            positionBefore,
            positionAfter,
            _params.request.input.collateralDelta,
            _state.fee,
            _state.borrowFee,
            _state.affiliateRebate
        );
        // Add Value to Stored Collateral Amount in Market
        market.updateCollateralAmount(
            _params.request.input.collateralDelta - _state.fee - _state.affiliateRebate - _state.borrowFee,
            _params.request.user,
            _params.request.input.isLong,
            true
        );

        _payFees(_state.borrowFee, _state.fee, _state.affiliateRebate, _state.referrer, _params.request.input.isLong);
        // Update Final Storage
        openPositions[positionKey] = positionAfter;
        emit CollateralEdited(positionKey, _params.request.input.collateralDelta, _params.request.input.isIncrease);
    }

    function executeCollateralDecrease(Position.Settlement memory _params, Execution.State memory _state)
        external
        onlyPositionManager
        nonReentrant
    {
        // Check the Position exists
        bytes32 positionKey = Position.generateKey(_params.request);
        Position.Data memory positionBefore = openPositions[positionKey];
        if (!Position.exists(positionBefore)) revert TradeStorage_PositionDoesNotExist();
        // Delete the Order from Storage
        _deleteOrder(_params.orderKey, _params.request.input.isLimit);
        // Perform Execution in Library
        Position.Data memory positionAfter;
        (positionAfter, _state) =
            Execution.decreaseCollateral(market, positionBefore, _params, _state, minCollateralUsd, liquidationFee);
        // Transfer Tokens to User
        uint256 amountOut =
            _params.request.input.collateralDelta - _state.fee - _state.affiliateRebate - _state.borrowFee;
        // Validate the Position Change
        PositionInvariants.validateCollateralDecrease(
            positionBefore, positionAfter, amountOut, _state.fee, _state.borrowFee, _state.affiliateRebate
        );
        // Check Market has enough available liquidity for payout
        if (
            MarketUtils.getPoolBalance(market, _params.request.input.assetId, _params.request.input.isLong)
                < amountOut + _state.affiliateRebate
        ) {
            revert TradeStorage_InsufficientFreeLiquidity();
        }
        // Decrease the Collateral Amount in the Market by the full delta
        market.updateCollateralAmount(
            _params.request.input.collateralDelta, _params.request.user, _params.request.input.isLong, false
        );
        // Pay Fees
        _payFees(_state.borrowFee, _state.fee, _state.affiliateRebate, _state.referrer, _params.request.input.isLong);
        // Update Final Storage
        openPositions[positionKey] = positionAfter;
        // Transfer Tokens to User
        market.transferOutTokens(
            _params.request.user, amountOut, _params.request.input.isLong, _params.request.input.reverseWrap
        );
        // Transfer Rebate to Referrer
        if (_state.affiliateRebate > 0) {
            market.transferOutTokens(
                _state.referrer,
                _state.affiliateRebate,
                _params.request.input.isLong,
                false // Leave unwrapped by default
            );
        }
        // Fire Event
        emit CollateralEdited(positionKey, _params.request.input.collateralDelta, _params.request.input.isIncrease);
    }

    function createNewPosition(Position.Settlement memory _params, Execution.State memory _state)
        external
        onlyPositionManager
        nonReentrant
    {
        // Check the Position doesn't exist
        bytes32 positionKey = Position.generateKey(_params.request);
        if (Position.exists(openPositions[positionKey])) revert TradeStorage_PositionExists();
        // Delete the Order from Storage
        _deleteOrder(_params.orderKey, _params.request.input.isLimit);
        // Perform Execution in the Library
        Position.Data memory position;
        (position, _state) = Execution.createNewPosition(market, _params, _state, minCollateralUsd);
        // Validate the New Position
        PositionInvariants.validateNewPosition(
            _params.request.input.collateralDelta, position.collateralAmount, _state.fee, _state.affiliateRebate
        );
        // If Request has conditionals, create the SL / TP
        (Position.Request memory stopLoss, Position.Request memory takeProfit) = Position.constructConditionalOrders(
            position, _params.request.input.conditionals, _params.request.input.executionFee
        );
        // If stop loss set, create and store the order
        if (_params.request.input.conditionals.stopLossSet) position.stopLossKey = _createStopLoss(stopLoss);
        // If take profit set, create and store the order
        if (_params.request.input.conditionals.takeProfitSet) position.takeProfitKey = _createTakeProfit(takeProfit);
        // Pay fees
        _payFees(0, _state.fee, _state.affiliateRebate, _state.referrer, _params.request.input.isLong);
        // Reserve Liquidity Equal to the Position Size
        _reserveLiquidity(
            _params.request.input.sizeDelta,
            position.collateralAmount,
            _state.collateralPrice,
            _state.collateralBaseUnit,
            position.user,
            _params.request.input.isLong
        );
        // Update Final Storage
        openPositions[positionKey] = position;
        bool success = openPositionKeys[position.isLong].add(positionKey);
        if (!success) revert TradeStorage_PositionAdditionFailed();
        // Fire Event
        emit PositionCreated(positionKey, position);
    }

    function increaseExistingPosition(Position.Settlement memory _params, Execution.State memory _state)
        external
        onlyPositionManager
        nonReentrant
    {
        // Check the Position exists
        bytes32 positionKey = Position.generateKey(_params.request);
        Position.Data memory positionBefore = openPositions[positionKey];
        if (!Position.exists(positionBefore)) revert TradeStorage_PositionDoesNotExist();
        // Delete the Order from Storage
        _deleteOrder(_params.orderKey, _params.request.input.isLimit);
        // Perform Execution in the Library
        Position.Data memory positionAfter;
        (positionAfter, _state) = Execution.increasePosition(market, positionBefore, _params, _state);
        // Validate the Position Change
        PositionInvariants.validateIncreasePosition(
            positionBefore,
            positionAfter,
            _params.request.input.collateralDelta,
            _state.fee,
            _state.affiliateRebate,
            _state.borrowFee,
            _params.request.input.sizeDelta
        );
        // Pay Fees
        _payFees(_state.borrowFee, _state.fee, _state.affiliateRebate, _state.referrer, _params.request.input.isLong);
        // Reserve Liquidity Equal to the Position Size
        _reserveLiquidity(
            _params.request.input.sizeDelta,
            _params.request.input.collateralDelta - _state.fee - _state.affiliateRebate - _state.borrowFee,
            _state.collateralPrice,
            _state.collateralBaseUnit,
            positionBefore.user,
            _params.request.input.isLong
        );
        // Update Final Storage
        openPositions[positionKey] = positionAfter;
    }

    function decreaseExistingPosition(Position.Settlement calldata _params, Execution.State memory _state)
        external
        onlyPositionManager
        nonReentrant
    {
        // Check the Position exists
        bytes32 positionKey = Position.generateKey(_params.request);
        Position.Data memory positionBefore = openPositions[positionKey];
        if (!Position.exists(positionBefore)) revert TradeStorage_PositionDoesNotExist();
        // Delete the Order from Storage
        if (!_params.isAdl) _deleteOrder(_params.orderKey, _params.request.input.isLimit);
        // If SL / TP, clear from the position
        if (_params.request.requestType == Position.RequestType.STOP_LOSS) {
            positionBefore.stopLossKey = bytes32(0);
        } else if (_params.request.requestType == Position.RequestType.TAKE_PROFIT) {
            positionBefore.takeProfitKey = bytes32(0);
        }
        // Perform Execution in the Library
        Position.Data memory positionAfter;
        Execution.DecreaseState memory decreaseState;
        (positionAfter, decreaseState, _state) =
            Execution.decreasePosition(market, positionBefore, _params, _state, minCollateralUsd, liquidationFee);
        // Validate the Position Change
        PositionInvariants.validateDecreasePosition(
            positionBefore,
            positionAfter,
            decreaseState.afterFeeAmount,
            _state.fee,
            _state.affiliateRebate,
            decreaseState.decreasePnl,
            _state.borrowFee,
            _params.request.input.sizeDelta
        );
        // Pay Fees
        _payFees(_state.borrowFee, _state.fee, _state.affiliateRebate, _state.referrer, _params.request.input.isLong);
        // Unreserve Liquidity Equal to the Position Size
        _unreserveLiquidity(
            _params.request.input.sizeDelta,
            _params.request.input.collateralDelta, // Full Amount
            _state.collateralPrice,
            _state.collateralBaseUnit,
            positionBefore.user,
            _params.request.input.isLong
        );
        // Update Final Storage
        openPositions[positionKey] = positionAfter;
        // Delete the Position if Full Decrease
        if (positionAfter.positionSize == 0 || positionAfter.collateralAmount == 0) {
            _deletePosition(positionKey, _params.request.input.isLong);
        }
        // Transfer Tokens to User
        uint256 amountOut = decreaseState.decreasePnl > 0
            ? decreaseState.afterFeeAmount + decreaseState.decreasePnl.abs() // Profit Case
            : decreaseState.afterFeeAmount; // Loss / Break Even Case -> Losses already deducted in Execution if any

        // Check Market has enough available liquidity for payout
        if (market.totalAvailableLiquidity(_params.request.input.isLong) < amountOut + _state.affiliateRebate) {
            revert TradeStorage_InsufficientFreeLiquidity();
        }
        // Transfer Tokens to User
        market.transferOutTokens(
            _params.request.user, amountOut, _params.request.input.isLong, _params.request.input.reverseWrap
        );
        // Transfer Rebate to Referrer
        if (_state.affiliateRebate > 0) {
            market.transferOutTokens(
                _state.referrer,
                _state.affiliateRebate,
                _params.request.input.isLong,
                false // Leave unwrapped by default
            );
        }
        // Fire Event
        emit DecreasePosition(positionKey, _params.request.input.collateralDelta, _params.request.input.sizeDelta);
    }

    function liquidatePosition(Execution.State memory _state, bytes32 _positionKey, address _liquidator)
        external
        onlyPositionManager
    {
        /* Update Initial Storage */
        Position.Data memory position = openPositions[_positionKey];
        if (!Position.exists(position)) revert TradeStorage_PositionDoesNotExist();

        uint256 remainingCollateral = position.collateralAmount;
        // delete the position from storage
        bool success = openPositionKeys[position.isLong].remove(_positionKey);
        if (!success) revert TradeStorage_PositionRemovalFailed();
        delete openPositions[_positionKey];

        (uint256 feesOwedToUser, uint256 feesToAccumulate, uint256 liqFeeInCollateral) =
            Position.liquidate(market, position, _state, liquidationFee);

        // unreserve all of the position's liquidity
        _unreserveLiquidity(
            position.positionSize,
            remainingCollateral,
            _state.collateralPrice,
            _state.collateralBaseUnit,
            position.user,
            position.isLong
        );
        // Remanining collateral after fees is added to the relevant pool
        market.increasePoolBalance(remainingCollateral, position.isLong);
        // Accumulate the fees to accumulate
        market.accumulateFees(feesToAccumulate, position.isLong);

        // Pay the liquidator
        market.transferOutTokens(
            _liquidator,
            liqFeeInCollateral,
            position.isLong,
            true // Unwrap by default
        );
        // Pay the fees owed to the user
        if (feesOwedToUser > 0) {
            market.transferOutTokens(
                position.user,
                feesOwedToUser,
                position.isLong,
                true // Unwrap by default
            );
        }

        emit LiquidatePosition(_positionKey, _liquidator, position.collateralAmount, position.isLong);
    }

    function _createStopLoss(Position.Request memory _stopLoss) internal returns (bytes32 stopLossKey) {
        stopLossKey = Position.generateOrderKey(_stopLoss);
        bool success = limitOrderKeys.add(stopLossKey);
        if (!success) revert TradeStorage_KeyAdditionFailed();
        orders[stopLossKey] = _stopLoss;
    }

    function _createTakeProfit(Position.Request memory _takeProfit) internal returns (bytes32 takeProfitKey) {
        takeProfitKey = Position.generateOrderKey(_takeProfit);
        bool success = limitOrderKeys.add(takeProfitKey);
        if (!success) revert TradeStorage_KeyAdditionFailed();
        orders[takeProfitKey] = _takeProfit;
    }

    function _deletePosition(bytes32 _positionKey, bool _isLong) internal {
        delete openPositions[_positionKey];
        bool success = openPositionKeys[_isLong].remove(_positionKey);
        if (!success) revert TradeStorage_PositionRemovalFailed();
    }

    function _deleteOrder(bytes32 _orderKey, bool _isLimit) internal {
        bool success = _isLimit ? limitOrderKeys.remove(_orderKey) : marketOrderKeys.remove(_orderKey);
        if (!success) revert TradeStorage_OrderRemovalFailed();
        delete orders[_orderKey];
    }

    function _reserveLiquidity(
        uint256 _sizeDeltaUsd,
        uint256 _collateralDelta,
        uint256 _collateralPrice,
        uint256 _collateralBaseUnit,
        address _user,
        bool _isLong
    ) internal {
        // Convert Size Delta USD to Collateral Tokens
        uint256 reserveDelta = mulDiv(_sizeDeltaUsd, _collateralBaseUnit, _collateralPrice);
        // Reserve an Amount of Liquidity Equal to the Position Size
        market.reserveLiquidity(reserveDelta, _isLong);
        // Register the Collateral in
        market.updateCollateralAmount(_collateralDelta, _user, _isLong, true);
    }

    function _unreserveLiquidity(
        uint256 _sizeDeltaUsd,
        uint256 _collateralDelta,
        uint256 _collateralPrice,
        uint256 _collateralBaseUnit,
        address _user,
        bool _isLong
    ) internal {
        // Convert Size Delta USD to Collateral Tokens
        uint256 reserveDelta = (mulDiv(_sizeDeltaUsd, _collateralBaseUnit, _collateralPrice)); // Could use collateral delta * leverage for gas savings?
        // Unreserve an Amount of Liquidity Equal to the Position Size
        market.unreserveLiquidity(reserveDelta, _isLong);
        // Register the Collateral out
        market.updateCollateralAmount(_collateralDelta, _user, _isLong, false);
    }

    function _payFees(
        uint256 _borrowAmount,
        uint256 _positionFee,
        uint256 _affiliateRebate,
        address _referrer,
        bool _isLong
    ) internal {
        // Pay Fees to LPs for Side (Position + Borrow)
        market.accumulateFees(_borrowAmount + _positionFee, _isLong);
        // Pay Affiliate Rebate to Referrer
        if (_affiliateRebate > 0) {
            referralStorage.accumulateAffiliateRewards(address(market), _referrer, _isLong, _affiliateRebate);
        }
    }

    function getOpenPositionKeys(bool _isLong) external view returns (bytes32[] memory) {
        return openPositionKeys[_isLong].values();
    }

    function getOrderKeys(bool _isLimit) external view returns (bytes32[] memory orderKeys) {
        orderKeys = _isLimit ? limitOrderKeys.values() : marketOrderKeys.values();
    }

    function getRequestQueueLengths() external view returns (uint256 marketLen, uint256 limitLen) {
        marketLen = marketOrderKeys.length();
        limitLen = limitOrderKeys.length();
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
