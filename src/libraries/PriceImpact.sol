// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IMarket} from "../markets/interfaces/IMarket.sol";
import {SignedMath} from "../libraries/SignedMath.sol";
import {Position} from "../positions/Position.sol";
import {MarketUtils} from "../markets/MarketUtils.sol";
import {mulDiv, mulDivSigned} from "@prb/math/Common.sol";
import {SafeCast} from "./SafeCast.sol";
import {Execution} from "../positions/Execution.sol";
import {MarketUtils} from "../markets/MarketUtils.sol";
import {MathUtils} from "./MathUtils.sol";

// library responsible for handling all price impact calculations
library PriceImpact {
    using SignedMath for int256;
    using SafeCast for uint256;
    using SafeCast for int256;
    using MathUtils for uint256;
    using MathUtils for int256;

    error PriceImpact_SizeDeltaIsZero();
    error PriceImpact_InsufficientLiquidity();
    error PriceImpact_InvalidState();
    error PriceImpact_SlippageExceedsMax();
    error PriceImpact_InvalidDecrease();

    uint256 private constant PRICE_PRECISION = 1e30;
    int256 private constant SIGNED_PRICE_PRECISION = 1e30;

    struct ImpactState {
        int256 positiveSkewScalar;
        int256 negativeSkewScalar;
        int256 positiveLiquidityScalar;
        int256 negativeLiquidityScalar;
        uint256 longOi;
        uint256 shortOi;
        uint256 initialTotalOi;
        uint256 updatedTotalOi;
        int256 initialSkew;
        int256 updatedSkew;
        int256 priceImpactUsd;
        int256 oiPercentage;
        int256 availableOi;
        int256 sizeDeltaUsd;
    }

    /**
     * Price impact is calculated as a function of the following:
     * 1. How the action affects the skew of the market. Positions should be punished for increasing, and rewarded for decreasing.
     * 2. The liquidity of the market. The more illiquid, the higher the price impact will be.
     */
    function execute(IMarket market, Position.Request memory _request, Execution.Prices memory _prices)
        internal
        view
        returns (uint256 impactedPrice, int256 priceImpactUsd)
    {
        if (_request.input.sizeDelta == 0) revert PriceImpact_SizeDeltaIsZero();

        ImpactState memory state;
        (
            state.positiveSkewScalar,
            state.negativeSkewScalar,
            state.positiveLiquidityScalar,
            state.negativeLiquidityScalar
        ) = market.getImpactValues(_request.input.ticker);
        state = _getImpactValues(market, _request.input.ticker);
        // Get long / short Oi -> used to calculate skew
        state.longOi = MarketUtils.getOpenInterest(market, _request.input.ticker, true);
        state.shortOi = MarketUtils.getOpenInterest(market, _request.input.ticker, false);
        // Used to calculate the impact on available liquidity
        if (_request.input.isLong) {
            state.availableOi = MarketUtils.getAvailableOiUsd(
                market,
                _request.input.ticker,
                _prices.indexPrice,
                _prices.longMarketTokenPrice,
                _prices.indexBaseUnit,
                true
            ).toInt256();
        } else {
            state.availableOi = MarketUtils.getAvailableOiUsd(
                market,
                _request.input.ticker,
                _prices.indexPrice,
                _prices.shortMarketTokenPrice,
                _prices.indexBaseUnit,
                false
            ).toInt256();
        }

        state.initialTotalOi = state.longOi + state.shortOi;

        state.initialSkew = state.longOi.diff(state.shortOi);
        if (_request.input.isIncrease) {
            if (_request.input.sizeDelta > state.availableOi.toUint256()) revert PriceImpact_InsufficientLiquidity();
            state.sizeDeltaUsd = _request.input.sizeDelta.toInt256();
            state.updatedTotalOi = state.initialTotalOi + _request.input.sizeDelta;
            _request.input.isLong ? state.longOi += _request.input.sizeDelta : state.shortOi += _request.input.sizeDelta;
        } else {
            if (_request.input.sizeDelta > state.initialTotalOi) revert PriceImpact_InvalidDecrease();
            state.sizeDeltaUsd = -_request.input.sizeDelta.toInt256();
            state.updatedTotalOi = state.initialTotalOi - _request.input.sizeDelta;
            _request.input.isLong ? state.longOi -= _request.input.sizeDelta : state.shortOi -= _request.input.sizeDelta;
        }
        state.updatedSkew = state.longOi.diff(state.shortOi);

        // Compare the MSBs to determine whether a skew flip has occurred
        if ((state.initialSkew ^ state.updatedSkew) < 0) {
            /**
             * If Skew has flipped, the market initially goes to perfect harmony, then skews in the opposite direction.
             * As a result, the size delta that takes the market to skew = 0, is coutned as positive impact, and
             * the size delta that skews the market in the opposite direction is counted as negative impact.
             * The total price impact is calculated as the positive impact - the negative impact.
             */
            // Calculate positive impact before the sign flips
            int256 positiveImpact = _calculateImpact(
                state.sizeDeltaUsd,
                0,
                state.initialSkew,
                state.positiveSkewScalar,
                state.positiveLiquidityScalar,
                state.initialTotalOi,
                state.updatedTotalOi,
                state.availableOi,
                _request.input.isIncrease
            );
            // Calculate negative impact after the sign flips
            int256 negativeImpact = _calculateImpact(
                state.sizeDeltaUsd,
                state.updatedSkew,
                0,
                state.negativeSkewScalar,
                state.negativeLiquidityScalar,
                state.initialTotalOi,
                state.updatedTotalOi,
                state.availableOi,
                _request.input.isIncrease
            );
            // priceImpactUsd = positive expression - the negative expression
            priceImpactUsd = positiveImpact - negativeImpact;
        } else {
            // Get the skew scalar and liquidity scalar, depending on direction of price impact
            int256 skewScalar;
            int256 liquidityScalar;
            if (state.updatedSkew.abs() < state.initialSkew.abs()) {
                skewScalar = state.positiveSkewScalar;
                liquidityScalar = state.positiveLiquidityScalar;
            } else {
                skewScalar = state.negativeSkewScalar;
                liquidityScalar = state.negativeLiquidityScalar;
            }
            // Calculate the impact within bounds
            priceImpactUsd = _calculateImpact(
                state.sizeDeltaUsd,
                state.updatedSkew,
                state.initialSkew,
                skewScalar,
                liquidityScalar,
                state.initialTotalOi,
                state.updatedTotalOi,
                state.availableOi,
                _request.input.isIncrease
            );
        }

        // validate the impact delta on pool
        if (priceImpactUsd > 0) {
            priceImpactUsd = _validateImpactDelta(market, _request.input.ticker, priceImpactUsd);
        }
        // calculate the impacted price
        impactedPrice =
            _calculateImpactedPrice(_request.input.sizeDelta, _prices.indexPrice, priceImpactUsd, _request.input.isLong);
        // check the slippage if negative
        if (priceImpactUsd < 0) {
            _checkSlippage(impactedPrice, _prices.indexPrice, _request.input.maxSlippage);
        }
    }

    /**
     * ========================= Private Functions =========================
     */

    /**
     * PriceImpact = sizeDeltaUsd * skewScalar((initialSkew/initialTotalOi) - (updatedSkew/updatedTotalOi)) * liquidityScalar(sizeDeltaUsd / totalAvailableLiquidity)
     * @dev - Only calculates impact within bounds. Does not handle skew flip case.
     */
    function _calculateImpact(
        int256 _sizeDeltaUsd,
        int256 _updatedSkew,
        int256 _initialSkew,
        int256 _skewScalar,
        int256 _liquidityScalar,
        uint256 _initialTotalOi,
        uint256 _updatedTotalOi,
        int256 _availableOi,
        bool _isIncrease
    ) private pure returns (int256 priceImpactUsd) {
        /**
         * Fully reducing the open interest technically brings the market to perfect harmony.
         * To avoid incentivizing this case with positive impact, the price impact is set to 0.
         */
        if (_updatedTotalOi == 0) return 0;
        /**
         * If initialTotalOi is 0, the (initialSkew/initialTotalOi) term is cancelled out.
         * Price impact will always be negative when total oi before is 0.
         * In this case, skewFactor = skewScalar * (updatedSkew/updatedTotalOi)
         */
        int256 skewFactor = _initialTotalOi == 0
            ? -mulDivSigned(_updatedSkew, _skewScalar, _updatedTotalOi.toInt256())
            : mulDivSigned(_initialSkew, _skewScalar, _initialTotalOi.toInt256())
                - mulDivSigned(_updatedSkew, _skewScalar, _updatedTotalOi.toInt256());

        /**
         * If position is a decrease, the liquidity factor can be ignored, as the
         * available open interest isn't a limiting factor.
         */
        if (_isIncrease) {
            if (_sizeDeltaUsd > _availableOi) revert PriceImpact_InvalidState();
            int256 liquidityFactor = mulDivSigned(_sizeDeltaUsd, _liquidityScalar, _availableOi);

            // Calculates the cumulative impact on both skew, and liquidity as a percentage.
            int256 cumulativeImpact = mulDivSigned(skewFactor, liquidityFactor, SIGNED_PRICE_PRECISION);

            // Calculate the Price Impact
            priceImpactUsd = mulDivSigned(_sizeDeltaUsd, cumulativeImpact, SIGNED_PRICE_PRECISION);
        } else {
            priceImpactUsd = mulDivSigned(_sizeDeltaUsd, skewFactor, SIGNED_PRICE_PRECISION);
        }
    }

    function _calculateImpactedPrice(uint256 _sizeDeltaUsd, uint256 _indexPrice, int256 _priceImpactUsd, bool _isLong)
        private
        pure
        returns (uint256 impactedPrice)
    {
        // Get the price impact as a percentage
        uint256 percentageImpact = PRICE_PRECISION.percentage(_priceImpactUsd.abs(), _sizeDeltaUsd);

        // Impact the price by the same percentage
        uint256 impactToPrice = _indexPrice.percentage(percentageImpact, PRICE_PRECISION);

        if (_isLong) {
            if (_priceImpactUsd < 0) {
                impactedPrice = _indexPrice + impactToPrice;
            } else {
                impactedPrice = _indexPrice - impactToPrice;
            }
        } else {
            if (_priceImpactUsd < 0) {
                impactedPrice = _indexPrice - impactToPrice;
            } else {
                impactedPrice = _indexPrice + impactToPrice;
            }
        }
    }

    /**
     * Positive impact is capped by the impact pool.
     * If the positive impact is > impact pool, return the entire impact pool.
     */
    function _validateImpactDelta(IMarket market, string memory _ticker, int256 _priceImpactUsd)
        private
        view
        returns (int256)
    {
        int256 impactPoolUsd = market.getImpactPool(_ticker).toInt256();
        if (_priceImpactUsd > impactPoolUsd) {
            return impactPoolUsd;
        } else {
            return _priceImpactUsd;
        }
    }

    function _checkSlippage(uint256 _impactedPrice, uint256 _signedPrice, uint256 _maxSlippage) private pure {
        uint256 impactDelta = _signedPrice.delta(_impactedPrice);
        uint256 slippage = PRICE_PRECISION.percentage(impactDelta, _signedPrice);

        if (slippage > _maxSlippage) {
            revert PriceImpact_SlippageExceedsMax();
        }
    }

    function _getImpactValues(IMarket market, string memory _ticker) private view returns (ImpactState memory state) {
        (
            state.positiveSkewScalar,
            state.negativeSkewScalar,
            state.positiveLiquidityScalar,
            state.negativeLiquidityScalar
        ) = market.getImpactValues(_ticker);
        state.positiveSkewScalar = state.positiveSkewScalar.expandDecimals(2, 30);
        state.negativeSkewScalar = state.negativeSkewScalar.expandDecimals(2, 30);
        state.positiveLiquidityScalar = state.positiveLiquidityScalar.expandDecimals(2, 30);
        state.negativeLiquidityScalar = state.negativeLiquidityScalar.expandDecimals(2, 30);
    }
}
