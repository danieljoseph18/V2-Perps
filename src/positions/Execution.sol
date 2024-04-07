// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IMarket} from "../markets/interfaces/IMarket.sol";
import {Position} from "./Position.sol";
import {MarketUtils} from "../markets/MarketUtils.sol";
import {Funding} from "../libraries/Funding.sol";
import {Borrowing} from "../libraries/Borrowing.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Oracle} from "../oracle/Oracle.sol";
import {ITradeStorage} from "./interfaces/ITradeStorage.sol";
import {IPriceFeed} from "../oracle/interfaces/IPriceFeed.sol";
import {PriceImpact} from "../libraries/PriceImpact.sol";
import {MarketUtils} from "../markets/MarketUtils.sol";
import {Referral} from "../referrals/Referral.sol";
import {IReferralStorage} from "../referrals/interfaces/IReferralStorage.sol";
import {Convert} from "../libraries/Convert.sol";

// Library for Handling Trade related logic
library Execution {
    using SignedMath for int256;
    using SafeCast for uint256;
    using Convert for uint256;
    using Convert for int256;

    error Execution_FeeExceedsDelta();
    error Execution_MinCollateralThreshold();
    error Execution_LiquidatablePosition();
    error Execution_FeesExceedCollateralDelta();
    error Execution_InvalidPriceRetrieval();
    error Execution_InvalidRequestKey();
    error Execution_InvalidFeeReceiver();
    error Execution_LimitPriceNotMet(uint256 limitPrice, uint256 markPrice);
    error Execution_PnlToPoolRatioNotExceeded(int256 pnlFactor, uint256 maxPnlFactor);
    error Execution_PositionNotActive();
    error Execution_PNLFactorNotReduced();
    error Execution_PositionExists();
    error Execution_InvalidPriceRequest();
    error Execution_InvalidRequestId();
    error Execution_InvalidAdlDelta();
    error Execution_PositionNotProfitable();

    event AdlTargetRatioReached(address indexed market, int256 pnlFactor, bool isLong);

    /**
     * ========================= Data Structures =========================
     */
    struct DecreaseState {
        int256 decreasePnl;
        uint256 afterFeeAmount;
        uint256 feesOwedToUser;
        uint256 feesToAccumulate;
        uint256 liqFee;
        bool isLiquidation;
        bool isInsolvent;
        bool isFullDecrease;
    }

    // stated Values for Execution
    struct State {
        uint256 indexPrice;
        uint256 indexBaseUnit;
        uint256 impactedPrice;
        uint256 longMarketTokenPrice;
        uint256 shortMarketTokenPrice;
        uint256 collateralDeltaUsd;
        int256 priceImpactUsd;
        uint256 collateralPrice;
        uint256 collateralBaseUnit;
        uint256 borrowFee;
        int256 fundingFee;
        uint256 positionFee;
        uint256 feeForExecutor;
        uint256 affiliateRebate;
        address referrer;
    }

    uint64 private constant LONG_BASE_UNIT = 1e18;
    uint64 private constant SHORT_BASE_UNIT = 1e6;
    uint64 private constant PRECISION = 1e18;
    uint64 private constant MAX_PNL_FACTOR = 0.45e18;

    /**
     * ========================= Construction Functions =========================
     */
    function initiate(
        ITradeStorage tradeStorage,
        IMarket market,
        IPriceFeed priceFeed,
        IReferralStorage referralStorage,
        bytes32 _orderKey,
        bytes32 _requestId,
        address _feeReceiver
    ) external view returns (State memory state, Position.Request memory request) {
        // Fetch and validate request from key
        request = tradeStorage.getOrder(_orderKey);
        // Validate the request before continuing execution
        request.requestId = _validateRequestId(tradeStorage, priceFeed, request, _requestId, _feeReceiver);
        // Fetch and validate price
        state = cacheTokenPrices(
            priceFeed, state, request.input.ticker, request.requestId, request.input.isLong, request.input.isIncrease
        );
        // Check the Limit Price if it's a limit order
        if (request.input.isLimit) {
            _checkLimitPrice(state.indexPrice, request.input.limitPrice, request.input.triggerAbove);
        }

        if (request.input.sizeDelta != 0) {
            // Execute Price Impact
            (state.impactedPrice, state.priceImpactUsd) = PriceImpact.execute(market, request, state);

            // Validate the available allocation if increase
            if (request.input.isIncrease) {
                MarketUtils.validateAllocation(
                    market,
                    request.input.ticker,
                    request.input.sizeDelta,
                    state.indexPrice,
                    state.collateralPrice,
                    state.indexBaseUnit,
                    state.collateralBaseUnit,
                    request.input.isLong
                );
            }
        }

        // Calculate Fee + Fee for executor
        (state.positionFee, state.feeForExecutor) = Position.calculateFee(
            tradeStorage,
            request.input.sizeDelta,
            request.input.collateralDelta,
            state.collateralPrice,
            state.collateralBaseUnit
        );

        // Calculate & Apply Fee Discount for Referral Code
        (state.positionFee, state.affiliateRebate, state.referrer) =
            Referral.applyFeeDiscount(referralStorage, request.user, state.positionFee);
    }

    function constructAdlOrder(
        IMarket market,
        ITradeStorage tradeStorage,
        IPriceFeed priceFeed,
        bytes32 _positionKey,
        bytes32 _priceRequestId,
        uint256 _adlFeePercentage,
        address _feeReceiver
    )
        external
        view
        returns (
            State memory state,
            Position.Settlement memory params,
            Position.Data memory position,
            int256 startingPnlFactor
        )
    {
        // Check the position in question is active
        position = tradeStorage.getPosition(_positionKey);
        if (position.positionSize == 0) revert Execution_PositionNotActive();
        // Get current MarketUtils and token data
        state = cacheTokenPrices(priceFeed, state, position.ticker, _priceRequestId, position.isLong, false);

        // Set the impacted price to the index price => 0 price impact on ADLs
        state.impactedPrice = state.indexPrice;
        state.priceImpactUsd = 0;
        // Get starting PNL Factor
        startingPnlFactor = _getPnlFactor(market, state, position.ticker, position.isLong);

        // Check the PNL Factor is greater than the max PNL Factor
        if (startingPnlFactor.abs() <= MAX_PNL_FACTOR || startingPnlFactor < 0) {
            revert Execution_PnlToPoolRatioNotExceeded(startingPnlFactor, MAX_PNL_FACTOR);
        }

        // Check the Position being ADLd is profitable
        int256 pnl = Position.getPositionPnl(
            position.positionSize,
            position.weightedAvgEntryPrice,
            state.indexPrice,
            state.indexBaseUnit,
            position.isLong
        );
        if (pnl < 0) revert Execution_PositionNotProfitable();

        // Calculate the Percentage to ADL
        uint256 adlPercentage = Position.calculateAdlPercentage(startingPnlFactor.abs(), pnl, position.positionSize);
        // Calculate the Size Delta
        uint256 sizeDelta = position.positionSize.percentage(adlPercentage);
        // Construct an ADL Order
        params = Position.createAdlOrder(position, sizeDelta, _feeReceiver, _priceRequestId);

        // Get and set the ADL fee for the executor
        // multiply the size delta by the adlFee percentage
        state.feeForExecutor =
            _calculateFeeForAdl(sizeDelta, state.collateralPrice, state.collateralBaseUnit, _adlFeePercentage);
    }

    /**
     * ========================= Main Execution Functions =========================
     */
    // @audit - are we using the afterFeeAmount correctly within and after this function
    function increaseCollateral(
        IMarket market,
        ITradeStorage tradeStorage,
        Position.Settlement memory _params,
        State memory _state,
        bytes32 _positionKey
    ) external view returns (Position.Data memory, State memory) {
        // Fetch and Validate the Position
        Position.Data memory position = tradeStorage.getPosition(_positionKey);
        // Store the initial collateral amount
        uint256 initialCollateral = position.collateralAmount;
        // Process any Outstanding Borrow Fees
        (position, _state.borrowFee) = _processBorrowFees(market, position, _state);
        // Process any Outstanding Funding Fees
        (position, _state.fundingFee) = _processFundingFees(market, position, _params, _state);
        // Calculate the amount of collateral left after fees
        uint256 afterFeeAmount = _calculateAmountAfterFees(_state, _params.request.input.collateralDelta);
        // Edit the Position for Increase
        position = _updatePosition(position, _state, afterFeeAmount, 0, true);
        // Check the Leverage
        _checkLeverage(market, position, _state);
        // Validate the Position Change
        _validateCollateralIncrease(position, _state, initialCollateral, _params.request.input.collateralDelta);

        return (position, _state);
    }

    // @audit - are we using the afterFeeAmount correctly within and after this function
    function decreaseCollateral(
        IMarket market,
        ITradeStorage tradeStorage,
        Position.Settlement memory _params,
        State memory _state,
        uint256 _minCollateralUsd,
        bytes32 _positionKey
    ) external view returns (Position.Data memory, State memory, uint256 amountOut) {
        // Fetch and Validate the Position
        Position.Data memory position = tradeStorage.getPosition(_positionKey);
        uint256 initialCollateral = position.collateralAmount;

        // Process any Outstanding Borrow  Fees
        (position, _state.borrowFee) = _processBorrowFees(market, position, _state);
        // Process any Outstanding Funding Fees
        (position, _state.fundingFee) = _processFundingFees(market, position, _params, _state);
        // Get Amount Out
        amountOut = _calculateAmountAfterFees(_state, _params.request.input.collateralDelta);
        // Edit the Position (subtract full collateral delta)
        position = _updatePosition(position, _state, _params.request.input.collateralDelta, 0, false);
        // Get remaining collateral in USD
        uint256 remainingCollateralUsd =
            position.collateralAmount.toUsd(_state.collateralPrice, _state.collateralBaseUnit);
        // Check if the Decrease puts the position below the min collateral threshold
        if (remainingCollateralUsd < _minCollateralUsd) revert Execution_MinCollateralThreshold();
        if (_checkIsLiquidatable(market, position, _state)) revert Execution_LiquidatablePosition();
        // Check the Leverage
        Position.checkLeverage(market, _params.request.input.ticker, position.positionSize, remainingCollateralUsd);
        // Validate the Position Change
        _validateCollateralDecrease(position, _state, amountOut, initialCollateral);

        return (position, _state, amountOut);
    }

    // No Funding Involvement
    // @audit - are we using the afterFeeAmount correctly within and after this function
    function createNewPosition(
        IMarket market,
        ITradeStorage tradeStorage,
        Position.Settlement memory _params,
        State memory _state,
        uint256 _minCollateralUsd,
        bytes32 _positionKey
    ) external view returns (Position.Data memory, State memory) {
        if (tradeStorage.getPosition(_positionKey).user != address(0)) revert Execution_PositionExists();
        uint256 initialCollateralDelta = _params.request.input.collateralDelta;
        // Calculate Amount After Fees
        uint256 afterFeeAmount = _calculateAmountAfterFees(_state, initialCollateralDelta);
        // Cache Collateral Delta in USD
        _state.collateralDeltaUsd = afterFeeAmount.toUsd(_state.collateralPrice, _state.collateralBaseUnit);
        // Check that the Position meets the minimum collateral threshold
        if (_state.collateralDeltaUsd < _minCollateralUsd) revert Execution_MinCollateralThreshold();
        // Generate the Position
        Position.Data memory position = Position.generateNewPosition(market, _params.request, _state);
        // Check the Position's Leverage is Valid
        Position.checkLeverage(
            market, _params.request.input.ticker, _params.request.input.sizeDelta, _state.collateralDeltaUsd
        );
        // Validate the Position
        Position.validateNewPosition(
            initialCollateralDelta,
            position.collateralAmount,
            _state.positionFee,
            _state.affiliateRebate,
            _state.feeForExecutor
        );
        // Return the Position
        return (position, _state);
    }

    // @audit - are we using the afterFeeAmount correctly within and after this function
    function increasePosition(
        IMarket market,
        ITradeStorage tradeStorage,
        Position.Settlement memory _params,
        State memory _state,
        bytes32 _positionKey
    ) external view returns (Position.Data memory, State memory) {
        Position.Data memory position = tradeStorage.getPosition(_positionKey);

        uint256 initialCollateral = position.collateralAmount;
        uint256 initialSize = position.positionSize;

        // Process any Outstanding Borrow Fees
        (position, _state.borrowFee) = _processBorrowFees(market, position, _state);
        // Process any Outstanding Funding Fees
        (position, _state.fundingFee) = _processFundingFees(market, position, _params, _state);
        // Settle outstanding fees
        uint256 afterFeeAmount = _calculateAmountAfterFees(_state, _params.request.input.collateralDelta);
        // Update the Existing Position
        position = _updatePosition(position, _state, afterFeeAmount, _params.request.input.sizeDelta, true);
        // Check the Leverage
        _checkLeverage(market, position, _state);

        // Validate the Position Change
        _validatePositionIncrease(
            position,
            _state,
            initialCollateral,
            initialSize,
            _params.request.input.collateralDelta,
            _params.request.input.sizeDelta
        );

        return (position, _state);
    }

    // @audit - clean up this code is horrible
    function decreasePosition(
        IMarket market,
        ITradeStorage tradeStorage,
        Position.Settlement memory _params,
        State memory _state,
        uint256 _minCollateralUsd,
        uint256 _liquidationFee,
        bytes32 _positionKey
    ) external view returns (Position.Data memory, DecreaseState memory decreaseState, State memory) {
        // Fetch and Validate the Position
        Position.Data memory position = tradeStorage.getPosition(_positionKey);

        // If SL / TP, clear from the position
        if (_params.request.requestType == Position.RequestType.STOP_LOSS) {
            position.stopLossKey = bytes32(0);
        } else if (_params.request.requestType == Position.RequestType.TAKE_PROFIT) {
            position.takeProfitKey = bytes32(0);
        }

        (_params.request.input.collateralDelta, decreaseState.isFullDecrease) =
            _validateCollateralDelta(position, _params);

        // Process any Outstanding Borrow Fees
        (position, _state.borrowFee) = _processBorrowFees(market, position, _state);
        // Process any Outstanding Funding Fees
        (position, _state.fundingFee) = _processFundingFees(market, position, _params, _state);
        // Calculate Pnl for decrease
        decreaseState.decreasePnl = _calculatePnl(_state, position, _params.request.input.sizeDelta);

        uint256 losses = _state.borrowFee + _state.positionFee + _state.feeForExecutor + _state.affiliateRebate;

        /**
         * Subtract any losses owed from the position.
         * Positive PNL / Funding is paid from LP, so has no effect on position's collateral
         */
        // @audit - are we updating pool for funding?
        if (decreaseState.decreasePnl < 0) losses += decreaseState.decreasePnl.abs();
        if (_state.fundingFee < 0) losses += _state.fundingFee.abs();

        // Liquidation Case
        if (losses >= position.collateralAmount) {
            (_params, decreaseState) = _initiateLiquidation(
                _params, _state, decreaseState, position.positionSize, position.collateralAmount, _liquidationFee
            );
        } else {
            // Decrease Case
            (position, decreaseState) =
                _initiateDecreasePosition(_params, position, _state, decreaseState, losses, _minCollateralUsd);
        }

        return (position, decreaseState, _state);
    }

    /**
     * ========================= Validation Functions =========================
     */
    function validateAdl(
        IMarket market,
        State memory _state,
        int256 _startingPnlFactor,
        string memory _ticker,
        bool _isLong
    ) external view {
        // Get the new PNL to pool ratio
        int256 newPnlFactor = _getPnlFactor(market, _state, _ticker, _isLong);
        // PNL to pool has reduced
        if (newPnlFactor >= _startingPnlFactor) revert Execution_PNLFactorNotReduced();
    }

    /**
     * ========================= Oracle Functions =========================
     */

    /**
     * Cache the signed prices for each token
     * If request is limit, the keeper should've requested a price update themselves.
     * If the request is a market, simply fetch and fulfill the request, making sure it exists
     */
    function cacheTokenPrices(
        IPriceFeed priceFeed,
        State memory _state,
        string memory _indexTicker,
        bytes32 _requestId,
        bool _isLong,
        bool _isIncrease
    ) public view returns (State memory) {
        // Determine whether to maximize or minimize price to round in protocol's favor
        bool maximizePrice = _isLong != _isIncrease;

        // Fetch index price based on order type and direction
        _state.indexPrice = _isLong
            ? _isIncrease
                ? Oracle.getMaxPrice(priceFeed, _requestId, _indexTicker)
                : Oracle.getMinPrice(priceFeed, _requestId, _indexTicker)
            : _isIncrease
                ? Oracle.getMinPrice(priceFeed, _requestId, _indexTicker)
                : Oracle.getMaxPrice(priceFeed, _requestId, _indexTicker);

        // Market Token Prices and Base Units
        (_state.longMarketTokenPrice, _state.shortMarketTokenPrice) =
            Oracle.getMarketTokenPrices(priceFeed, _requestId, maximizePrice);

        _state.collateralPrice = _isLong ? _state.longMarketTokenPrice : _state.shortMarketTokenPrice;
        _state.collateralBaseUnit = _isLong ? LONG_BASE_UNIT : SHORT_BASE_UNIT;

        _state.indexBaseUnit = Oracle.getBaseUnit(priceFeed, _indexTicker);

        return _state;
    }

    /**
     * ========================= Private Helper Functions =========================
     */
    /// @dev Applies all changes to an active position
    function _updatePosition(
        Position.Data memory _position,
        State memory _state,
        uint256 _collateralDelta,
        uint256 _sizeDelta,
        bool _isIncrease
    ) private view returns (Position.Data memory) {
        _position.lastUpdate = uint64(block.timestamp);
        if (_isIncrease) {
            // Increase the Position's collateral
            _position.collateralAmount += _collateralDelta;
            if (_sizeDelta > 0) {
                _position.weightedAvgEntryPrice = MarketUtils.calculateWeightedAverageEntryPrice(
                    _position.weightedAvgEntryPrice, _position.positionSize, _sizeDelta.toInt256(), _state.impactedPrice
                );
                _position.positionSize += _sizeDelta;
            }
        } else {
            _position.collateralAmount -= _collateralDelta;
            if (_sizeDelta > 0) {
                _position.weightedAvgEntryPrice = MarketUtils.calculateWeightedAverageEntryPrice(
                    _position.weightedAvgEntryPrice,
                    _position.positionSize,
                    -_sizeDelta.toInt256(),
                    _state.impactedPrice
                );
                _position.positionSize -= _sizeDelta;
            }
        }
        return _position;
    }

    function _checkIsLiquidatable(IMarket market, Position.Data memory _position, State memory _state)
        public
        view
        returns (bool isLiquidatable)
    {
        // Get the value of all collateral remaining in the position
        uint256 collateralValueUsd = _position.collateralAmount.toUsd(_state.collateralPrice, _state.collateralBaseUnit);
        // Get the PNL for the position
        int256 pnl = Position.getPositionPnl(
            _position.positionSize,
            _position.weightedAvgEntryPrice,
            _state.indexPrice,
            _state.indexBaseUnit,
            _position.isLong
        );

        // Get the Borrow Fees Owed in USD
        uint256 borrowingFeesUsd = Position.getTotalBorrowFeesUsd(market, _position);

        // Get the Funding Fees Owed in USD
        int256 fundingFeesUsd = Position.getTotalFundingFees(market, _position, _state.indexPrice);

        // Calculate the total losses
        int256 losses = pnl + borrowingFeesUsd.toInt256() + fundingFeesUsd;

        // Check if the losses exceed the collateral value
        if (losses < 0 && losses.abs() > collateralValueUsd) {
            isLiquidatable = true;
        } else {
            isLiquidatable = false;
        }
    }

    function _calculatePnl(State memory _state, Position.Data memory _position, uint256 _sizeDelta)
        private
        pure
        returns (int256 pnl)
    {
        pnl = Position.getRealizedPnl(
            _position.positionSize,
            _sizeDelta,
            _position.weightedAvgEntryPrice,
            _state.impactedPrice,
            _state.indexBaseUnit,
            _state.collateralPrice,
            _state.collateralBaseUnit,
            _position.isLong
        );
    }

    function _calculateFeeForAdl(
        uint256 _sizeDelta,
        uint256 _collateralPrice,
        uint256 _collateralBaseUnit,
        uint256 _adlFeePercentage
    ) private pure returns (uint256 adlFee) {
        // Calculate the fee in USD as a percentage of the size delta
        uint256 adlFeeUsd = _sizeDelta.percentage(_adlFeePercentage);
        // Convert value from USD to collateral
        adlFee = adlFeeUsd.toBase(_collateralPrice, _collateralBaseUnit);
    }

    function _processFundingFees(
        IMarket market,
        Position.Data memory _position,
        Position.Settlement memory _params,
        State memory _state
    ) private view returns (Position.Data memory, int256 fundingFee) {
        // Calculate and subtract the funding fee
        (int256 fundingFeeUsd, int256 nextFundingAccrued) = Position.getFundingFeeDelta(
            market,
            _params.request.input.ticker,
            _state.indexPrice,
            _params.request.input.sizeDelta,
            _position.fundingParams.lastFundingAccrued
        );
        // Reset the last funding accrued
        _position.fundingParams.lastFundingAccrued = nextFundingAccrued;
        // Store Funding Fees in Collateral Tokens -> Will be Paid out / Settled as PNL with Decrease
        fundingFee += fundingFeeUsd < 0
            ? -fundingFeeUsd.toBase(_state.collateralBaseUnit, _state.collateralPrice).toInt256()
            : fundingFeeUsd.toBase(_state.collateralBaseUnit, _state.collateralPrice).toInt256();
        // Reset the funding owed
        _position.fundingParams.fundingOwed = 0;

        return (_position, fundingFee);
    }

    function _processBorrowFees(IMarket market, Position.Data memory _position, State memory _state)
        private
        view
        returns (Position.Data memory, uint256 borrowFee)
    {
        // Calculate and subtract the Borrowing Fee
        borrowFee = Position.getTotalBorrowFees(market, _position, _state);
        _position.borrowingParams.feesOwed = 0;
        // Update the position's borrowing parameters
        (_position.borrowingParams.lastLongCumulativeBorrowFee, _position.borrowingParams.lastShortCumulativeBorrowFee)
        = MarketUtils.getCumulativeBorrowFees(market, _position.ticker);

        return (_position, borrowFee);
    }

    /**
     * Extrapolated into an private function to prevent STD Errors
     */
    function _getPnlFactor(IMarket market, Execution.State memory _state, string memory _ticker, bool _isLong)
        private
        view
        returns (int256 pnlFactor)
    {
        pnlFactor = MarketUtils.getPnlFactor(
            market,
            _ticker,
            _state.indexPrice,
            _state.indexBaseUnit,
            _state.collateralPrice,
            _state.collateralBaseUnit,
            _isLong
        );
    }

    function _validateCollateralIncrease(
        Position.Data memory _position,
        Execution.State memory _state,
        uint256 _initialCollateral,
        uint256 _collateralIn
    ) private pure {
        Position.validateCollateralIncrease(
            _position,
            _initialCollateral,
            _collateralIn,
            _state.positionFee,
            _state.fundingFee,
            _state.borrowFee,
            _state.affiliateRebate,
            _state.feeForExecutor
        );
    }

    function _validateCollateralDecrease(
        Position.Data memory _position,
        Execution.State memory _state,
        uint256 _amountOut,
        uint256 _initialCollateral
    ) private pure {
        // Validate the Position Change
        Position.validateCollateralDecrease(
            _position,
            _initialCollateral,
            _amountOut,
            _state.positionFee,
            _state.fundingFee,
            _state.borrowFee,
            _state.affiliateRebate,
            _state.feeForExecutor
        );
    }

    function _validatePositionIncrease(
        Position.Data memory _position,
        Execution.State memory _state,
        uint256 _initialCollateral,
        uint256 _initialSize,
        uint256 _collateralIn,
        uint256 _sizeDelta
    ) private pure {
        Position.validateIncreasePosition(
            _position,
            _initialCollateral,
            _initialSize,
            _collateralIn,
            _state.positionFee,
            _state.affiliateRebate,
            _state.fundingFee,
            _state.borrowFee,
            _sizeDelta,
            _state.feeForExecutor
        );
    }

    /// @dev private function to prevent STD Err
    function _validatePositionDecrease(
        Position.Data memory _position,
        Execution.DecreaseState memory _decreaseState,
        Execution.State memory _state,
        uint256 _sizeDelta,
        uint256 _initialCollateral,
        uint256 _initialSize
    ) private pure {
        Position.validateDecreasePosition(
            _position,
            _initialCollateral,
            _initialSize,
            _decreaseState.afterFeeAmount,
            _state.positionFee,
            _state.affiliateRebate,
            _decreaseState.decreasePnl,
            _state.fundingFee,
            _state.borrowFee,
            _sizeDelta,
            _state.feeForExecutor
        );
    }

    function _checkLeverage(IMarket market, Position.Data memory _position, Execution.State memory _state)
        private
        view
    {
        Position.checkLeverage(
            market,
            _position.ticker,
            _position.positionSize,
            _position.collateralAmount.toUsd(_state.collateralPrice, _state.collateralBaseUnit) // Collat in USD
        );
    }

    function _validateRequestId(
        ITradeStorage tradeStorage,
        IPriceFeed priceFeed,
        Position.Request memory _request,
        bytes32 _requestId,
        address _feeReceiver
    ) private view returns (bytes32 requestId) {
        if (_request.input.isLimit) {
            // Set the Request Id to the Provided Request Id
            requestId = _requestId;
            // If a limit order, the keeper should've requested a price update themselves
            // Required to prevent front-runners from stealing keeper fees for TXs they didn't initiate
            // MinTimeForExecution acts as a time buffer in which the keeper must execute the TX before it opens to the broader network
            if (
                priceFeed.getRequester(_requestId) != _feeReceiver
                    && block.timestamp < _request.requestTimestamp + tradeStorage.minTimeForExecution()
            ) {
                revert Execution_InvalidPriceRequest();
            }
        } else if (_requestId == bytes32(0)) {
            revert Execution_InvalidRequestId();
        }
    }

    /**
     * if Trigger above and price >  trigger price -> valid
     * if Trigger below and price < trigger price -> valid
     * else revert
     */
    function _checkLimitPrice(uint256 _indexPrice, uint256 _limitPrice, bool _triggerAbove) private pure {
        bool limitPriceCondition = _triggerAbove ? _indexPrice >= _limitPrice : _indexPrice <= _limitPrice;
        if (!limitPriceCondition) revert Execution_LimitPriceNotMet(_limitPrice, _indexPrice);
    }

    function _calculateAmountAfterFees(State memory _state, uint256 _collateralDelta)
        private
        pure
        returns (uint256 afterFeeAmount)
    {
        uint256 totalFees = _state.positionFee + _state.feeForExecutor + _state.affiliateRebate + _state.borrowFee;
        if (_state.fundingFee < 0) totalFees += _state.fundingFee.abs();
        if (totalFees >= _collateralDelta) revert Execution_FeesExceedCollateralDelta();
        // Calculate the amount of collateral left after fees
        afterFeeAmount = _collateralDelta - totalFees;
        // Account for any Positive Funding
        if (_state.fundingFee > 0) afterFeeAmount += _state.fundingFee.abs();
    }

    function _validateCollateralDelta(Position.Data memory _position, Position.Settlement memory _params)
        private
        pure
        returns (uint256 collateralDelta, bool isFullDecrease)
    {
        // Full Close Case
        if (_params.request.input.sizeDelta == _position.positionSize) {
            collateralDelta = _position.collateralAmount;
            isFullDecrease = true;
        } else if (_params.request.input.collateralDelta == 0) {
            // If no collateral delta specified, calculate it for a proportional decrease
            collateralDelta =
                _position.collateralAmount.percentage(_params.request.input.sizeDelta, _position.positionSize);
        }
    }

    function _initiateLiquidation(
        Position.Settlement memory _params,
        State memory _state,
        DecreaseState memory _decreaseState,
        uint256 _positionSize,
        uint256 _collateralAmount,
        uint256 _liquidationFee
    ) private pure returns (Position.Settlement memory, DecreaseState memory) {
        // 1. Set Collateral and Size delta to max
        _params.request.input.collateralDelta = _collateralAmount;
        _params.request.input.sizeDelta = _positionSize;
        // 2. Calculate the Fees Owed to the User
        _decreaseState.feesOwedToUser =
            _state.fundingFee > 0 ? _state.fundingFee.toBase(_state.collateralPrice, _state.collateralBaseUnit) : 0;
        if (_decreaseState.decreasePnl > 0) _decreaseState.feesOwedToUser += _decreaseState.decreasePnl.abs();
        // 3. Calculate the Fees to Accumulate
        _decreaseState.feesToAccumulate = _state.borrowFee + _state.positionFee;
        // 4. Calculate the Liquidation Fee
        _decreaseState.liqFee = _collateralAmount.percentage(_liquidationFee);
        // 5. Set the Liquidation Flag
        _decreaseState.isLiquidation = true;
        // 6. Check whether it's insolvent
        if (
            _decreaseState.feesToAccumulate + _decreaseState.liqFee + _state.feeForExecutor + _state.affiliateRebate
                >= _collateralAmount
        ) {
            _decreaseState.isInsolvent = true;
        }

        return (_params, _decreaseState);
    }

    function _initiateDecreasePosition(
        Position.Settlement memory _params,
        Position.Data memory _position,
        State memory _state,
        DecreaseState memory _decreaseState,
        uint256 _losses,
        uint256 _minCollateralUsd
    ) private view returns (Position.Data memory, DecreaseState memory) {
        uint256 initialCollateral = _position.collateralAmount;
        uint256 initialSize = _position.positionSize;
        // Decrease Case
        if (_losses >= _params.request.input.collateralDelta) revert Execution_FeesExceedCollateralDelta();
        _position = _updatePosition(
            _position, _state, _params.request.input.collateralDelta, _params.request.input.sizeDelta, false
        );
        // Calculate the amount of collateral left after fees
        // = Collateral Delta - Borrow Fees - Fee - Losses - Fee for Executor (if any)
        _decreaseState.afterFeeAmount = _params.request.input.collateralDelta - _losses;

        _validatePositionDecrease(
            _position, _decreaseState, _state, _params.request.input.sizeDelta, initialCollateral, initialSize
        );

        // Check if the Decrease puts the position below the min collateral threshold
        // Only check these if it's not a full decrease
        if (!_decreaseState.isFullDecrease) {
            // Get remaining collateral in USD
            uint256 remainingCollateralUsd =
                _position.collateralAmount.toUsd(_state.collateralPrice, _state.collateralBaseUnit);
            if (remainingCollateralUsd < _minCollateralUsd) revert Execution_MinCollateralThreshold();
        }

        return (_position, _decreaseState);
    }
}
