// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IMarket} from "../markets/interfaces/IMarket.sol";
import {IVault} from "../markets/interfaces/IVault.sol";
import {Position} from "../positions/Position.sol";
import {MarketUtils} from "../markets/MarketUtils.sol";
import {Casting} from "./Casting.sol";
import {Units} from "./Units.sol";
import {Execution} from "../positions/Execution.sol";
import {MathUtils} from "./MathUtils.sol";
import {MarketId} from "../types/MarketId.sol";

// library responsible for handling all price impact calculations
library PriceImpact {
    using Casting for uint256;
    using Casting for int256;
    using MathUtils for uint256;
    using MathUtils for int256;
    using Units for uint256;

    error PriceImpact_SizeDeltaIsZero();
    error PriceImpact_InsufficientLiquidity();
    error PriceImpact_InvalidState();
    error PriceImpact_SlippageExceedsMax();
    error PriceImpact_InvalidDecrease();

    uint256 private constant PRICE_PRECISION = 1e30;
    int256 private constant SIGNED_PRICE_PRECISION = 1e30;

    struct ImpactState {
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
     * The formula for price impact is:
     * sizeDeltaUsd * skewScalar((initialSkew/initialTotalOi) - (updatedSkew/updatedTotalOi)) * liquidityScalar(sizeDeltaUsd / totalAvailableLiquidity)
     *
     * Impact is calculated in USD, and is capped by the impact pool.
     *
     * Instead of adding / subtracting collateral, the price of the position is manipulated accordingly, by the same percentage as the impact.
     *
     * If the impact percentage exceeds the maximum slippage specified by the user, the transaction is reverted.
     */
    function execute(
        MarketId _id,
        IMarket market,
        IVault vault,
        Position.Request memory _request,
        Execution.Prices memory _prices
    ) external view returns (uint256 impactedPrice, int256 priceImpactUsd) {
        if (_request.input.sizeDelta == 0) revert PriceImpact_SizeDeltaIsZero();

        ImpactState memory state;

        state = _getImpactValues(_id, market, _request.input.ticker);

        state.longOi = market.getOpenInterest(_id, _request.input.ticker, true);
        state.shortOi = market.getOpenInterest(_id, _request.input.ticker, false);

        if (_request.input.isLong) {
            state.availableOi = MarketUtils.getAvailableOiUsd(
                _id,
                market,
                vault,
                _request.input.ticker,
                _prices.indexPrice,
                _prices.longMarketTokenPrice,
                _prices.indexBaseUnit,
                true
            ).toInt256();
        } else {
            state.availableOi = MarketUtils.getAvailableOiUsd(
                _id,
                market,
                vault,
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
             * As a result, the size delta that takes the market to skew = 0, is counted as positive impact, and
             * the size delta that skews the market in the opposite direction is counted as negative impact.
             * The total price impact is calculated as the positive impact - the negative impact.
             */
            int256 positiveImpact = _calculateImpact(
                state.sizeDeltaUsd,
                0,
                state.initialSkew,
                state.positiveLiquidityScalar,
                state.initialTotalOi,
                state.updatedTotalOi,
                state.availableOi,
                _request.input.isIncrease
            );

            int256 negativeImpact = _calculateImpact(
                state.sizeDeltaUsd,
                state.updatedSkew,
                0,
                state.negativeLiquidityScalar,
                state.initialTotalOi,
                state.updatedTotalOi,
                state.availableOi,
                _request.input.isIncrease
            );

            priceImpactUsd = positiveImpact - negativeImpact;
        } else {
            int256 liquidityScalar;
            if (state.updatedSkew.abs() < state.initialSkew.abs()) {
                liquidityScalar = state.positiveLiquidityScalar;
            } else {
                liquidityScalar = state.negativeLiquidityScalar;
            }

            // Calculate the impact within bounds (no skew flip has occurred)
            priceImpactUsd = _calculateImpact(
                state.sizeDeltaUsd,
                state.updatedSkew,
                state.initialSkew,
                liquidityScalar,
                state.initialTotalOi,
                state.updatedTotalOi,
                state.availableOi,
                _request.input.isIncrease
            );
        }

        if (priceImpactUsd > 0) {
            priceImpactUsd = _validateImpactDelta(_id, market, _request.input.ticker, priceImpactUsd);
        }

        impactedPrice =
            _calculateImpactedPrice(_request.input.sizeDelta, _prices.indexPrice, priceImpactUsd, _request.input.isLong);

        if (priceImpactUsd < 0) {
            _checkSlippage(impactedPrice, _prices.indexPrice, _request.input.maxSlippage);
        }
    }

    /**
     * =========================================== Private Functions ===========================================
     */
    function _calculateImpact(
        int256 _sizeDeltaUsd,
        int256 _updatedSkew,
        int256 _initialSkew,
        int256 _liquidityScalar,
        uint256 _initialTotalOi,
        uint256 _updatedTotalOi,
        int256 _availableOi,
        bool _isIncrease
    ) private pure returns (int256 priceImpactUsd) {
        // Avoid incentivizing full decreases (market technically goes to perfect harmony.)
        if (_updatedTotalOi == 0) return 0;

        /**
         * If initialTotalOi is 0, the (initialSkew/initialTotalOi) term is cancelled out.
         * Price impact will always be negative when total oi before is 0.
         * In this case, skewFactor = skewScalar * (updatedSkew/updatedTotalOi)
         */
        int256 skewFactor = _initialTotalOi == 0
            ? -_updatedSkew.sDivWad(_updatedTotalOi.toInt256())
            : _initialSkew.sDivWad(_initialTotalOi.toInt256()) - _updatedSkew.sDivWad(_updatedTotalOi.toInt256());

        /**
         * If position is a decrease, the liquidity factor can be ignored, as the
         * available open interest isn't a limiting factor.
         */
        if (_isIncrease) {
            if (_sizeDeltaUsd > _availableOi) revert PriceImpact_InvalidState();
            int256 liquidityFactor = _sizeDeltaUsd.mulDivSigned(_liquidityScalar, _availableOi);

            // Calculates the cumulative impact on both skew, and liquidity as a percentage.
            int256 cumulativeImpact = skewFactor.mulDivSigned(liquidityFactor, SIGNED_PRICE_PRECISION);

            priceImpactUsd = _sizeDeltaUsd.mulDivSigned(cumulativeImpact, SIGNED_PRICE_PRECISION);
        } else {
            priceImpactUsd = _sizeDeltaUsd.mulDivSigned(skewFactor, SIGNED_PRICE_PRECISION);
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
    function _validateImpactDelta(MarketId _id, IMarket market, string memory _ticker, int256 _priceImpactUsd)
        private
        view
        returns (int256)
    {
        int256 impactPoolUsd = market.getImpactPool(_id, _ticker).toInt256();
        if (_priceImpactUsd > impactPoolUsd) {
            return impactPoolUsd;
        } else {
            return _priceImpactUsd;
        }
    }

    function _checkSlippage(uint256 _impactedPrice, uint256 _signedPrice, uint256 _maxSlippage) private pure {
        uint256 impactDelta = _signedPrice.absDiff(_impactedPrice);
        uint256 slippage = PRICE_PRECISION.percentage(impactDelta, _signedPrice);

        if (slippage > _maxSlippage) {
            revert PriceImpact_SlippageExceedsMax();
        }
    }

    function _getImpactValues(MarketId _id, IMarket market, string memory _ticker)
        private
        view
        returns (ImpactState memory state)
    {
        (state.positiveLiquidityScalar, state.negativeLiquidityScalar) = market.getImpactValues(_id, _ticker);
        state.positiveLiquidityScalar = state.positiveLiquidityScalar.expandDecimals(4, 30);
        state.negativeLiquidityScalar = state.negativeLiquidityScalar.expandDecimals(4, 30);
    }
}
