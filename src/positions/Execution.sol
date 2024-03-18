// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IMarket} from "../markets/interfaces/IMarket.sol";
import {IMarketMaker} from "../markets/interfaces/IMarketMaker.sol";
import {Position} from "./Position.sol";
import {MarketUtils} from "../markets/MarketUtils.sol";
import {Funding} from "../libraries/Funding.sol";
import {Borrowing} from "../libraries/Borrowing.sol";
import {Pricing} from "../libraries/Pricing.sol";
import {mulDiv} from "@prb/math/Common.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Oracle} from "../oracle/Oracle.sol";
import {Fee} from "../libraries/Fee.sol";
import {ITradeStorage} from "./interfaces/ITradeStorage.sol";
import {IPriceFeed} from "../oracle/interfaces/IPriceFeed.sol";
import {PriceImpact} from "../libraries/PriceImpact.sol";

// Library for Handling Trade related logic
library Execution {
    using SignedMath for int256;
    using SafeCast for uint256;

    error Execution_RefPriceGreaterThanLimitPrice();
    error Execution_RefPriceLessThanLimitPrice();
    error Execution_InvalidRequestType();
    error Execution_FeeExceedsDelta();
    error Execution_MinCollateralThreshold();
    error Execution_LiquidatablePosition();
    error Execution_FeesExceedCollateralDelta();
    error Execution_LossesExceedPrinciple();
    error Execution_InvalidPriceRetrieval();
    error Execution_InvalidRequestKey();
    error Execution_InvalidFeeReceiver();

    /**
     * ========================= Data Structures =========================
     */
    struct DecreaseState {
        int256 decreasePnl;
        uint256 afterFeeAmount;
    }

    // stated Values for Execution
    struct State {
        IMarket market;
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

    /**
     * ========================= Construction Functions =========================
     */
    function constructParams(
        ITradeStorage tradeStorage,
        IMarketMaker marketMaker,
        IPriceFeed priceFeed,
        bytes32 _orderKey,
        address _feeReceiver
    ) external view returns (State memory state, Position.Request memory request) {
        // Fetch and validate request from key
        request = tradeStorage.getOrder(_orderKey);
        if (request.user == address(0)) revert Execution_InvalidRequestKey();
        if (_feeReceiver == address(0)) revert Execution_InvalidFeeReceiver();
        // Validate the request before continuing execution, if invalid, delete the request

        // Fetch and validate price
        state =
            cacheTokenPrices(priceFeed, state, request.input.assetId, request.input.isLong, request.input.isIncrease);

        // state Variables
        state.market = IMarket(marketMaker.tokenToMarkets(request.input.assetId));

        if (request.input.isLimit) Position.checkLimitPrice(state.indexPrice, request.input);
        Position.validateRequest(marketMaker, request, state);

        if (request.input.sizeDelta != 0) {
            // Execute Price Impact
            (state.impactedPrice, state.priceImpactUsd) = PriceImpact.execute(state.market, priceFeed, request, state);
            // state Size Delta USD

            MarketUtils.validateAllocation(
                state.market,
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

    // @audit - check the position isn't put below min leverage
    // @audit - should we process fees before updating the fee parameters?
    // No Funding Involvement
    function increaseCollateral(Position.Data memory _position, Position.Settlement memory _params, State memory _state)
        external
        view
        returns (Position.Data memory, State memory)
    {
        // Subtract fee from collateral delta
        _params.request.input.collateralDelta -= _state.fee;
        // Subtract the fee paid to the refferer -> @audit - should this be fee discount instead?
        if (_state.affiliateRebate > 0) {
            _params.request.input.collateralDelta -= _state.affiliateRebate;
        }
        // Process any Outstanding Borrow Fees
        (_position, _state.borrowFee) = _processBorrowFees(_position, _params, _state);
        // Calculate the amount of collateral left after fees
        if (_state.borrowFee >= _params.request.input.collateralDelta) revert Execution_FeeExceedsDelta();
        uint256 afterFeeAmount = _params.request.input.collateralDelta - _state.borrowFee;
        // Edit the Position for Increase
        _position = _editPosition(_position, _state, afterFeeAmount, 0, true);
        // Check the Leverage
        Position.checkLeverage(
            _state.market,
            _params.request.input.assetId,
            _position.positionSize,
            mulDiv(_position.collateralAmount, _state.collateralPrice, _state.collateralBaseUnit) // Collat in USD
        );
        return (_position, _state);
    }

    // No Funding Involvement
    function decreaseCollateral(
        Position.Data memory _position,
        Position.Settlement memory _params,
        State memory _state,
        uint256 _minCollateralUsd,
        uint256 _liquidationFeeUsd
    ) external view returns (Position.Data memory, State memory) {
        // Process any Outstanding Borrow  Fees
        (_position, _state.borrowFee) = _processBorrowFees(_position, _params, _state);
        // Edit the Position (subtract full collateral delta)
        _position = _editPosition(_position, _state, _params.request.input.collateralDelta, 0, false);
        // Get remaining collateral in USD
        uint256 remainingCollateralUsd =
            mulDiv(_position.collateralAmount, _state.collateralPrice, _state.collateralBaseUnit);
        // Check if the Decrease puts the position below the min collateral threshold
        if (!_checkMinCollateral(remainingCollateralUsd, _minCollateralUsd)) revert Execution_MinCollateralThreshold();
        if (_checkIsLiquidatable(_position, _state, _liquidationFeeUsd)) revert Execution_LiquidatablePosition();
        // Check the Leverage
        Position.checkLeverage(
            _state.market, _params.request.input.assetId, _position.positionSize, remainingCollateralUsd
        );

        return (_position, _state);
    }

    // No Funding Involvement
    function createNewPosition(Position.Settlement memory _params, State memory _state, uint256 _minCollateralUsd)
        external
        view
        returns (Position.Data memory, State memory)
    {
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
        Position.Data memory position = Position.generateNewPosition(_params.request, _state);
        // Check the Position's Leverage is Valid
        Position.checkLeverage(
            _state.market, _params.request.input.assetId, _params.request.input.sizeDelta, _state.collateralDeltaUsd
        );
        // Return the Position
        return (position, _state);
    }

    // Realise all previous funding and borrowing fees
    // For funding - reset the earnings after charging the previous amount
    function increasePosition(Position.Data memory _position, Position.Settlement memory _params, State memory _state)
        external
        view
        returns (Position.Data memory, State memory)
    {
        // Subtract Fee from Collateral Delta - @audit - can I move down to where other fees are subtracted?
        _params.request.input.collateralDelta -= _state.fee;
        // Process any Outstanding Borrow Fees
        (_position, _state.borrowFee) = _processBorrowFees(_position, _params, _state);
        // Process any Outstanding Funding Fees
        (_position) = _processFundingFees(_position, _params, _state);
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
            _state.market,
            _params.request.input.assetId,
            _position.positionSize,
            mulDiv(_position.collateralAmount, _state.collateralPrice, _state.collateralBaseUnit)
        );

        return (_position, _state);
    }

    function decreasePosition(
        Position.Data memory _position,
        Position.Settlement memory _params,
        State memory _state,
        uint256 _minCollateralUsd,
        uint256 _liquidationFeeUsd
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
        (_position, _state.borrowFee) = _processBorrowFees(_position, _params, _state);
        // Process any Outstanding Funding Fees
        (_position) = _processFundingFees(_position, _params, _state);

        decreaseState.decreasePnl = _calculatePnl(_state, _position, _params.request.input.sizeDelta);

        _position = _editPosition(
            _position, _state, _params.request.input.collateralDelta, _params.request.input.sizeDelta, false
        );

        uint256 losses = _state.borrowFee + _state.fee;

        /**
         * Subtract any losses owed from the position.
         * Positive PNL is paid from LP, so has no effect on position's collateral
         */
        if (decreaseState.decreasePnl < 0) {
            losses += decreaseState.decreasePnl.abs();
        }

        if (losses >= _params.request.input.collateralDelta) revert Execution_LossesExceedPrinciple();

        // Calculate the amount of collateral left after fees
        decreaseState.afterFeeAmount = _params.request.input.collateralDelta - losses;

        // Get remaining collateral in USD
        uint256 remainingCollateralUsd =
            mulDiv(_position.collateralAmount, _state.collateralPrice, _state.collateralBaseUnit);

        // Check if the Decrease puts the position below the min collateral threshold
        // Only check these if it's not a full decrease
        // @audit - what to check if it IS a full decrease?
        if (!isFullDecrease) {
            if (!_checkMinCollateral(remainingCollateralUsd, _minCollateralUsd)) {
                revert Execution_MinCollateralThreshold();
            }
            if (_checkIsLiquidatable(_position, _state, _liquidationFeeUsd)) revert Execution_LiquidatablePosition();
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
        _state.collateralBaseUnit = _isLong ? Oracle.getLongBaseUnit(priceFeed) : Oracle.getShortBaseUnit(priceFeed);

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
                _position.weightedAvgEntryPrice = Pricing.calculateWeightedAverageEntryPrice(
                    _position.weightedAvgEntryPrice, _position.positionSize, _sizeDelta.toInt256(), _state.impactedPrice
                );
                _position.positionSize += _sizeDelta;
            }
        } else {
            _position.collateralAmount -= _collateralDelta;
            if (_sizeDelta > 0) {
                _position.weightedAvgEntryPrice = Pricing.calculateWeightedAverageEntryPrice(
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

    // @gas - duplicate in position
    function _checkIsLiquidatable(Position.Data memory _position, State memory _state, uint256 _liquidationFeeUsd)
        public
        view
        returns (bool isLiquidatable)
    {
        // Get the value of all collateral remaining in the position
        uint256 collateralValueUsd =
            mulDiv(_position.collateralAmount, _state.collateralPrice, _state.collateralBaseUnit);
        // Get the PNL for the position
        int256 pnl = Pricing.getPositionPnl(_position, _state.indexPrice, _state.indexBaseUnit);
        // Get the Borrow Fees Owed in USD
        uint256 borrowingFeesUsd = Borrowing.getTotalFeesOwedUsd(_position, _state);
        // Get the Funding Fees Owed in USD
        int256 fundingFeesUsd = Funding.getTotalFeesOwedUsd(_position, _state.indexPrice);
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
        pnl = Pricing.getDecreasePositionPnl(
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
        Position.Data memory _position,
        Position.Settlement memory _params,
        State memory _state
    ) internal view returns (Position.Data memory) {
        // Calculate and subtract the funding fee
        (int256 fundingFeeUsd, int256 nextFundingAccrued) = Funding.getFeeForPositionChange(
            _state.market,
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

    function _processBorrowFees(Position.Data memory _position, Position.Settlement memory _params, State memory _state)
        internal
        view
        returns (Position.Data memory, uint256 borrowFee)
    {
        // Calculate and subtract the Borrowing Fee
        borrowFee = Borrowing.getTotalCollateralFeesOwed(_position, _state);

        _position.borrowingParams.feesOwed = 0;
        if (borrowFee > _params.request.input.collateralDelta) revert Execution_FeeExceedsDelta();

        // Update the position's borrowing parameters
        (_position.borrowingParams.lastLongCumulativeBorrowFee, _position.borrowingParams.lastShortCumulativeBorrowFee)
        = _position.market.getCumulativeBorrowFees(_position.assetId);

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
