// SPDX-License-Identifier: BUSL-1.1
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
import {console} from "forge-std/Test.sol";

// Library for Handling Trade related logic
library Order {
    using SignedMath for int256;
    using SafeCast for uint256;

    error Order_InvalidSlippage();
    error Order_InvalidCollateralDelta();
    error Order_MarketDoesNotExist();
    error Order_InvalidLimitPrice();
    error Order_RefPriceGreaterThanLimitPrice();
    error Order_RefPriceLessThanLimitPrice();
    error Order_InvalidRequestType();
    error Order_FeeExceedsDelta();
    error Order_MinCollateralThreshold();
    error Order_LiquidatablePosition();
    error Order_FeesExceedCollateralDelta();
    error Order_LossesExceedPrinciple();
    error Order_InvalidPriceRetrieval();
    error Order_InvalidRequestKey();
    error Order_InvalidFeeReceiver();

    uint256 internal constant PRECISION = 1e18;
    uint256 private constant MIN_SLIPPAGE = 0.0001e18; // 0.01%
    uint256 private constant MAX_SLIPPAGE = 0.9999e18; // 99.99%

    /**
     * ========================= Data Structures =========================
     */
    struct DecreaseState {
        int256 decreasePnl;
        uint256 afterFeeAmount;
    }

    // stated Values for Execution
    struct ExecutionState {
        IMarket market;
        uint256 indexPrice;
        uint256 indexBaseUnit;
        uint256 impactedPrice;
        uint256 longMarketTokenPrice;
        uint256 shortMarketTokenPrice;
        int256 collateralDeltaUsd;
        int256 priceImpactUsd;
        uint256 collateralPrice;
        uint256 collateralBaseUnit;
        int256 fundingFee;
        uint256 borrowFee;
        uint256 fee;
        uint256 affiliateRebate;
        address referrer;
    }

    /**
     * Need to Check:
     * - Collateral is > min collateral
     * - Leverage is valid (1 - X)
     * - Limit price is valid -> if long, limit price < ref price, if short, limit price > ref price
     * - Conditional Prices are valid -> if long, stop loss < ref price, if short, stop loss > ref price
     * if long, take profit > ref price, if short, take profit < ref price
     */

    /**
     * ========================= Construction Functions =========================
     */
    function constructExecuteParams(
        ITradeStorage tradeStorage,
        IMarketMaker marketMaker,
        IPriceFeed priceFeed,
        bytes32 _orderKey,
        address _feeReceiver
    ) external view returns (ExecutionState memory state, Position.Request memory request) {
        // Fetch and validate request from key
        request = tradeStorage.getOrder(_orderKey);
        if (request.user == address(0)) revert Order_InvalidRequestKey();
        if (_feeReceiver == address(0)) revert Order_InvalidFeeReceiver();
        // Fetch and validate price
        state =
            cacheTokenPrices(priceFeed, state, request.input.assetId, request.input.isLong, request.input.isIncrease);

        // state Variables
        state.market = IMarket(marketMaker.tokenToMarkets(request.input.assetId));
        state.collateralDeltaUsd = request.input.isIncrease
            ? mulDiv(request.input.collateralDelta, state.collateralPrice, state.collateralBaseUnit).toInt256()
            : -mulDiv(request.input.collateralDelta, state.collateralPrice, state.collateralBaseUnit).toInt256();

        if (request.input.isLimit) Position.checkLimitPrice(state.indexPrice, request.input);
        Position.validateRequest(tradeStorage, request, state);

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

    // SL / TP are Decrease Orders tied to a Position
    function constructConditionalOrders(Position.Data memory _position, Position.Conditionals memory _conditionals)
        external
        view
        returns (Position.Request memory stopLossOrder, Position.Request memory takeProfitOrder)
    {
        // Construct the stop loss based on the values
        if (_conditionals.stopLossSet) {
            stopLossOrder = Position.Request({
                input: Position.Input({
                    assetId: _position.assetId,
                    collateralToken: _position.collateralToken,
                    collateralDelta: mulDiv(_position.collateralAmount, _conditionals.stopLossPercentage, PRECISION),
                    sizeDelta: mulDiv(_position.positionSize, _conditionals.stopLossPercentage, PRECISION),
                    limitPrice: _conditionals.stopLossPrice,
                    maxSlippage: MAX_SLIPPAGE,
                    executionFee: 0, // @audit - how do we get user to pay for execution?
                    isLong: !_position.isLong,
                    isLimit: true,
                    isIncrease: false,
                    shouldWrap: true,
                    conditionals: Position.Conditionals({
                        stopLossSet: false,
                        stopLossPrice: 0,
                        stopLossPercentage: 0,
                        takeProfitSet: false,
                        takeProfitPrice: 0,
                        takeProfitPercentage: 0
                    })
                }),
                market: address(_position.market),
                user: _position.user,
                requestBlock: block.number,
                requestType: Position.RequestType.STOP_LOSS
            });
        }
        // Construct the Take profit based on the values
        if (_conditionals.takeProfitSet) {
            takeProfitOrder = Position.Request({
                input: Position.Input({
                    assetId: _position.assetId,
                    collateralToken: _position.collateralToken,
                    collateralDelta: mulDiv(_position.collateralAmount, _conditionals.takeProfitPercentage, PRECISION),
                    sizeDelta: mulDiv(_position.positionSize, _conditionals.takeProfitPercentage, PRECISION),
                    limitPrice: _conditionals.takeProfitPrice,
                    maxSlippage: MAX_SLIPPAGE,
                    executionFee: 0, // @audit - how do we get user to pay for execution?
                    isLong: !_position.isLong,
                    isLimit: true,
                    isIncrease: false,
                    shouldWrap: true,
                    conditionals: Position.Conditionals({
                        stopLossSet: false,
                        stopLossPrice: 0,
                        stopLossPercentage: 0,
                        takeProfitSet: false,
                        takeProfitPrice: 0,
                        takeProfitPercentage: 0
                    })
                }),
                market: address(_position.market),
                user: _position.user,
                requestBlock: block.number,
                requestType: Position.RequestType.TAKE_PROFIT
            });
        }
    }

    /**
     * ========================= Validation Functions =========================
     */
    function validateInitialParameters(IMarketMaker marketMaker, Position.Input memory _trade)
        external
        view
        returns (address market, bytes32 positionKey)
    {
        if (!(_trade.maxSlippage >= MIN_SLIPPAGE && _trade.maxSlippage <= MAX_SLIPPAGE)) revert Order_InvalidSlippage();
        if (_trade.collateralDelta == 0) revert Order_InvalidCollateralDelta();

        market = marketMaker.tokenToMarkets(_trade.assetId);
        if (market == address(0)) revert Order_MarketDoesNotExist();

        positionKey = keccak256(abi.encode(_trade.assetId, msg.sender, _trade.isLong));

        if (_trade.isLimit && _trade.limitPrice == 0) revert Order_InvalidLimitPrice();
    }

    /**
     * ========================= Main Execution Functions =========================
     */

    // @audit - check the position isn't put below min leverage
    // @audit - should we process fees before updating the fee parameters?
    // No Funding Involvement
    function executeCollateralIncrease(
        Position.Data memory _position,
        Position.Execution memory _params,
        ExecutionState memory _state
    ) external view returns (Position.Data memory, ExecutionState memory) {
        // Subtract fee from collateral delta
        _params.request.input.collateralDelta -= _state.fee;
        // Subtract the fee paid to the refferer
        if (_state.affiliateRebate > 0) {
            _params.request.input.collateralDelta -= _state.affiliateRebate;
        }
        // Update the Fee Parameters
        _position = _updateFeeParameters(_position, _state);
        // Process any Outstanding Borrow Fees
        (_position, _state.borrowFee) = _processBorrowFees(_position, _params, _state);
        // Calculate the amount of collateral left after fees
        if (_state.borrowFee >= _params.request.input.collateralDelta) revert Order_FeeExceedsDelta();
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
    function executeCollateralDecrease(
        Position.Data memory _position,
        Position.Execution memory _params,
        ExecutionState memory _state,
        uint256 _minCollateralUsd,
        uint256 _liquidationFeeUsd
    ) external view returns (Position.Data memory, ExecutionState memory) {
        // Update the Fee Parameters
        _position = _updateFeeParameters(_position, _state);
        // Process any Outstanding Borrow  Fees
        (_position, _state.borrowFee) = _processBorrowFees(_position, _params, _state);
        // Edit the Position (subtract full collateral delta)
        _position = _editPosition(_position, _state, _params.request.input.collateralDelta, 0, false);
        // Check if the Decrease puts the position below the min collateral threshold
        if (
            !checkMinCollateral(
                _position.collateralAmount, _state.collateralPrice, _state.collateralBaseUnit, _minCollateralUsd
            )
        ) revert Order_MinCollateralThreshold();
        if (_checkIsLiquidatable(_position, _state, _liquidationFeeUsd)) revert Order_LiquidatablePosition();
        // Check the Leverage
        Position.checkLeverage(
            _state.market,
            _params.request.input.assetId,
            _position.positionSize,
            mulDiv(_position.collateralAmount, _state.collateralPrice, _state.collateralBaseUnit)
        );

        return (_position, _state);
    }

    // No Funding Involvement
    function createNewPosition(
        Position.Execution memory _params,
        ExecutionState memory _state,
        uint256 _minCollateralUsd
    ) external view returns (Position.Data memory, ExecutionState memory) {
        // Subtract Fee from Collateral Delta
        _params.request.input.collateralDelta -= _state.fee;
        // Subtract the fee paid to the refferer
        if (_state.affiliateRebate > 0) {
            _state.affiliateRebate = Position.convertUsdToCollateral(
                _state.affiliateRebate, _state.collateralPrice, _state.collateralBaseUnit
            );
            _params.request.input.collateralDelta -= _state.affiliateRebate;
        }
        // Check that the Position meets the minimum collateral threshold
        if (
            !checkMinCollateral(
                _params.request.input.collateralDelta,
                _state.collateralPrice,
                _state.collateralBaseUnit,
                _minCollateralUsd
            )
        ) revert Order_MinCollateralThreshold();
        // Generate the Position
        Position.Data memory position = Position.generateNewPosition(_params.request, _state);
        // Check the Position's Leverage is Valid
        Position.checkLeverage(
            _state.market,
            _params.request.input.assetId,
            _params.request.input.sizeDelta,
            _state.collateralDeltaUsd.abs()
        );
        // Return the Position
        return (position, _state);
    }

    // Realise all previous funding and borrowing fees
    // For funding - reset the earnings after charging the previous amount
    function increaseExistingPosition(
        Position.Data memory _position,
        Position.Execution memory _params,
        ExecutionState memory _state
    ) external view returns (Position.Data memory, ExecutionState memory) {
        // Subtract Fee from Collateral Delta - @audit - can I move down to where other fees are subtracted?
        _params.request.input.collateralDelta -= _state.fee;
        // Update the Fee Parameters
        _position = _updateFeeParameters(_position, _state);
        // Process any Outstanding Borrow Fees
        (_position, _state.borrowFee) = _processBorrowFees(_position, _params, _state);
        // Process any Outstanding Funding Fees
        (_position, _state.fundingFee) = _processFundingFees(_position, _params, _state);
        // Settle outstanding fees
        uint256 feesToSettle = _state.borrowFee;
        if (_state.fundingFee < 0) {
            feesToSettle += _state.fundingFee.abs();
        } else {
            // @audit - counts as position profit, need to handle accordingly
            // @audit - DEFINITELY VULNERABILITY / INCONSISTENCY HERE
            // essentially subtract profit from LPs and add to position
            _params.request.input.collateralDelta += _state.fundingFee.abs();
        }

        if (feesToSettle >= _params.request.input.collateralDelta) revert Order_FeesExceedCollateralDelta();
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

    function decreaseExistingPosition(
        Position.Data memory _position,
        Position.Execution memory _params,
        ExecutionState memory _state,
        uint256 _minCollateralUsd,
        uint256 _liquidationFeeUsd
    ) external view returns (Position.Data memory, DecreaseState memory decreaseState, ExecutionState memory) {
        // Update the Fee Parameters
        _position = _updateFeeParameters(_position, _state);

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
        (_position, _state.fundingFee) = _processFundingFees(_position, _params, _state);

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

        if (losses >= _params.request.input.collateralDelta) revert Order_LossesExceedPrinciple();

        // Calculate the amount of collateral left after fees
        decreaseState.afterFeeAmount = _params.request.input.collateralDelta - losses;

        // Check if the Decrease puts the position below the min collateral threshold
        // Only check these if it's not a full decrease
        // @audit - what to check if it IS a full decrease?
        if (!isFullDecrease) {
            if (
                !checkMinCollateral(
                    _position.collateralAmount, _state.collateralPrice, _state.collateralBaseUnit, _minCollateralUsd
                )
            ) revert Order_MinCollateralThreshold();
            if (_checkIsLiquidatable(_position, _state, _liquidationFeeUsd)) revert Order_LiquidatablePosition();
        }

        return (_position, decreaseState, _state);
    }

    // Checks if a position meets the minimum collateral threshold
    function checkMinCollateral(
        uint256 _collateralAmount,
        uint256 _collateralPriceUsd,
        uint256 _collateralBaseUnit,
        uint256 _minCollateralUsd
    ) public pure returns (bool isValid) {
        uint256 requestCollateralUsd = mulDiv(_collateralAmount, _collateralPriceUsd, _collateralBaseUnit);
        if (requestCollateralUsd < _minCollateralUsd) {
            isValid = false;
        } else {
            isValid = true;
        }
    }

    /**
     * ========================= Internal Helper Functions =========================
     */
    function _updateFeeParameters(Position.Data memory _position, ExecutionState memory _state)
        internal
        view
        returns (Position.Data memory)
    {
        // Borrowing Fees
        _position.borrowingParams.feesOwed = Borrowing.getTotalCollateralFeesOwed(_position, _state);
        (_position.borrowingParams.lastLongCumulativeBorrowFee, _position.borrowingParams.lastShortCumulativeBorrowFee)
        = _position.market.getCumulativeBorrowFees(_position.assetId);
        return _position;
    }

    /// @dev Applies all changes to an active position
    function _editPosition(
        Position.Data memory _position,
        ExecutionState memory _state,
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
    function _checkIsLiquidatable(
        Position.Data memory _position,
        ExecutionState memory _state,
        uint256 _liquidationFeeUsd
    ) public view returns (bool isLiquidatable) {
        uint256 collateralValueUsd =
            mulDiv(_position.collateralAmount, _state.collateralPrice, _state.collateralBaseUnit);
        uint256 totalFeesOwedUsd = Position.getTotalFeesOwedUsd(_position, _state);
        int256 pnl = Pricing.getPositionPnl(_position, _state.indexPrice, _state.indexBaseUnit);
        uint256 losses = _liquidationFeeUsd + totalFeesOwedUsd + (pnl < 0 ? pnl.abs() : 0);
        isLiquidatable = collateralValueUsd <= losses;
    }

    function _calculatePnl(ExecutionState memory _state, Position.Data memory _position, uint256 _sizeDelta)
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
        pnl += _state.fundingFee;
    }

    function _processFundingFees(
        Position.Data memory _position,
        Position.Execution memory _params,
        ExecutionState memory _state
    ) internal view returns (Position.Data memory, int256 fundingFee) {
        // Calculate and subtract the funding fee
        (int256 fundingFeeUsd, int256 nextFundingAccrued) = Funding.getFeeForPositionChange(
            _state.market,
            _params.request.input.assetId,
            _state.indexPrice,
            _params.request.input.sizeDelta,
            _position.lastFundingAccrued
        );
        // Reset the last funding accrued
        _position.lastFundingAccrued = nextFundingAccrued;
        // Convert funding fee to collateral amount
        fundingFee = fundingFeeUsd < 0
            ? -_convertValueToCollateral(fundingFeeUsd.abs(), _state.collateralPrice, _state.collateralBaseUnit).toInt256()
            : _convertValueToCollateral(fundingFeeUsd.abs(), _state.collateralPrice, _state.collateralBaseUnit).toInt256();

        return (_position, fundingFee);
    }

    function _processBorrowFees(
        Position.Data memory _position,
        Position.Execution memory _params,
        ExecutionState memory _state
    ) internal view returns (Position.Data memory, uint256 borrowFee) {
        // Calculate and subtract the Borrowing Fee
        borrowFee = Borrowing.getTotalCollateralFeesOwed(_position, _state);

        _position.borrowingParams.feesOwed = 0;
        if (borrowFee > _params.request.input.collateralDelta) revert Order_FeeExceedsDelta();

        return (_position, borrowFee);
    }

    function _convertValueToCollateral(uint256 _valueUsd, uint256 _collateralPrice, uint256 _collateralBaseUnit)
        internal
        pure
        returns (uint256 collateralAmount)
    {
        collateralAmount = mulDiv(_valueUsd, _collateralBaseUnit, _collateralPrice);
    }

    /**
     * Cache the signed prices for each token
     */
    function cacheTokenPrices(
        IPriceFeed priceFeed,
        ExecutionState memory _state,
        bytes32 _assetId,
        bool _isLong,
        bool _isIncrease
    ) public view returns (ExecutionState memory) {
        // Determine price fetch strategy based on whether it's a limit order or not
        bool maximizePrice = _isLong != _isIncrease;

        // Fetch index price based on order type and direction
        _state.indexPrice = _isLong
            ? _isIncrease ? Oracle.getMaxPrice(priceFeed, _assetId) : Oracle.getMinPrice(priceFeed, _assetId)
            : _isIncrease ? Oracle.getMinPrice(priceFeed, _assetId) : Oracle.getMaxPrice(priceFeed, _assetId);

        if (_state.indexPrice == 0) revert Order_InvalidPriceRetrieval();

        // Market Token Prices and Base Units
        (_state.longMarketTokenPrice, _state.shortMarketTokenPrice) =
            Oracle.getMarketTokenPrices(priceFeed, maximizePrice);

        _state.collateralPrice = _isLong ? _state.longMarketTokenPrice : _state.shortMarketTokenPrice;
        _state.collateralBaseUnit = _isLong ? Oracle.getLongBaseUnit(priceFeed) : Oracle.getShortBaseUnit(priceFeed);

        _state.indexBaseUnit = Oracle.getBaseUnit(priceFeed, _assetId);

        return _state;
    }
}
