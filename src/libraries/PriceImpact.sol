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
    }

    /**
     * PriceImpact = sizeDeltaUsd * skewScalar((skewBefore/totalOiBefore) - (skewAfter/totalOiAfter)) * liquidityScalar(sizeDeltaUsd / totalAvailableLiquidity)
     */
    // @audit - I think we can make this more efficient.
    function execute(IMarket market, Position.Request memory _request, Execution.State memory _orderState)
        external
        view
        returns (uint256 impactedPrice, int256 priceImpactUsd)
    {
        ImpactState memory state;

        state.impact = MarketUtils.getImpactConfig(market, _request.input.assetId);

        state.longOi = MarketUtils.getOpenInterestUsd(market, _request.input.assetId, true);
        state.shortOi = MarketUtils.getOpenInterestUsd(market, _request.input.assetId, false);

        if (_request.input.sizeDelta == 0) {
            revert PriceImpact_SizeDeltaIsZero();
        }

        // Calculate the impact on available liquidity
        uint256 availableOi = MarketUtils.getTotalAvailableOiUsd(
            market, _request.input.assetId, _orderState.longMarketTokenPrice, _orderState.shortMarketTokenPrice
        );
        // Can't trade on an empty pool
        if (availableOi == 0) {
            revert PriceImpact_NoAvailableLiquidity();
        }

        state.oiPercentage = mulDiv(_request.input.sizeDelta, PRICE_PRECISION, availableOi).toInt256();

        state.totalOiBefore = state.longOi + state.shortOi;

        state.skewBefore = state.longOi.toInt256() - state.shortOi.toInt256();

        if (_request.input.isIncrease) {
            _request.input.isLong ? state.longOi += _request.input.sizeDelta : state.shortOi += _request.input.sizeDelta;
            state.totalOiAfter = state.totalOiBefore + _request.input.sizeDelta;
        } else {
            _request.input.isLong ? state.longOi -= _request.input.sizeDelta : state.shortOi -= _request.input.sizeDelta;
            state.totalOiAfter = state.totalOiBefore - _request.input.sizeDelta;
        }

        state.skewAfter = state.longOi.toInt256() - state.shortOi.toInt256();

        // If total open interest before or after is zero, calculate impact accordingly
        if (state.totalOiBefore == 0 || state.totalOiAfter == 0) {
            priceImpactUsd = _calculateImpactOnEmptyPool(state, _request.input.sizeDelta);
        } else {
            // Compare the MSBs to determine whether a skew flip has occurred
            bool skewFlip = (state.skewBefore ^ state.skewAfter) < 0;

            // If Skew Flip -> positive impact until skew = 0, and negative impact after, then combine
            // If no skew flip, impact within bounds
            priceImpactUsd = skewFlip
                ? _calculateFlipImpact(
                    state.impact,
                    _request.input.sizeDelta.toInt256(),
                    state.totalOiBefore.toInt256(),
                    state.totalOiAfter.toInt256(),
                    state.skewBefore,
                    state.skewAfter,
                    state.oiPercentage
                )
                : _calculateImpactWithinBounds(
                    state.impact,
                    _request.input.sizeDelta.toInt256(),
                    state.totalOiBefore.toInt256(),
                    state.totalOiAfter.toInt256(),
                    state.skewBefore,
                    state.skewAfter,
                    state.oiPercentage
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
     * ========================= Internal Functions =========================
     */

    // Function to handle the case where open interest before/after is 0
    /**
     * 0 terms are cancelled out, so we can simplify the equation for each side to:
     *
     * If Total Oi Before is 0:
     *  PriceImpact = sizeDeltaUsd * skewScalar(skewAfter/totalOiAfter) * liquidityScalar(sizeDeltaUsd / totalAvailableLiquidity)
     * If Total Oi After is 0:
     *  PriceImpact = sizeDeltaUsd * skewScalar(skewBefore/totalOiBefore) * liquidityScalar(sizeDeltaUsd / totalAvailableLiquidity)
     *
     * If total oi after is 0, return 0 to avoid incentivizing this case. Otherwise users would receive a positive impact
     * for full-closing the open interest, as 0 skew = is technically a perfect balance.
     */
    function _calculateImpactOnEmptyPool(ImpactState memory _state, uint256 _sizeDelta)
        internal
        pure
        returns (int256 priceImpact)
    {
        if (_state.totalOiAfter == 0) return 0;

        if (_state.totalOiBefore != 0) {
            revert PriceImpact_InvalidState();
        }

        // If total open interest before is 0, charge the entire skew factor after
        int256 skewImpact = mulDivSigned(_state.skewAfter, SIGNED_PRICE_PRECISION, _state.totalOiAfter.toInt256());

        // Price impact will always be negative when total oi before is 0
        int256 skewScalar = _state.impact.negativeSkewScalar;
        int256 liquidityScalar = _state.impact.negativeLiquidityScalar;

        int256 liquidityImpact = mulDivSigned(liquidityScalar, _state.oiPercentage, SIGNED_PRICE_PRECISION);
        // Multiply by -1 as impact should always be negative here
        int256 totalImpact = mulDivSigned(
            mulDivSigned(skewScalar, skewImpact, SIGNED_PRICE_PRECISION), liquidityImpact, SIGNED_PRICE_PRECISION
        );
        // if the total impact is > 0, flip the sign
        if (totalImpact > 0) totalImpact = -totalImpact;
        // Don't need to check upper boundary of 1e18, as impact should always be negative here
        if (totalImpact < -1e18 || totalImpact > 0) {
            revert PriceImpact_InvalidTotalImpact(totalImpact);
        }
        priceImpact = mulDivSigned(_sizeDelta.toInt256(), totalImpact, SIGNED_PRICE_PRECISION);
    }

    /**
     * PriceImpact = sizeDeltaUsd * skewScalar((skewBefore/totalOiBefore) - (skewAfter/totalOiAfter)) * liquidityScalar(sizeDeltaUsd / totalAvailableLiquidity)
     */
    // If skew factor before = 0 -> impact is all negative, charge the entire skew factor after
    // If skew factor after = 0 -> impact is all positive, charge the entire skew factor before
    function _calculateImpactWithinBounds(
        IMarket.ImpactConfig memory _impact,
        int256 _sizeDeltaUsd,
        int256 _totalOiBefore,
        int256 _totalOiAfter,
        int256 _skewBefore,
        int256 _skewAfter,
        int256 _oiPercentage
    ) internal pure returns (int256 priceImpactUsd) {
        int256 skewScalar;
        int256 liquidityScalar;
        // If Price Impact is Positive
        if (_skewAfter.abs() < _skewBefore.abs()) {
            skewScalar = _impact.positiveSkewScalar;
            liquidityScalar = _impact.positiveLiquidityScalar;
        } else {
            skewScalar = _impact.negativeSkewScalar;
            liquidityScalar = _impact.negativeLiquidityScalar;
        }
        int256 skewImpact = mulDivSigned(
            skewScalar,
            mulDivSigned(_skewBefore, SIGNED_PRICE_PRECISION, _totalOiBefore)
                - mulDivSigned(_skewAfter, SIGNED_PRICE_PRECISION, _totalOiAfter),
            SIGNED_PRICE_PRECISION
        );
        int256 liquidityImpact = mulDivSigned(liquidityScalar, _oiPercentage, SIGNED_PRICE_PRECISION);
        int256 totalImpact = mulDivSigned(skewImpact, liquidityImpact, SIGNED_PRICE_PRECISION);
        priceImpactUsd = mulDivSigned(_sizeDeltaUsd, totalImpact, SIGNED_PRICE_PRECISION);
    }

    // impact is positive toward 0, so positive impact is simply the skew factor before
    // negative impact is the skew factor after
    /**
     * PriceImpact = sizeDeltaUsd * skewScalar((skewBefore/totalOiBefore) - (skewAfter/totalOiAfter)) * liquidityScalar(sizeDeltaUsd / totalAvailableLiquidity)
     */
    function _calculateFlipImpact(
        IMarket.ImpactConfig memory _impact,
        int256 _sizeDeltaUsd,
        int256 _totalOiBefore,
        int256 _totalOiAfter,
        int256 _skewBefore,
        int256 _skewAfter,
        int256 _oiPercentage
    ) internal pure returns (int256 priceImpactUsd) {
        // Calculate the positive impact before the sign flips
        int256 positiveImpact = _calculateImpactWithinBounds(
            _impact, _sizeDeltaUsd, _totalOiBefore, _totalOiAfter, _skewBefore, 0, _oiPercentage
        );
        // Calculate the negative impact after the sign flips
        int256 negativeImpact = _calculateImpactWithinBounds(
            _impact, _sizeDeltaUsd, _totalOiBefore, _totalOiAfter, 0, _skewAfter, _oiPercentage
        );
        // return the positive expresion - the negative expression
        priceImpactUsd = positiveImpact - negativeImpact;
    }

    function _checkSlippage(uint256 _impactedPrice, uint256 _signedPrice, uint256 _maxSlippage) internal pure {
        uint256 impactDelta =
            _signedPrice > _impactedPrice ? _signedPrice - _impactedPrice : _impactedPrice - _signedPrice;
        uint256 slippage = mulDiv(impactDelta, PRICE_PRECISION, _signedPrice);
        if (slippage > _maxSlippage) {
            revert PriceImpact_SlippageExceedsMax();
        }
    }

    /**
     * Get the impacted percentage of the size delta
     * Impact the price by the same percentage
     * Return the impacted price
     */
    function _calculateImpactedPrice(uint256 _sizeDeltaUsd, uint256 _indexPrice, int256 _priceImpactUsd)
        internal
        pure
        returns (uint256 impactedPrice)
    {
        uint256 percentageImpact = mulDiv(_priceImpactUsd.abs(), PRICE_PRECISION, _sizeDeltaUsd);
        uint256 impactToPrice = mulDiv(percentageImpact, _indexPrice, PRICE_PRECISION);
        if (_priceImpactUsd < 0) {
            impactedPrice = _indexPrice - impactToPrice;
        } else {
            impactedPrice = _indexPrice + impactToPrice;
        }
    }

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
}
