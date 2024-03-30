// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IMarket} from "../markets/interfaces/IMarket.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {Position} from "../positions/Position.sol";
import {MarketUtils} from "../markets/MarketUtils.sol";
import {mulDiv, mulDivSigned} from "@prb/math/Common.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Execution} from "../positions/Execution.sol";
import {Oracle} from "../oracle/Oracle.sol";
import {IPriceFeed} from "../oracle/interfaces/IPriceFeed.sol";
import {MarketUtils} from "../markets/MarketUtils.sol";

// library responsible for handling all price impact calculations
library PriceImpact {
    using SignedMath for int256;
    using SafeCast for uint256;
    using SafeCast for int256;

    error PriceImpact_InvalidTotalImpact(int256 totalImpact);
    error PriceImpact_SizeDeltaIsZero();
    error PriceImpact_NoAvailableLiquidity();
    error PriceImpact_InvalidState();
    error PriceImpact_SlippageExceedsMax();

    uint256 private constant PRICE_PRECISION = 1e30;
    int256 private constant SIGNED_PRICE_PRECISION = 1e30;

    struct ImpactState {
        IMarket.ImpactConfig impact;
        uint256 longOi;
        uint256 shortOi;
        uint256 totalOiBefore;
        uint256 totalOiAfter;
        int256 skewBefore;
        int256 skewAfter;
        int256 priceImpactUsd;
        int256 oiPercentage;
        uint256 availableOi;
    }

    /**
     * Price impact is calculated as a function of the following:
     * 1. How the action affects the skew of the market. Positions should be punished for increasing, and rewarded for decreasing.
     * 2. The liquidity of the market. The more illiquid, the higher the price impact will be.
     */
    function execute(IMarket market, Position.Request memory _request, Execution.State memory _orderState)
        external
        view
        returns (uint256 impactedPrice, int256 priceImpactUsd)
    {
        if (_request.input.sizeDelta == 0) revert PriceImpact_SizeDeltaIsZero();

        ImpactState memory state;
        state.impact = MarketUtils.getImpactConfig(market, _request.input.assetId);
        // Get long / short Oi -> used to calculate skew
        state.longOi = MarketUtils.getOpenInterest(market, _request.input.assetId, true);
        state.shortOi = MarketUtils.getOpenInterest(market, _request.input.assetId, false);
        // Used to alculate the impact on available liquidity
        state.availableOi = MarketUtils.getTotalAvailableOiUsd(
            market, _request.input.assetId, _orderState.longMarketTokenPrice, _orderState.shortMarketTokenPrice
        );
        if (state.availableOi == 0) revert PriceImpact_NoAvailableLiquidity();

        state.totalOiBefore = state.longOi + state.shortOi;
        int256 sizeDeltaUsd;
        if (_request.input.isIncrease) {
            sizeDeltaUsd = _request.input.sizeDelta.toInt256();
            state.totalOiAfter = state.totalOiBefore + _request.input.sizeDelta;
        } else {
            sizeDeltaUsd = -_request.input.sizeDelta.toInt256();
            state.totalOiAfter = state.totalOiBefore - _request.input.sizeDelta;
        }
        state.skewBefore = state.longOi.toInt256() - state.shortOi.toInt256();
        state.skewAfter = state.longOi.toInt256() - state.shortOi.toInt256() + sizeDeltaUsd;

        // Compare the MSBs to determine whether a skew flip has occurred
        if ((state.skewBefore ^ state.skewAfter) < 0) {
            /**
             * If Skew has flipped, the market initially goes to perfect harmony, then skews in the opposite direction.
             * As a result, the size delta that takes the market to skew = 0, is coutned as positive impact, and
             * the size delta that skews the market in the opposite direction is counted as negative impact.
             * The total price impact is calculated as the positive impact - the negative impact.
             */
            // Calculate positive impact before the sign flips
            int256 positiveImpact = _calculateImpact(
                sizeDeltaUsd,
                state.skewBefore,
                0,
                state.impact.positiveSkewScalar,
                state.impact.positiveLiquidityScalar,
                state.totalOiBefore,
                state.totalOiAfter,
                state.availableOi
            );
            // Calculate negative impact after the sign flips
            int256 negativeImpact = _calculateImpact(
                sizeDeltaUsd,
                0,
                state.skewAfter,
                state.impact.negativeSkewScalar,
                state.impact.negativeLiquidityScalar,
                state.totalOiBefore,
                state.totalOiAfter,
                state.availableOi
            );
            // priceImpactUsd = positive expression - the negative expression
            priceImpactUsd = positiveImpact - negativeImpact;
        } else {
            /**
             * Fully reducing the open interest technically brings the market to perfect harmony.
             * To avoid incentivizing this case with positive impact, the price impact is set to 0.
             */
            if (state.totalOiAfter == 0) return (_orderState.indexPrice, 0);
            // Get the skew scalar and liquidity scalar, depending on direction of price impact
            int256 skewScalar;
            int256 liquidityScalar;
            if (state.skewAfter.abs() < state.skewBefore.abs()) {
                skewScalar = state.impact.positiveSkewScalar;
                liquidityScalar = state.impact.positiveLiquidityScalar;
            } else {
                skewScalar = state.impact.negativeSkewScalar;
                liquidityScalar = state.impact.negativeLiquidityScalar;
            }
            // Calculate the impact within bounds
            priceImpactUsd = _calculateImpact(
                sizeDeltaUsd,
                state.skewAfter,
                state.skewBefore,
                skewScalar,
                liquidityScalar,
                state.totalOiBefore,
                state.totalOiAfter,
                state.availableOi
            );
        }

        // validate the impact delta on pool
        if (priceImpactUsd > 0) {
            priceImpactUsd = _validateImpactDelta(market, _request.input.assetId, priceImpactUsd);
        }
        // calculate the impacted price
        impactedPrice = _calculateImpactedPrice(_request.input.sizeDelta, _orderState.indexPrice, priceImpactUsd);
        // check the slippage if negative
        if (priceImpactUsd < 0) {
            _checkSlippage(impactedPrice, _orderState.indexPrice, _request.input.maxSlippage);
        }
    }

    /**
     * PriceImpact = sizeDeltaUsd * skewScalar((skewBefore/totalOiBefore) - (skewAfter/totalOiAfter)) * liquidityScalar(sizeDeltaUsd / totalAvailableLiquidity)
     * @dev - Only calculates impact within bounds. Does not handle skew flip case.
     */
    function _calculateImpact(
        int256 _sizeDeltaUsd,
        int256 _skewAfter,
        int256 _skewBefore,
        int256 _skewScalar,
        int256 _liquidityScalar,
        uint256 _totalOiBefore,
        uint256 _totalOiAfter,
        uint256 _availableOi
    ) internal pure returns (int256 priceImpactUsd) {
        /**
         * If totalOiBefore is 0, the (skewBefore/totalOiBefore) term is cancelled out.
         * In this case, skewFactor = skewScalar * (skewAfter/totalOiAfter)
         */
        int256 skewFactor = _totalOiBefore == 0
            ? mulDivSigned(_skewAfter, _skewScalar, _totalOiAfter.toInt256())
            : mulDivSigned(_skewBefore, _skewScalar, _totalOiBefore.toInt256())
                - mulDivSigned(_skewAfter, _skewScalar, _totalOiAfter.toInt256());
        // availableOi != 0, and sizeDelta is always <= availableOi.
        int256 liquidityFactor = mulDivSigned(_sizeDeltaUsd, _liquidityScalar, _availableOi.toInt256());
        // Calculates the cumulative impact on both skew, and liquidity as a percentage.
        int256 cumulativeImpact = mulDivSigned(skewFactor, liquidityFactor, SIGNED_PRICE_PRECISION);
        // Calculate the Price Impact
        priceImpactUsd = mulDivSigned(_sizeDeltaUsd, cumulativeImpact, SIGNED_PRICE_PRECISION);
    }

    /**
     * ========================= Internal Functions =========================
     */
    function _calculateImpactedPrice(uint256 _sizeDeltaUsd, uint256 _indexPrice, int256 _priceImpactUsd)
        internal
        pure
        returns (uint256 impactedPrice)
    {
        // Get the price impact as a percentage
        uint256 percentageImpact = mulDiv(_priceImpactUsd.abs(), PRICE_PRECISION, _sizeDeltaUsd);
        // Impact the price by the same percentage
        uint256 impactToPrice = mulDiv(percentageImpact, _indexPrice, PRICE_PRECISION);
        if (_priceImpactUsd < 0) {
            impactedPrice = _indexPrice - impactToPrice;
        } else {
            impactedPrice = _indexPrice + impactToPrice;
        }
    }

    /**
     * Positive impact is capped by the impact pool.
     * If the positive impact is > impact pool, return the entire impact pool.
     */
    function _validateImpactDelta(IMarket market, bytes32 _assetId, int256 _priceImpactUsd)
        internal
        view
        returns (int256)
    {
        int256 impactPoolUsd = MarketUtils.getImpactPool(market, _assetId).toInt256();
        if (_priceImpactUsd > impactPoolUsd) {
            return impactPoolUsd;
        } else {
            return _priceImpactUsd;
        }
    }

    function _checkSlippage(uint256 _impactedPrice, uint256 _signedPrice, uint256 _maxSlippage) internal pure {
        uint256 impactDelta =
            _signedPrice > _impactedPrice ? _signedPrice - _impactedPrice : _impactedPrice - _signedPrice;
        uint256 slippage = mulDiv(impactDelta, PRICE_PRECISION, _signedPrice);
        if (slippage > _maxSlippage) {
            revert PriceImpact_SlippageExceedsMax();
        }
    }
}
