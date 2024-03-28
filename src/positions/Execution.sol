// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IMarket} from "../markets/interfaces/IMarket.sol";
import {IMarketMaker} from "../markets/interfaces/IMarketMaker.sol";
import {Position} from "./Position.sol";
import {MarketUtils} from "../markets/MarketUtils.sol";
import {Funding} from "../libraries/Funding.sol";
import {Borrowing} from "../libraries/Borrowing.sol";
import {mulDiv} from "@prb/math/Common.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Oracle} from "../oracle/Oracle.sol";
import {ITradeStorage} from "./interfaces/ITradeStorage.sol";
import {IPriceFeed} from "../oracle/interfaces/IPriceFeed.sol";
import {PriceImpact} from "../libraries/PriceImpact.sol";
import {MarketUtils} from "../markets/MarketUtils.sol";

// Library for Handling Trade related logic
library Execution {
    using SignedMath for int256;
    using SafeCast for uint256;

    error Execution_FeeExceedsDelta();
    error Execution_MinCollateralThreshold();
    error Execution_LiquidatablePosition();
    error Execution_FeesExceedCollateralDelta();
    error Execution_InvalidPriceRetrieval();
    error Execution_InvalidRequestKey();
    error Execution_InvalidFeeReceiver();
    error Execution_LimitPriceNotMet(uint256 limitPrice, uint256 markPrice);

    /**
     * ========================= Data Structures =========================
     */
    struct DecreaseState {
        int256 decreasePnl;
        uint256 afterFeeAmount;
        bool isLiquidation;
        uint256 feesOwedToUser;
        uint256 feesToAccumulate;
        uint256 liqFee;
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
        uint256 fee;
        uint256 affiliateRebate;
        address referrer;
    }

    uint256 private constant LONG_BASE_UNIT = 1e18;
    uint256 private constant SHORT_BASE_UNIT = 1e6;
    uint256 private constant PRECISION = 1e18;

    /**
     * ========================= Construction Functions =========================
     */
    function constructParams(
        IMarket market,
        ITradeStorage tradeStorage,
        IPriceFeed priceFeed,
        bytes32 _orderKey,
        address _feeReceiver
    ) external view returns (State memory state, Position.Request memory request) {
        // Fetch and validate request from key
        request = tradeStorage.getOrder(_orderKey);
        if (request.user == address(0)) revert Execution_InvalidRequestKey();
        if (_feeReceiver == address(0)) revert Execution_InvalidFeeReceiver();
        // Validate the request before continuing execution

        // Fetch and validate price
        state =
            cacheTokenPrices(priceFeed, state, request.input.assetId, request.input.isLong, request.input.isIncrease);

        Position.validateRequest(market, request, state);

        // Check the Price for Limit orders
        if (request.input.isLimit) {
            bool limitPriceCondition;
            // For TP -> Position must be in profit
            if (request.requestType == Position.RequestType.TAKE_PROFIT) {
                limitPriceCondition = request.input.isLong
                    ? state.indexPrice >= request.input.limitPrice
                    : state.indexPrice <= request.input.limitPrice;
            } else {
                limitPriceCondition = request.input.isLong
                    ? state.indexPrice <= request.input.limitPrice
                    : state.indexPrice >= request.input.limitPrice;
            }
            if (!limitPriceCondition) revert Execution_LimitPriceNotMet(request.input.limitPrice, state.indexPrice);
        }

        if (request.input.sizeDelta != 0) {
            // Execute Price Impact
            (state.impactedPrice, state.priceImpactUsd) = PriceImpact.execute(market, request, state);
            // state Size Delta USD

            MarketUtils.validateAllocation(
                market,
                request.input.assetId,
                request.input.sizeDelta,
                state.collateralPrice,
                state.collateralBaseUnit,
                request.input.isLong
            );
        }
    }

    /**
     * ========================= Main Execution Functions =========================
     */
    function increaseCollateral(
        IMarket market,
        Position.Data memory _position,
        Position.Settlement memory _params,
        State memory _state
    ) external view returns (Position.Data memory, State memory) {
        // Subtract fee from collateral delta
        _params.request.input.collateralDelta -= _state.fee;

        if (_state.affiliateRebate > 0) {
            _params.request.input.collateralDelta -= _state.affiliateRebate;
        }
        // Process any Outstanding Borrow Fees
        (_position, _state.borrowFee) = _processBorrowFees(market, _position, _params, _state);
        // Calculate the amount of collateral left after fees
        if (_state.borrowFee >= _params.request.input.collateralDelta) revert Execution_FeeExceedsDelta();
        uint256 afterFeeAmount = _params.request.input.collateralDelta - _state.borrowFee;
        // Edit the Position for Increase
        _position = _editPosition(_position, _state, afterFeeAmount, 0, true);
        // Check the Leverage
        Position.checkLeverage(
            market,
            _params.request.input.assetId,
            _position.positionSize,
            mulDiv(_position.collateralAmount, _state.collateralPrice, _state.collateralBaseUnit) // Collat in USD
        );
        return (_position, _state);
    }

    function decreaseCollateral(
        IMarket market,
        Position.Data memory _position,
        Position.Settlement memory _params,
        State memory _state,
        uint256 _minCollateralUsd,
        uint256 _liquidationFeeUsd
    ) external view returns (Position.Data memory, State memory) {
        // Process any Outstanding Borrow  Fees
        (_position, _state.borrowFee) = _processBorrowFees(market, _position, _params, _state);
        // Edit the Position (subtract full collateral delta)
        _position = _editPosition(_position, _state, _params.request.input.collateralDelta, 0, false);
        // Get remaining collateral in USD
        uint256 remainingCollateralUsd =
            mulDiv(_position.collateralAmount, _state.collateralPrice, _state.collateralBaseUnit);
        // Check if the Decrease puts the position below the min collateral threshold
        if (!_checkMinCollateral(remainingCollateralUsd, _minCollateralUsd)) revert Execution_MinCollateralThreshold();
        if (_checkIsLiquidatable(market, _position, _state, _liquidationFeeUsd)) {
            revert Execution_LiquidatablePosition();
        }
        // Check the Leverage
        Position.checkLeverage(market, _params.request.input.assetId, _position.positionSize, remainingCollateralUsd);

        return (_position, _state);
    }

    // No Funding Involvement
    function createNewPosition(
        IMarket market,
        Position.Settlement memory _params,
        State memory _state,
        uint256 _minCollateralUsd
    ) external view returns (Position.Data memory, State memory) {
        // Subtract Fee from Collateral Delta
        _params.request.input.collateralDelta -= _state.fee;
        // Subtract the fee paid to the refferer
        if (_state.affiliateRebate > 0) {
            _params.request.input.collateralDelta -= _state.affiliateRebate;
        }
        // Cache Collateral Delta in USD
        _state.collateralDeltaUsd =
            mulDiv(_params.request.input.collateralDelta, _state.collateralPrice, _state.collateralBaseUnit);
        // Check that the Position meets the minimum collateral threshold
        if (!_checkMinCollateral(_state.collateralDeltaUsd, _minCollateralUsd)) {
            revert Execution_MinCollateralThreshold();
        }
        // Generate the Position
        Position.Data memory position = Position.generateNewPosition(market, _params.request, _state);
        // Check the Position's Leverage is Valid
        Position.checkLeverage(
            market, _params.request.input.assetId, _params.request.input.sizeDelta, _state.collateralDeltaUsd
        );
        // Return the Position
        return (position, _state);
    }

    // Realise all previous funding and borrowing fees
    // For funding - reset the earnings after charging the previous amount
    function increasePosition(
        IMarket market,
        Position.Data memory _position,
        Position.Settlement memory _params,
        State memory _state
    ) external view returns (Position.Data memory, State memory) {
        // Subtract Fee from Collateral Delta
        _params.request.input.collateralDelta -= _state.fee;
        // Process any Outstanding Borrow Fees
        (_position, _state.borrowFee) = _processBorrowFees(market, _position, _params, _state);
        // Process any Outstanding Funding Fees
        (_position) = _processFundingFees(market, _position, _params, _state);
        // Settle outstanding fees
        uint256 feesToSettle = _state.borrowFee;

        if (feesToSettle >= _params.request.input.collateralDelta) revert Execution_FeesExceedCollateralDelta();
        // Subtract fees from collateral delta
        _params.request.input.collateralDelta -= feesToSettle;
        // Update the Existing Position
        _position = _editPosition(
            _position, _state, _params.request.input.collateralDelta, _params.request.input.sizeDelta, true
        );
        // Check the Leverage
        Position.checkLeverage(
            market,
            _params.request.input.assetId,
            _position.positionSize,
            mulDiv(_position.collateralAmount, _state.collateralPrice, _state.collateralBaseUnit)
        );

        return (_position, _state);
    }

    function decreasePosition(
        IMarket market,
        Position.Data memory _position,
        Position.Settlement memory _params,
        State memory _state,
        uint256 _minCollateralUsd,
        uint256 _liquidationFee
    ) external view returns (Position.Data memory, DecreaseState memory decreaseState, State memory) {
        // Handle case where user wants to close the entire position, but size / collateral aren't proportional
        bool isFullDecrease;
        if (_params.request.input.collateralDelta == _position.collateralAmount) {
            _params.request.input.sizeDelta = _position.positionSize;
            isFullDecrease = true;
        } else if (_params.request.input.sizeDelta == _position.positionSize) {
            _params.request.input.collateralDelta = _position.collateralAmount;
            isFullDecrease = true;
        }

        // Process any Outstanding Borrow Fees
        (_position, _state.borrowFee) = _processBorrowFees(market, _position, _params, _state);
        // Process any Outstanding Funding Fees
        _position = _processFundingFees(market, _position, _params, _state);
        // Calculate Pnl for decrease
        decreaseState.decreasePnl = _calculatePnl(_state, _position, _params.request.input.sizeDelta);

        _position = _editPosition(
            _position, _state, _params.request.input.collateralDelta, _params.request.input.sizeDelta, false
        );
        // @audit - should we be adding fee here? Is it already accounted for?
        uint256 losses = _state.borrowFee + _state.fee;

        /**
         * Subtract any losses owed from the position.
         * Positive PNL is paid from LP, so has no effect on position's collateral
         */
        if (decreaseState.decreasePnl < 0) {
            losses += decreaseState.decreasePnl.abs();
        }

        // Liquidation Case
        // @audit - check insolvency case -> E.g if liq fee can't be paid etc.
        if (losses >= _params.request.input.collateralDelta) {
            // 1. Calculate the Fees Owed to the User
            decreaseState.feesOwedToUser = _position.fundingParams.fundingOwed > 0
                ? mulDiv(_position.fundingParams.fundingOwed.abs(), _state.collateralBaseUnit, _state.collateralPrice)
                : 0;
            if (decreaseState.decreasePnl > 0) decreaseState.feesOwedToUser += decreaseState.decreasePnl.abs();
            // 2. Calculate the Fees to Accumulate
            decreaseState.feesToAccumulate = _state.borrowFee;
            // 3. Calculate the Liquidation Fee
            decreaseState.liqFee = mulDiv(_position.collateralAmount, _liquidationFee, PRECISION);
            // 4. Set the Liquidation Flag
            decreaseState.isLiquidation = true;
        } else {
            // Calculate the amount of collateral left after fees
            decreaseState.afterFeeAmount = _params.request.input.collateralDelta - losses;

            // Get remaining collateral in USD
            uint256 remainingCollateralUsd =
                mulDiv(_position.collateralAmount, _state.collateralPrice, _state.collateralBaseUnit);

            // Check if the Decrease puts the position below the min collateral threshold
            // Only check these if it's not a full decrease
            if (!isFullDecrease) {
                if (!_checkMinCollateral(remainingCollateralUsd, _minCollateralUsd)) {
                    revert Execution_MinCollateralThreshold();
                }
            }
        }

        return (_position, decreaseState, _state);
    }

    /**
     * ========================= Oracle Functions =========================
     */

    /**
     * Cache the signed prices for each token
     */
    function cacheTokenPrices(
        IPriceFeed priceFeed,
        State memory _state,
        bytes32 _assetId,
        bool _isLong,
        bool _isIncrease
    ) public view returns (State memory) {
        // Determine price fetch strategy based on whether it's a limit order or not
        bool maximizePrice = _isLong != _isIncrease;

        // Fetch index price based on order type and direction
        _state.indexPrice = _isLong
            ? _isIncrease ? Oracle.getMaxPrice(priceFeed, _assetId) : Oracle.getMinPrice(priceFeed, _assetId)
            : _isIncrease ? Oracle.getMinPrice(priceFeed, _assetId) : Oracle.getMaxPrice(priceFeed, _assetId);

        if (_state.indexPrice == 0) revert Execution_InvalidPriceRetrieval();

        // Market Token Prices and Base Units
        (_state.longMarketTokenPrice, _state.shortMarketTokenPrice) =
            Oracle.getMarketTokenPrices(priceFeed, maximizePrice);

        _state.collateralPrice = _isLong ? _state.longMarketTokenPrice : _state.shortMarketTokenPrice;
        _state.collateralBaseUnit = _isLong ? LONG_BASE_UNIT : SHORT_BASE_UNIT;

        _state.indexBaseUnit = Oracle.getBaseUnit(priceFeed, _assetId);

        return _state;
    }

    /**
     * ========================= Internal Helper Functions =========================
     */
    /// @dev Applies all changes to an active position
    function _editPosition(
        Position.Data memory _position,
        State memory _state,
        uint256 _collateralDelta,
        uint256 _sizeDelta,
        bool _isIncrease
    ) internal view returns (Position.Data memory) {
        _position.lastUpdate = block.timestamp;
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

    function _checkIsLiquidatable(
        IMarket market,
        Position.Data memory _position,
        State memory _state,
        uint256 _liquidationFeeUsd
    ) public view returns (bool isLiquidatable) {
        // Get the value of all collateral remaining in the position
        uint256 collateralValueUsd =
            mulDiv(_position.collateralAmount, _state.collateralPrice, _state.collateralBaseUnit);
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
        int256 losses = pnl + borrowingFeesUsd.toInt256() + fundingFeesUsd + _liquidationFeeUsd.toInt256();
        // Check if the losses exceed the collateral value
        if (losses < 0 && losses.abs() > collateralValueUsd) {
            isLiquidatable = true;
        } else {
            isLiquidatable = false;
        }
    }

    function _calculatePnl(State memory _state, Position.Data memory _position, uint256 _sizeDelta)
        internal
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
        // Combine funding and pnl
        pnl += _position.fundingParams.fundingOwed;
    }

    function _processFundingFees(
        IMarket market,
        Position.Data memory _position,
        Position.Settlement memory _params,
        State memory _state
    ) internal view returns (Position.Data memory) {
        // Calculate and subtract the funding fee
        (int256 fundingFeeUsd, int256 nextFundingAccrued) = Position.getFundingFeeDelta(
            market,
            _params.request.input.assetId,
            _state.indexPrice,
            _params.request.input.sizeDelta,
            _position.fundingParams.lastFundingAccrued
        );
        // Reset the last funding accrued
        _position.fundingParams.lastFundingAccrued = nextFundingAccrued;
        // Store Funding Fees in Collateral Tokens -> Will be Paid out / Settled as PNL with Decrease
        _position.fundingParams.fundingOwed += fundingFeeUsd < 0
            ? -_convertValueToCollateral(fundingFeeUsd.abs(), _state.collateralPrice, _state.collateralBaseUnit).toInt256()
            : _convertValueToCollateral(fundingFeeUsd.abs(), _state.collateralPrice, _state.collateralBaseUnit).toInt256();

        return (_position);
    }

    function _processBorrowFees(
        IMarket market,
        Position.Data memory _position,
        Position.Settlement memory _params,
        State memory _state
    ) internal view returns (Position.Data memory, uint256 borrowFee) {
        // Calculate and subtract the Borrowing Fee
        borrowFee = Position.getTotalBorrowFees(market, _position, _state);

        _position.borrowingParams.feesOwed = 0;
        if (borrowFee > _params.request.input.collateralDelta) revert Execution_FeeExceedsDelta();

        // Update the position's borrowing parameters
        (_position.borrowingParams.lastLongCumulativeBorrowFee, _position.borrowingParams.lastShortCumulativeBorrowFee)
        = MarketUtils.getCumulativeBorrowFees(market, _position.assetId);

        return (_position, borrowFee);
    }

    function _convertValueToCollateral(uint256 _valueUsd, uint256 _collateralPrice, uint256 _collateralBaseUnit)
        internal
        pure
        returns (uint256 collateralAmount)
    {
        collateralAmount = mulDiv(_valueUsd, _collateralBaseUnit, _collateralPrice);
    }

    function _checkMinCollateral(uint256 _collateralUsd, uint256 _minCollateralUsd)
        internal
        pure
        returns (bool isValid)
    {
        if (_collateralUsd < _minCollateralUsd) {
            isValid = false;
        } else {
            isValid = true;
        }
    }
}
