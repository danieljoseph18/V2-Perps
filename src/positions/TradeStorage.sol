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

contract TradeStorage is ITradeStorage, RoleValidation, ReentrancyGuard {
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using SignedMath for int256;

    IMarket public market;
    IReferralStorage public referralStorage;
    IPriceFeed public priceFeed;

    uint256 private constant PRECISION = 1e18;
    uint256 private constant MAX_LIQUIDATION_FEE = 0.5e18; // 50%
    uint256 private constant MAX_TRADING_FEE = 0.01e18; // 1%
    uint256 private constant ADJUSTMENT_FEE = 0.001e18; // 0.1%
    uint256 private constant MIN_COLLATERAL = 1000;
    uint256 private constant LONG_BASE_UNIT = 1e18;
    uint256 private constant SHORT_BASE_UNIT = 1e6;

    mapping(bytes32 _key => Position.Request _order) private orders;
    EnumerableSet.Bytes32Set private marketOrderKeys;
    EnumerableSet.Bytes32Set private limitOrderKeys;

    mapping(bytes32 _positionKey => Position.Data) private openPositions;
    mapping(bool _isLong => EnumerableSet.Bytes32Set _positionKeys) internal openPositionKeys;

    bool private isInitialized;
    uint256 private liquidationFee; // Stored as a percentage with 18 D.P (e.g 0.05e18 = 5%)
    uint256 private minCollateralUsd;

    uint256 public tradingFee;
    uint256 public minBlockDelay;

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

    /**
     * ===================================== Order Functions =====================================
     */

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

    /**
     * ===================================== Execution Functions =====================================
     */
    function executePositionRequest(bytes32 _orderKey, address _feeReceiver)
        external
        onlyPositionManager
        nonReentrant
        returns (Execution.State memory state, Position.Request memory request)
    {
        (state, request) = Execution.constructParams(market, this, priceFeed, _orderKey, _feeReceiver);
        // Fetch the State of the Market Before the Position
        IMarket.MarketStorage memory marketBefore = market.getStorage(request.input.assetId);

        // Calculate Fee
        state.fee = Position.calculateFee(
            this,
            request.input.sizeDelta,
            request.input.collateralDelta,
            state.collateralPrice,
            state.collateralBaseUnit
        );

        // Calculate & Apply Fee Discount for Referral Code
        (state.fee, state.affiliateRebate, state.referrer) =
            Referral.applyFeeDiscount(referralStorage, request.user, state.fee);

        bytes32 positionKey = Position.generateKey(request);
        Position.Data memory position = openPositions[positionKey];
        if (request.requestType == Position.RequestType.CREATE_POSITION) {
            if (Position.exists(position)) revert TradeStorage_PositionExists();
        } else {
            if (!Position.exists(position)) revert TradeStorage_PositionDoesNotExist();
        }

        // Delete the Order from Storage
        _deleteOrder(_orderKey, request.input.isLimit);

        // Update the Market State
        _updateMarketState(
            state, request.input.assetId, request.input.sizeDelta, request.input.isLong, request.input.isIncrease
        );

        // Execute Trade
        if (request.requestType == Position.RequestType.CREATE_POSITION) {
            _createNewPosition(Position.Settlement(request, _orderKey, _feeReceiver, false), state, positionKey);
        } else if (request.requestType == Position.RequestType.POSITION_DECREASE) {
            _decreasePosition(
                Position.Settlement(request, _orderKey, _feeReceiver, false), state, position, positionKey
            );
        } else if (request.requestType == Position.RequestType.POSITION_INCREASE) {
            _increasePosition(
                Position.Settlement(request, _orderKey, _feeReceiver, false), state, position, positionKey
            );
        } else if (request.requestType == Position.RequestType.COLLATERAL_DECREASE) {
            _executeCollateralDecrease(
                Position.Settlement(request, _orderKey, _feeReceiver, false), state, position, positionKey
            );
        } else if (request.requestType == Position.RequestType.COLLATERAL_INCREASE) {
            _executeCollateralIncrease(
                Position.Settlement(request, _orderKey, _feeReceiver, false), state, position, positionKey
            );
        } else if (request.requestType == Position.RequestType.TAKE_PROFIT) {
            _decreasePosition(
                Position.Settlement(request, _orderKey, _feeReceiver, false), state, position, positionKey
            );
        } else if (request.requestType == Position.RequestType.STOP_LOSS) {
            _decreasePosition(
                Position.Settlement(request, _orderKey, _feeReceiver, false), state, position, positionKey
            );
        } else {
            revert TradeStorage_InvalidRequestType();
        }

        // Fetch the State of the Market After the Position
        IMarket.MarketStorage memory marketAfter = market.getStorage(request.input.assetId);

        // Invariant Check
        Position.validateMarketDelta(marketBefore, marketAfter, request);
    }

    function liquidatePosition(bytes32 _positionKey, address _liquidator) external onlyPositionManager nonReentrant {
        // Fetch the Position
        Position.Data memory position = openPositions[_positionKey];
        // Check the Position Exists
        if (!Position.exists(position)) revert TradeStorage_PositionDoesNotExist();
        // Construct the Execution State
        Execution.State memory state;
        // @audit - is this the right price returned ? (min vs max vs med)
        state = Execution.cacheTokenPrices(priceFeed, state, position.assetId, position.isLong, false);
        // No price impact on Liquidations
        state.impactedPrice = state.indexPrice;
        // Update the Market State
        _updateMarketState(state, position.assetId, position.positionSize, position.isLong, false);
        // Construct Liquidation Order
        Position.Settlement memory params = Position.constructLiquidationOrder(position, _liquidator);
        // Execute the Liquidation
        _decreasePosition(params, state, position, _positionKey);
        // Fire Event
        emit LiquidatePosition(_positionKey, _liquidator, position.collateralAmount, position.isLong);
    }

    function executeAdl(bytes32 _positionKey, bytes32 _assetId, uint256 _sizeDelta)
        external
        onlyPositionManager
        nonReentrant
    {
        Execution.State memory state;
        IMarket.AdlConfig memory adl = MarketUtils.getAdlConfig(market, _assetId);
        // Check the position in question is active
        Position.Data memory position = openPositions[_positionKey];
        if (position.positionSize == 0) revert TradeStorage_PositionNotActive();
        // Get current MarketUtils and token data
        state = Execution.cacheTokenPrices(priceFeed, state, position.assetId, position.isLong, false);

        // Set the impacted price to the index price => 0 price impact on ADLs
        state.impactedPrice = state.indexPrice;
        state.priceImpactUsd = 0;
        // Get starting PNL Factor
        int256 startingPnlFactor = _getPnlFactor(state, _assetId, position.isLong);
        // fetch max pnl to pool ratio
        uint256 maxPnlFactor = MarketUtils.getMaxPnlFactor(market, _assetId);

        // Check the PNL Factor is greater than the max PNL Factor
        if (startingPnlFactor.abs() <= maxPnlFactor || startingPnlFactor < 0) {
            revert TradeStorage_PnlToPoolRatioNotExceeded(startingPnlFactor, maxPnlFactor);
        }

        // Construct an ADL Order
        Position.Settlement memory params = Position.createAdlOrder(position, _sizeDelta);

        // Update the Market State
        _updateMarketState(
            state,
            params.request.input.assetId,
            params.request.input.sizeDelta,
            params.request.input.isLong,
            params.request.input.isIncrease
        );

        // Execute the order
        _decreasePosition(params, state, position, _positionKey);

        // Get the new PNL to pool ratio
        int256 newPnlFactor = _getPnlFactor(state, _assetId, position.isLong);
        // PNL to pool has reduced
        if (newPnlFactor >= startingPnlFactor) revert TradeStorage_PNLFactorNotReduced();
        // Check if the new PNL to pool ratio is below the threshold
        // Fire event to alert the keepers
        if (newPnlFactor.abs() <= adl.targetPnlFactor) {
            emit AdlTargetRatioReached(address(market), newPnlFactor, position.isLong);
        }
        emit AdlExecuted(address(market), _positionKey, _sizeDelta, position.isLong);
    }

    /**
     * ===================================== Internal Functions =====================================
     */
    function _executeCollateralIncrease(
        Position.Settlement memory _params,
        Execution.State memory _state,
        Position.Data memory _positionBefore,
        bytes32 _positionKey
    ) internal {
        // Perform Execution in Library
        Position.Data memory positionAfter;
        (positionAfter, _state) = Execution.increaseCollateral(market, _positionBefore, _params, _state);
        // Validate the Position Change
        Position.validateCollateralIncrease(
            _positionBefore,
            positionAfter,
            _params.request.input.collateralDelta,
            _state.fee,
            _state.fundingFee,
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
        // Account for any Funding
        if (_state.fundingFee < 0) {
            // User Paid Funding
            uint256 absFundingFee = _state.fundingFee.abs();
            market.updatePoolBalance(absFundingFee, _positionBefore.isLong, true);
        } else if (_state.fundingFee > 0) {
            // User got Paid Funding
            uint256 absFundingFee = _state.fundingFee.abs();
            market.updatePoolBalance(absFundingFee, _positionBefore.isLong, false);
        }
        // Pay Fees
        _payFees(_state.borrowFee, _state.fee, _state.affiliateRebate, _state.referrer, _params.request.input.isLong);
        // Update Final Storage
        openPositions[_positionKey] = positionAfter;
        emit CollateralEdited(_positionKey, _params.request.input.collateralDelta, _params.request.input.isIncrease);
    }

    function _executeCollateralDecrease(
        Position.Settlement memory _params,
        Execution.State memory _state,
        Position.Data memory _positionBefore,
        bytes32 _positionKey
    ) internal {
        // Perform Execution in Library
        Position.Data memory positionAfter;
        (positionAfter, _state) =
            Execution.decreaseCollateral(market, _positionBefore, _params, _state, minCollateralUsd, liquidationFee);
        // Transfer Tokens to User
        uint256 amountOut =
            _params.request.input.collateralDelta - _state.fee - _state.affiliateRebate - _state.borrowFee;
        // Add / Subtract funding fees
        if (_state.fundingFee < 0) {
            // User Paid Funding
            uint256 absFundingFee = _state.fundingFee.abs();
            amountOut -= absFundingFee;
            market.updatePoolBalance(absFundingFee, _positionBefore.isLong, true);
        } else if (_state.fundingFee > 0) {
            // User got Paid Funding
            uint256 absFundingFee = _state.fundingFee.abs();
            amountOut += absFundingFee;
            market.updatePoolBalance(absFundingFee, _positionBefore.isLong, false);
        }
        // Validate the Position Change
        Position.validateCollateralDecrease(
            _positionBefore,
            positionAfter,
            amountOut,
            _state.fee,
            _state.fundingFee,
            _state.borrowFee,
            _state.affiliateRebate
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
        openPositions[_positionKey] = positionAfter;
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
        emit CollateralEdited(_positionKey, _params.request.input.collateralDelta, _params.request.input.isIncrease);
    }

    function _createNewPosition(Position.Settlement memory _params, Execution.State memory _state, bytes32 _positionKey)
        internal
    {
        // Perform Execution in the Library
        Position.Data memory position;
        (position, _state) = Execution.createNewPosition(market, _params, _state, minCollateralUsd);
        // Validate the New Position
        Position.validateNewPosition(
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
        openPositions[_positionKey] = position;
        bool success = openPositionKeys[position.isLong].add(_positionKey);
        if (!success) revert TradeStorage_PositionAdditionFailed();
        // Fire Event
        emit PositionCreated(_positionKey, position);
    }

    function _increasePosition(
        Position.Settlement memory _params,
        Execution.State memory _state,
        Position.Data memory _positionBefore,
        bytes32 _positionKey
    ) internal {
        // Perform Execution in the Library
        Position.Data memory positionAfter;
        (positionAfter, _state) = Execution.increasePosition(market, _positionBefore, _params, _state);
        // Validate the Position Change
        Position.validateIncreasePosition(
            _positionBefore,
            positionAfter,
            _params.request.input.collateralDelta,
            _state.fee,
            _state.affiliateRebate,
            _state.fundingFee,
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
            _positionBefore.user,
            _params.request.input.isLong
        );
        // If user's position has increased with positive funding, need to subtract from the pool
        if (_state.fundingFee > 0) {
            market.updatePoolBalance(_state.fundingFee.abs(), _positionBefore.isLong, false);
        } else if (_state.fundingFee < 0) {
            // If user's position has decreased with negative funding, need to add to the pool
            market.updatePoolBalance(_state.fundingFee.abs(), _positionBefore.isLong, true);
        }
        // Update Final Storage
        openPositions[_positionKey] = positionAfter;
        // Fire event
        emit IncreasePosition(_positionKey, _params.request.input.collateralDelta, _params.request.input.sizeDelta);
    }

    function _decreasePosition(
        Position.Settlement memory _params,
        Execution.State memory _state,
        Position.Data memory _positionBefore,
        bytes32 _positionKey
    ) internal {
        // If SL / TP, clear from the position
        if (_params.request.requestType == Position.RequestType.STOP_LOSS) {
            _positionBefore.stopLossKey = bytes32(0);
        } else if (_params.request.requestType == Position.RequestType.TAKE_PROFIT) {
            _positionBefore.takeProfitKey = bytes32(0);
        }
        // Perform Execution in the Library
        Position.Data memory positionAfter;
        Execution.DecreaseState memory decreaseState;
        (positionAfter, decreaseState, _state) =
            Execution.decreasePosition(market, _positionBefore, _params, _state, minCollateralUsd, liquidationFee);

        uint256 amountOut;

        // @audit - state changes correct?
        if (decreaseState.isLiquidation) {
            // Remanining collateral after fees is added to the relevant pool
            market.updatePoolBalance(_positionBefore.collateralAmount, _positionBefore.isLong, true);
            // Accumulate the fees to accumulate
            market.accumulateFees(decreaseState.feesToAccumulate, _positionBefore.isLong);
            // Set amount out
            amountOut = decreaseState.feesOwedToUser;
            // Decrease the pool amount by the amount being payed out to the user
            if (amountOut > 0) {
                market.updatePoolBalance(amountOut, _positionBefore.isLong, false);
            }
        } else {
            // Validate the Position Change
            _validateDecrease(_positionBefore, positionAfter, decreaseState, _state, _params.request.input.sizeDelta);
            // Pay Fees
            _payFees(
                _state.borrowFee, _state.fee, _state.affiliateRebate, _state.referrer, _params.request.input.isLong
            );
            // Set Amount Out
            amountOut = decreaseState.decreasePnl > 0
                ? decreaseState.afterFeeAmount + decreaseState.decreasePnl.abs() // Profit Case
                : decreaseState.afterFeeAmount; // Loss / Break Even Case -> Losses already deducted in Execution if any
            // Pay any positive funding accrued. Negative Funding Deducted in Execution
            amountOut += _state.fundingFee > 0 ? _state.fundingFee.abs() : 0;
            // If profit being payed out, need to decrease the pool amount by the profit
            if (amountOut > decreaseState.afterFeeAmount) {
                market.updatePoolBalance(amountOut - decreaseState.afterFeeAmount, _positionBefore.isLong, false);
            }
        }

        // Unreserve Liquidity
        _unreserveLiquidity(
            _params.request.input.sizeDelta,
            _params.request.input.collateralDelta,
            _state.collateralPrice,
            _state.collateralBaseUnit,
            _positionBefore.user,
            _params.request.input.isLong
        );

        // Delete the Position if Full Decrease
        if (positionAfter.positionSize == 0 || positionAfter.collateralAmount == 0) {
            _deletePosition(_positionKey, _params.request.input.isLong);
        } else {
            // Update Final Storage
            openPositions[_positionKey] = positionAfter;
        }

        // Check Market has enough available liquidity for payout
        if (market.totalAvailableLiquidity(_params.request.input.isLong) < amountOut + _state.affiliateRebate) {
            revert TradeStorage_InsufficientFreeLiquidity();
        }
        // Transfer Liquidation Fees to the Liquidator
        if (decreaseState.liqFee > 0) {
            // Pay the liquidator
            market.transferOutTokens(
                _params.feeReceiver, // Liquidator
                decreaseState.liqFee,
                _positionBefore.isLong,
                true // Unwrap by default
            );
        }
        // Transfer Tokens to User
        if (amountOut > 0) {
            market.transferOutTokens(
                _params.request.user, amountOut, _params.request.input.isLong, _params.request.input.reverseWrap
            );
        }
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
        emit DecreasePosition(_positionKey, _params.request.input.collateralDelta, _params.request.input.sizeDelta);
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
        market.updateLiquidityReservation(reserveDelta, _isLong, true);
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
        market.updateLiquidityReservation(reserveDelta, _isLong, false);
        // Register the Collateral out
        market.updateCollateralAmount(_collateralDelta, _user, _isLong, false);
    }

    function _updateMarketState(
        Execution.State memory _state,
        bytes32 _assetId,
        uint256 _sizeDelta,
        bool _isLong,
        bool _isIncrease
    ) internal {
        // Update the Market State
        market.updateMarketState(
            _assetId,
            _sizeDelta,
            _state.indexPrice,
            _state.impactedPrice,
            _state.indexBaseUnit,
            _state.collateralPrice,
            _isLong,
            _isIncrease
        );
        // If Price Impact is Negative, add to the impact Pool
        // If Price Impact is Positive, Subtract from the Impact Pool
        // Impact Pool Delta = -1 * Price Impact
        if (_state.priceImpactUsd == 0) return;
        market.updateImpactPool(_assetId, -_state.priceImpactUsd);
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

    /// @dev Internal function to prevent STD Err
    function _validateDecrease(
        Position.Data memory _positionBefore,
        Position.Data memory _positionAfter,
        Execution.DecreaseState memory _decreaseState,
        Execution.State memory _state,
        uint256 _sizeDelta
    ) internal pure {
        Position.validateDecreasePosition(
            _positionBefore,
            _positionAfter,
            _decreaseState.afterFeeAmount,
            _state.fee,
            _state.affiliateRebate,
            _decreaseState.decreasePnl,
            _state.fundingFee,
            _state.borrowFee,
            _sizeDelta
        );
    }

    /**
     * Extrapolated into an internal function to prevent STD Errors
     */
    function _getPnlFactor(Execution.State memory _state, bytes32 _assetId, bool _isLong)
        internal
        view
        returns (int256 pnlFactor)
    {
        pnlFactor = MarketUtils.getPnlFactor(
            market,
            _assetId,
            _state.indexPrice,
            _state.indexBaseUnit,
            _state.collateralPrice,
            _state.collateralBaseUnit,
            _isLong
        );
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
