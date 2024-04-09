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
import {MathUtils} from "../libraries/MathUtils.sol";

// Library for Handling Trade related logic
library Execution {
    using SignedMath for int256;
    using SafeCast for uint256;
    using MathUtils for uint256;
    using MathUtils for int256;

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
    error Execution_InvalidPosition();

    event AdlTargetRatioReached(address indexed market, int256 pnlFactor, bool isLong);

    /**
     * ========================= Data Structures =========================
     */
    struct DecreaseState {
        uint256 amountOwedToUser;
        uint256 feesToAccumulate;
        bool isFullDecrease;
    }

    struct FeeState {
        uint256 afterFeeAmount;
        int256 fundingFee;
        uint256 borrowFee;
        uint256 positionFee;
        uint256 feeForExecutor;
        uint256 affiliateRebate;
        int256 realizedPnl;
        address referrer;
        bool isLiquidation;
    }

    // stated Values for Execution
    struct Prices {
        uint256 indexPrice;
        uint256 indexBaseUnit;
        uint256 impactedPrice;
        uint256 longMarketTokenPrice;
        uint256 shortMarketTokenPrice;
        int256 priceImpactUsd;
        uint256 collateralPrice;
        uint256 collateralBaseUnit;
    }

    uint64 private constant LONG_BASE_UNIT = 1e18;
    uint64 private constant SHORT_BASE_UNIT = 1e6;
    uint64 private constant PRECISION = 1e18;
    uint64 private constant MAX_PNL_FACTOR = 0.45e18;

    /**
     * ========================= Construction Functions =========================
     */
    /**
     * audit - probably need additional checks for size delta and collateral delta
     * 1. If create new position --> leverage should be 1-100x
     * 2. if increase position --> leverage should be 1-100x
     * 3. if decrease position --> leverage should be 1-100x
     * 4. if edit collateral --> leverage should be 1-100x after edit
     */
    function initiate(
        ITradeStorage tradeStorage,
        IMarket market,
        IPriceFeed priceFeed,
        bytes32 _orderKey,
        bytes32 _requestId,
        address _feeReceiver
    ) external view returns (Prices memory prices, Position.Request memory request) {
        // Fetch and validate request from key
        request = tradeStorage.getOrder(_orderKey);
        // Validate the request before continuing execution
        request.requestId = _validateRequestId(tradeStorage, priceFeed, request, _requestId, _feeReceiver);
        // Fetch and validate price
        prices = getTokenPrices(
            priceFeed, request.input.ticker, request.requestId, request.input.isLong, request.input.isIncrease
        );
        // Check the Limit Price if it's a limit order
        if (request.input.isLimit) {
            _checkLimitPrice(prices.indexPrice, request.input.limitPrice, request.input.triggerAbove);
        }

        if (request.input.sizeDelta != 0) {
            // Execute Price Impact
            (prices.impactedPrice, prices.priceImpactUsd) = PriceImpact.execute(market, request, prices);

            // Validate the available allocation if increase
            if (request.input.isIncrease) {
                MarketUtils.validateAllocation(
                    market,
                    request.input.ticker,
                    request.input.sizeDelta,
                    prices.indexPrice,
                    prices.collateralPrice,
                    prices.indexBaseUnit,
                    prices.collateralBaseUnit,
                    request.input.isLong
                );
            }
        }
    }

    function inititateAdlOrder(
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
            Prices memory prices,
            Position.Settlement memory params,
            Position.Data memory position,
            int256 startingPnlFactor,
            uint256 feeForExecutor
        )
    {
        // Check the position in question is active
        position = tradeStorage.getPosition(_positionKey);
        if (position.positionSize == 0) revert Execution_PositionNotActive();
        // Get current MarketUtils and token data
        prices = getTokenPrices(priceFeed, position.ticker, _priceRequestId, position.isLong, false);

        // Set the impacted price to the index price => 0 price impact on ADLs
        prices.impactedPrice = prices.indexPrice;
        prices.priceImpactUsd = 0;
        // Get starting PNL Factor
        startingPnlFactor = _getPnlFactor(market, prices, position.ticker, position.isLong);

        // Check the PNL Factor is greater than the max PNL Factor
        if (startingPnlFactor.abs() <= MAX_PNL_FACTOR || startingPnlFactor < 0) {
            revert Execution_PnlToPoolRatioNotExceeded(startingPnlFactor, MAX_PNL_FACTOR);
        }

        // Check the Position being ADLd is profitable
        int256 pnl = Position.getPositionPnl(
            position.positionSize,
            position.weightedAvgEntryPrice,
            prices.indexPrice,
            prices.indexBaseUnit,
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
        feeForExecutor =
            _calculateFeeForAdl(sizeDelta, prices.collateralPrice, prices.collateralBaseUnit, _adlFeePercentage);
    }

    /**
     * ========================= Main Execution Functions =========================
     */
    function increaseCollateral(
        IMarket market,
        ITradeStorage tradeStorage,
        IReferralStorage referralStorage,
        Position.Settlement memory _params,
        Prices calldata _prices,
        bytes32 _positionKey
    ) external view returns (Position.Data memory position, FeeState memory feeState) {
        // Fetch and Validate the Position
        position = tradeStorage.getPosition(_positionKey);
        if (position.user == address(0)) revert Execution_InvalidPosition();
        // Store the initial collateral amount
        uint256 initialCollateral = position.collateralAmount;
        // Calculate Fee + Fee for executor
        (feeState.positionFee, feeState.feeForExecutor, feeState.affiliateRebate, feeState.referrer) =
        _calculatePositionFees(
            tradeStorage,
            referralStorage,
            _params.request.input.sizeDelta,
            _params.request.input.collateralDelta,
            _prices.collateralPrice,
            _prices.collateralBaseUnit,
            position.user
        );
        // Process any Outstanding Borrow Fees
        (position, feeState.borrowFee) = _processBorrowFees(market, position, _prices);
        // Process any Outstanding Funding Fees
        (position, feeState.fundingFee) = _processFundingFees(market, position, _params, _prices);
        // Calculate the amount of collateral left after fees
        feeState.afterFeeAmount = _calculateAmountAfterFees(
            _params.request.input.collateralDelta,
            feeState.positionFee,
            feeState.feeForExecutor,
            feeState.affiliateRebate,
            feeState.borrowFee,
            feeState.fundingFee
        );
        // Edit the Position for Increase
        position = _updatePosition(position, feeState.afterFeeAmount, 0, _prices.impactedPrice, true);
        // Check the Leverage
        _checkLeverage(market, position, _prices);
        // Validate the Position Change
        Position.validateCollateralIncrease(
            position, feeState, initialCollateral, _params.request.input.collateralDelta
        );
    }

    function decreaseCollateral(
        IMarket market,
        ITradeStorage tradeStorage,
        IReferralStorage referralStorage,
        Position.Settlement memory _params,
        Prices calldata _prices,
        uint256 _minCollateralUsd,
        bytes32 _positionKey
    ) external view returns (Position.Data memory position, FeeState memory feeState) {
        // Fetch and Validate the Position
        position = tradeStorage.getPosition(_positionKey);
        if (position.user == address(0)) revert Execution_InvalidPosition();
        uint256 initialCollateral = position.collateralAmount;
        // Calculate Fee + Fee for executor
        (feeState.positionFee, feeState.feeForExecutor, feeState.affiliateRebate, feeState.referrer) =
        _calculatePositionFees(
            tradeStorage,
            referralStorage,
            _params.request.input.sizeDelta,
            _params.request.input.collateralDelta,
            _prices.collateralPrice,
            _prices.collateralBaseUnit,
            position.user
        );
        // Process any Outstanding Borrow  Fees
        (position, feeState.borrowFee) = _processBorrowFees(market, position, _prices);
        // Process any Outstanding Funding Fees
        (position, feeState.fundingFee) = _processFundingFees(market, position, _params, _prices);
        // Get Amount Out
        feeState.afterFeeAmount = _calculateAmountAfterFees(
            _params.request.input.collateralDelta,
            feeState.positionFee,
            feeState.feeForExecutor,
            feeState.affiliateRebate,
            feeState.borrowFee,
            feeState.fundingFee
        );
        // Edit the Position (subtract full collateral delta)
        position = _updatePosition(position, _params.request.input.collateralDelta, 0, _prices.impactedPrice, false);
        // Get remaining collateral in USD
        uint256 remainingCollateralUsd =
            position.collateralAmount.toUsd(_prices.collateralPrice, _prices.collateralBaseUnit);
        // Check if the Decrease puts the position below the min collateral threshold
        if (remainingCollateralUsd < _minCollateralUsd) revert Execution_MinCollateralThreshold();
        if (_checkIsLiquidatable(market, position, _prices)) revert Execution_LiquidatablePosition();
        // Check the Leverage
        Position.checkLeverage(market, _params.request.input.ticker, position.positionSize, remainingCollateralUsd);
        // Validate the Position Change
        Position.validateCollateralDecrease(position, feeState, initialCollateral);
    }

    // No Funding Involvement
    function createNewPosition(
        IMarket market,
        ITradeStorage tradeStorage,
        IReferralStorage referralStorage,
        Position.Settlement memory _params,
        Prices calldata _prices,
        uint256 _minCollateralUsd,
        bytes32 _positionKey
    ) external view returns (Position.Data memory position, FeeState memory feeState) {
        if (tradeStorage.getPosition(_positionKey).user != address(0)) revert Execution_PositionExists();

        // Calculate Fee + Fee for executor
        (feeState.positionFee, feeState.feeForExecutor, feeState.affiliateRebate, feeState.referrer) =
        _calculatePositionFees(
            tradeStorage,
            referralStorage,
            _params.request.input.sizeDelta,
            _params.request.input.collateralDelta,
            _prices.collateralPrice,
            _prices.collateralBaseUnit,
            position.user
        );
        // Calculate Amount After Fees
        feeState.afterFeeAmount = _calculateAmountAfterFees(
            _params.request.input.collateralDelta,
            feeState.positionFee,
            feeState.feeForExecutor,
            feeState.affiliateRebate,
            feeState.borrowFee,
            feeState.fundingFee
        );
        // Cache Collateral Delta in USD
        uint256 collateralDeltaUsd = feeState.afterFeeAmount.toUsd(_prices.collateralPrice, _prices.collateralBaseUnit);
        // Check that the Position meets the minimum collateral threshold
        if (collateralDeltaUsd < _minCollateralUsd) revert Execution_MinCollateralThreshold();

        // Generate the Position
        position = Position.generateNewPosition(market, _params.request, _prices.impactedPrice, feeState.afterFeeAmount);

        // Check the Position's Leverage is Valid
        Position.checkLeverage(
            market, _params.request.input.ticker, _params.request.input.sizeDelta, collateralDeltaUsd
        );
        // Validate the Position
        Position.validateNewPosition(
            _params.request.input.collateralDelta,
            position.collateralAmount,
            feeState.positionFee,
            feeState.affiliateRebate,
            feeState.feeForExecutor
        );
    }

    function increasePosition(
        IMarket market,
        ITradeStorage tradeStorage,
        IReferralStorage referralStorage,
        Position.Settlement memory _params,
        Prices calldata _prices,
        bytes32 _positionKey
    ) external view returns (FeeState memory feeState, Position.Data memory position) {
        position = tradeStorage.getPosition(_positionKey);
        if (position.user == address(0)) revert Execution_InvalidPosition();

        uint256 initialCollateral = position.collateralAmount;
        uint256 initialSize = position.positionSize;

        // Calculate Fee + Fee for executor
        (feeState.positionFee, feeState.feeForExecutor, feeState.affiliateRebate, feeState.referrer) =
        _calculatePositionFees(
            tradeStorage,
            referralStorage,
            _params.request.input.sizeDelta,
            _params.request.input.collateralDelta,
            _prices.collateralPrice,
            _prices.collateralBaseUnit,
            position.user
        );
        // Process any Outstanding Borrow Fees
        (position, feeState.borrowFee) = _processBorrowFees(market, position, _prices);
        // Process any Outstanding Funding Fees
        (position, feeState.fundingFee) = _processFundingFees(market, position, _params, _prices);
        // Settle outstanding fees
        feeState.afterFeeAmount = _calculateAmountAfterFees(
            _params.request.input.collateralDelta,
            feeState.positionFee,
            feeState.feeForExecutor,
            feeState.affiliateRebate,
            feeState.borrowFee,
            feeState.fundingFee
        );

        // Update the Existing Position in Memory
        position = _updatePosition(
            position, feeState.afterFeeAmount, _params.request.input.sizeDelta, _prices.impactedPrice, true
        );

        // Check the Leverage
        _checkLeverage(market, position, _prices);

        // Validate the Position Change
        Position.validateIncreasePosition(
            position,
            feeState,
            initialCollateral,
            initialSize,
            _params.request.input.collateralDelta,
            _params.request.input.sizeDelta
        );
    }

    function decreasePosition(
        IMarket market,
        ITradeStorage tradeStorage,
        IReferralStorage referralStorage,
        Position.Settlement memory _params,
        Prices calldata _prices,
        uint256 _minCollateralUsd,
        uint256 _liquidationFee,
        bytes32 _positionKey
    )
        external
        view
        returns (Position.Data memory position, DecreaseState memory decreaseState, FeeState memory feeState)
    {
        // Fetch and Validate the Position
        position = tradeStorage.getPosition(_positionKey);
        if (position.user == address(0)) revert Execution_InvalidPosition();

        // If SL / TP, clear from the position
        if (_params.request.requestType == Position.RequestType.STOP_LOSS) {
            position.stopLossKey = bytes32(0);
        } else if (_params.request.requestType == Position.RequestType.TAKE_PROFIT) {
            position.takeProfitKey = bytes32(0);
        }

        (_params.request.input.collateralDelta, _params.request.input.sizeDelta, decreaseState.isFullDecrease) =
            _validateCollateralDelta(position, _params);

        // Calculate Fee + Fee for executor
        (feeState.positionFee, feeState.feeForExecutor, feeState.affiliateRebate, feeState.referrer) =
        _calculatePositionFees(
            tradeStorage,
            referralStorage,
            _params.request.input.sizeDelta,
            _params.request.input.collateralDelta,
            _prices.collateralPrice,
            _prices.collateralBaseUnit,
            position.user
        );
        // Process any Outstanding Borrow Fees
        (position, feeState.borrowFee) = _processBorrowFees(market, position, _prices);
        // Process any Outstanding Funding Fees
        (position, feeState.fundingFee) = _processFundingFees(market, position, _params, _prices);
        // No Calculation for After Fee Amount here --> liquidations can be insolvent, so it's only checked for decrease case.
        // Calculate Pnl for decrease
        feeState.realizedPnl = _calculatePnl(_prices, position, _params.request.input.sizeDelta);

        // Calculate the total losses accrued by the position
        uint256 losses = feeState.borrowFee + feeState.positionFee + feeState.feeForExecutor + feeState.affiliateRebate;
        if (feeState.realizedPnl < 0) losses += feeState.realizedPnl.abs();
        if (feeState.fundingFee < 0) losses += feeState.fundingFee.abs();

        // Liquidation Case
        if (losses >= position.collateralAmount) {
            (_params, decreaseState, feeState) = _initiateLiquidation(
                _params,
                decreaseState,
                _prices,
                feeState,
                position.positionSize,
                position.collateralAmount,
                _liquidationFee
            );
        } else {
            // Decrease Case
            (position, feeState.afterFeeAmount) = _initiateDecreasePosition(
                market, _params, position, _prices, feeState, _minCollateralUsd, decreaseState.isFullDecrease
            );
        }
    }

    /**
     * ========================= Validation Functions =========================
     */
    function validateAdl(
        IMarket market,
        Prices calldata _prices,
        int256 _startingPnlFactor,
        string memory _ticker,
        bool _isLong
    ) external view {
        // Get the new PNL to pool ratio
        int256 newPnlFactor = _getPnlFactor(market, _prices, _ticker, _isLong);
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
    function getTokenPrices(
        IPriceFeed priceFeed,
        string memory _indexTicker,
        bytes32 _requestId,
        bool _isLong,
        bool _isIncrease
    ) public view returns (Prices memory prices) {
        // Determine whether to maximize or minimize price to round in protocol's favor
        bool maximizePrice = _isLong != _isIncrease;

        // Fetch index price based on order type and direction
        prices.indexPrice = _isLong
            ? _isIncrease
                ? Oracle.getMaxPrice(priceFeed, _requestId, _indexTicker)
                : Oracle.getMinPrice(priceFeed, _requestId, _indexTicker)
            : _isIncrease
                ? Oracle.getMinPrice(priceFeed, _requestId, _indexTicker)
                : Oracle.getMaxPrice(priceFeed, _requestId, _indexTicker);

        // Market Token Prices and Base Units
        (prices.longMarketTokenPrice, prices.shortMarketTokenPrice) =
            Oracle.getMarketTokenPrices(priceFeed, _requestId, maximizePrice);

        prices.collateralPrice = _isLong ? prices.longMarketTokenPrice : prices.shortMarketTokenPrice;
        prices.collateralBaseUnit = _isLong ? LONG_BASE_UNIT : SHORT_BASE_UNIT;

        prices.indexBaseUnit = Oracle.getBaseUnit(priceFeed, _indexTicker);
    }

    /**
     * ========================= Private Helper Functions =========================
     */
    /// @dev Applies all changes to an active position
    function _updatePosition(
        Position.Data memory _position,
        uint256 _collateralDelta,
        uint256 _sizeDelta,
        uint256 _impactedPrice,
        bool _isIncrease
    ) private view returns (Position.Data memory) {
        _position.lastUpdate = uint64(block.timestamp);
        if (_isIncrease) {
            // Increase the Position's collateral
            _position.collateralAmount += _collateralDelta;
            if (_sizeDelta > 0) {
                _position.weightedAvgEntryPrice = MarketUtils.calculateWeightedAverageEntryPrice(
                    _position.weightedAvgEntryPrice, _position.positionSize, _sizeDelta.toInt256(), _impactedPrice
                );
                _position.positionSize += _sizeDelta;
            }
        } else {
            _position.collateralAmount -= _collateralDelta;
            if (_sizeDelta > 0) {
                _position.weightedAvgEntryPrice = MarketUtils.calculateWeightedAverageEntryPrice(
                    _position.weightedAvgEntryPrice, _position.positionSize, -_sizeDelta.toInt256(), _impactedPrice
                );
                _position.positionSize -= _sizeDelta;
            }
        }
        return _position;
    }

    function _checkIsLiquidatable(IMarket market, Position.Data memory _position, Prices calldata _prices)
        public
        view
        returns (bool isLiquidatable)
    {
        // Get the value of all collateral remaining in the position
        uint256 collateralValueUsd =
            _position.collateralAmount.toUsd(_prices.collateralPrice, _prices.collateralBaseUnit);
        // Get the PNL for the position
        int256 pnl = Position.getPositionPnl(
            _position.positionSize,
            _position.weightedAvgEntryPrice,
            _prices.indexPrice,
            _prices.indexBaseUnit,
            _position.isLong
        );

        // Get the Borrow Fees Owed in USD
        uint256 borrowingFeesUsd = Position.getTotalBorrowFeesUsd(market, _position);

        // Get the Funding Fees Owed in USD
        int256 fundingFeesUsd = Position.getTotalFundingFees(market, _position, _prices.indexPrice);

        // Calculate the total losses
        int256 losses = pnl + borrowingFeesUsd.toInt256() + fundingFeesUsd;

        // Check if the losses exceed the collateral value
        if (losses < 0 && losses.abs() > collateralValueUsd) {
            isLiquidatable = true;
        } else {
            isLiquidatable = false;
        }
    }

    function _calculatePnl(Prices calldata _prices, Position.Data memory _position, uint256 _sizeDelta)
        private
        pure
        returns (int256 pnl)
    {
        pnl = Position.getRealizedPnl(
            _position.positionSize,
            _sizeDelta,
            _position.weightedAvgEntryPrice,
            _prices.impactedPrice,
            _prices.indexBaseUnit,
            _prices.collateralPrice,
            _prices.collateralBaseUnit,
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
        // Units value from USD to collateral
        adlFee = adlFeeUsd.fromUsd(_collateralPrice, _collateralBaseUnit);
    }

    function _processFundingFees(
        IMarket market,
        Position.Data memory _position,
        Position.Settlement memory _params,
        Prices calldata _prices
    ) private view returns (Position.Data memory, int256 fundingFee) {
        // Calculate and subtract the funding fee
        (int256 fundingFeeUsd, int256 nextFundingAccrued) = Position.getFundingFeeDelta(
            market,
            _params.request.input.ticker,
            _prices.indexPrice,
            _params.request.input.sizeDelta,
            _position.fundingParams.lastFundingAccrued
        );
        // Reset the last funding accrued
        _position.fundingParams.lastFundingAccrued = nextFundingAccrued;
        // Store Funding Fees in Collateral Tokens -> Will be Paid out / Settled as PNL with Decrease
        fundingFee += fundingFeeUsd < 0
            ? -fundingFeeUsd.fromUsdSigned(_prices.collateralPrice, _prices.collateralBaseUnit).toInt256()
            : fundingFeeUsd.fromUsdSigned(_prices.collateralPrice, _prices.collateralBaseUnit).toInt256();
        // Reset the funding owed
        _position.fundingParams.fundingOwed = 0;

        return (_position, fundingFee);
    }

    function _processBorrowFees(IMarket market, Position.Data memory _position, Prices calldata _prices)
        private
        view
        returns (Position.Data memory, uint256 borrowFee)
    {
        // Calculate and subtract the Borrowing Fee
        borrowFee = Position.getTotalBorrowFees(market, _position, _prices);
        _position.borrowingParams.feesOwed = 0;
        // Update the position's borrowing parameters
        (_position.borrowingParams.lastLongCumulativeBorrowFee, _position.borrowingParams.lastShortCumulativeBorrowFee)
        = MarketUtils.getCumulativeBorrowFees(market, _position.ticker);

        return (_position, borrowFee);
    }

    function _initiateLiquidation(
        Position.Settlement memory _params,
        DecreaseState memory _decreaseState,
        Prices calldata _prices,
        FeeState memory _feeState,
        uint256 _positionSize,
        uint256 _collateralAmount,
        uint256 _liquidationFee
    ) private pure returns (Position.Settlement memory, DecreaseState memory, FeeState memory) {
        // 1. Set Collateral and Size delta to max
        _params.request.input.collateralDelta = _collateralAmount;
        _params.request.input.sizeDelta = _positionSize;
        // 2. Calculate the Fees Owed to the User
        _decreaseState.amountOwedToUser = _feeState.fundingFee > 0
            ? _feeState.fundingFee.fromUsdSigned(_prices.collateralPrice, _prices.collateralBaseUnit)
            : 0;
        if (_feeState.realizedPnl > 0) _decreaseState.amountOwedToUser += _feeState.realizedPnl.abs();
        // 3. Calculate the Fees to Accumulate
        _decreaseState.feesToAccumulate = _feeState.borrowFee + _feeState.positionFee;
        // 4. Calculate the Liquidation Fee
        _feeState.feeForExecutor = _collateralAmount.percentage(_liquidationFee);
        // 5. Set Affiliate Fees to 0
        _feeState.affiliateRebate = 0;
        // 6. Set the Liquidation Flag
        _feeState.isLiquidation = true;

        return (_params, _decreaseState, _feeState);
    }

    function _initiateDecreasePosition(
        IMarket market,
        Position.Settlement memory _params,
        Position.Data memory _position,
        Prices calldata _prices,
        FeeState memory _feeState,
        uint256 _minCollateralUsd,
        bool _isFullDecrease
    ) private view returns (Position.Data memory, uint256) {
        uint256 initialCollateral = _position.collateralAmount;
        uint256 initialSize = _position.positionSize;
        // Calculate After Fee Amount
        _feeState.afterFeeAmount = _calculateAmountAfterFees(
            _params.request.input.collateralDelta,
            _feeState.positionFee,
            _feeState.feeForExecutor,
            _feeState.affiliateRebate,
            _feeState.borrowFee,
            _feeState.fundingFee
        );
        // Decrease Case
        _position = _updatePosition(
            _position,
            _params.request.input.collateralDelta,
            _params.request.input.sizeDelta,
            _prices.impactedPrice,
            false
        );
        // Add / Subtract PNL
        // @audit - what about funding?
        _feeState.afterFeeAmount = _feeState.realizedPnl > 0
            ? _feeState.afterFeeAmount + _feeState.realizedPnl.abs()
            : _feeState.afterFeeAmount - _feeState.realizedPnl.abs();

        _validatePositionDecrease(
            _position, _feeState, _params.request.input.sizeDelta, initialCollateral, initialSize, _feeState.realizedPnl
        );

        // Check if the Decrease puts the position below the min collateral threshold
        // Only check these if it's not a full decrease
        if (!_isFullDecrease) {
            // Get remaining collateral in USD
            uint256 remainingCollateralUsd =
                _position.collateralAmount.toUsd(_prices.collateralPrice, _prices.collateralBaseUnit);
            if (remainingCollateralUsd < _minCollateralUsd) revert Execution_MinCollateralThreshold();
            // Check Leverage
            Position.checkLeverage(market, _position.ticker, _position.positionSize, remainingCollateralUsd);
        }

        return (_position, _feeState.afterFeeAmount);
    }

    // @audit - something wrong with this
    function _calculatePositionFees(
        ITradeStorage tradeStorage,
        IReferralStorage referralStorage,
        uint256 _sizeDelta,
        uint256 _collateralDelta,
        uint256 _collateralPrice,
        uint256 _collateralBaseUnit,
        address _user
    ) private view returns (uint256 positionFee, uint256 feeForExecutor, uint256 affiliateRebate, address referrer) {
        // Calculate Fee + Fee for executor
        (positionFee, feeForExecutor) =
            Position.calculateFee(tradeStorage, _sizeDelta, _collateralDelta, _collateralPrice, _collateralBaseUnit);

        // Calculate & Apply Fee Discount for Referral Code
        (positionFee, affiliateRebate, referrer) = Referral.applyFeeDiscount(referralStorage, _user, positionFee);
    }
    /**
     * Extrapolated into an private function to prevent STD Errors
     */

    function _getPnlFactor(IMarket market, Prices memory _prices, string memory _ticker, bool _isLong)
        private
        view
        returns (int256 pnlFactor)
    {
        pnlFactor = MarketUtils.getPnlFactor(
            market,
            _ticker,
            _prices.indexPrice,
            _prices.indexBaseUnit,
            _prices.collateralPrice,
            _prices.collateralBaseUnit,
            _isLong
        );
    }

    /// @dev private function to prevent STD Err
    function _validatePositionDecrease(
        Position.Data memory _position,
        FeeState memory _feeState,
        uint256 _sizeDelta,
        uint256 _initialCollateral,
        uint256 _initialSize,
        int256 _decreasePnl
    ) private pure {
        Position.validateDecreasePosition(
            _position, _feeState, _initialCollateral, _initialSize, _sizeDelta, _decreasePnl
        );
    }

    function _checkLeverage(IMarket market, Position.Data memory _position, Prices calldata _prices) private view {
        Position.checkLeverage(
            market,
            _position.ticker,
            _position.positionSize,
            _position.collateralAmount.toUsd(_prices.collateralPrice, _prices.collateralBaseUnit) // Collat in USD
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
            // Fetch and return the request id attached to the position request
            requestId = _request.requestId;
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

    function _calculateAmountAfterFees(
        uint256 _collateralDelta,
        uint256 _positionFee,
        uint256 _feeForExecutor,
        uint256 _affiliateRebate,
        uint256 _borrowFee,
        int256 _fundingFee
    ) private pure returns (uint256 afterFeeAmount) {
        uint256 totalFees = _positionFee + _feeForExecutor + _affiliateRebate + _borrowFee;
        // Account for any Positive Funding
        if (_fundingFee < 0) totalFees += _fundingFee.abs();
        else afterFeeAmount += _fundingFee.abs();
        if (totalFees >= _collateralDelta) revert Execution_FeesExceedCollateralDelta();

        // Calculate the amount of collateral left after fees
        afterFeeAmount = _collateralDelta - totalFees;
    }

    function _validateCollateralDelta(Position.Data memory _position, Position.Settlement memory _params)
        private
        pure
        returns (uint256 collateralDelta, uint256 sizeDelta, bool isFullDecrease)
    {
        // Full Close Case
        if (
            _params.request.input.sizeDelta >= _position.positionSize
                || _params.request.input.collateralDelta >= _position.collateralAmount
        ) {
            collateralDelta = _position.collateralAmount;
            sizeDelta = _position.positionSize;
            isFullDecrease = true;
        } else if (_params.request.input.collateralDelta == 0) {
            // If no collateral delta specified, calculate it for a proportional decrease
            collateralDelta =
                _position.collateralAmount.percentage(_params.request.input.sizeDelta, _position.positionSize);
        }
    }
}
