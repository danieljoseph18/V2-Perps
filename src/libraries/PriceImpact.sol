//  ,----,------------------------------,------.
//   | ## |                              |    - |
//   | ## |                              |    - |
//   |    |------------------------------|    - |
//   |    ||............................||      |
//   |    ||,-                        -.||      |
//   |    ||___                      ___||    ##|
//   |    ||---`--------------------'---||      |
//   `--mb'|_|______________________==__|`------'

//    ____  ____  ___ _   _ _____ _____ ____
//   |  _ \|  _ \|_ _| \ | |_   _|___ /|  _ \
//   | |_) | |_) || ||  \| | | |   |_ \| |_) |
//   |  __/|  _ < | || |\  | | |  ___) |  _ <
//   |_|   |_| \_\___|_| \_| |_| |____/|_| \_\

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {IMarket} from "../markets/interfaces/IMarket.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {ud, UD60x18, unwrap} from "@prb/math/UD60x18.sol";
import {sd, SD59x18, unwrap} from "@prb/math/SD59x18.sol";
import {Position} from "../positions/Position.sol";
import {MarketUtils} from "../markets/MarketUtils.sol";
import {Pool} from "../markets/Pool.sol";
import {mulDiv, mulDivSigned} from "@prb/math/Common.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Order} from "../positions/Order.sol";
import {Oracle} from "../oracle/Oracle.sol";
import {IPriceFeed} from "../oracle/interfaces/IPriceFeed.sol";
import {console, console2} from "forge-std/Test.sol";

// library responsible for handling all price impact calculations
library PriceImpact {
    using SignedMath for int256;
    using SafeCast for uint256;
    using SafeCast for int256;

    error PriceImpact_InvalidTotalImpact(int256 totalImpact);

    uint256 public constant SCALAR = 1e18;
    int256 public constant SIGNED_SCALAR = 1e18;

    struct ExecutionState {
        IMarket.ImpactConfig impact;
        uint256 longOi;
        uint256 shortOi;
        uint256 sizeDeltaUsd;
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
    // @audit - should OI be OI before size delta or after??
    // @audit - should be before delta for skewBefore and
    // after delta for skew after as skewAfter can be > totalOiBefore - solves 0 case
    function execute(
        IMarket market,
        IPriceFeed priceFeed,
        Position.Request memory _request,
        Order.ExecutionState memory _orderState
    ) external view returns (uint256 impactedPrice, int256 priceImpactUsd) {
        ExecutionState memory state;

        state.impact = market.getImpactConfig(_request.input.indexToken);
        state.longOi = MarketUtils.getOpenInterestUsd(
            market, _request.input.indexToken, _orderState.indexPrice, _orderState.indexBaseUnit, true
        );
        state.shortOi = MarketUtils.getOpenInterestUsd(
            market, _request.input.indexToken, _orderState.indexPrice, _orderState.indexBaseUnit, false
        );
        state.sizeDeltaUsd = mulDiv(_request.input.sizeDelta, _orderState.indexPrice, _orderState.indexBaseUnit);

        require(state.sizeDeltaUsd != 0, "PriceImpact: Size delta is 0");

        // Calculate the impact on available liquidity
        uint256 availableOi = MarketUtils.getTotalAvailableOiUsd(
            market,
            _request.input.indexToken,
            _orderState.longMarketTokenPrice,
            _orderState.shortMarketTokenPrice,
            Oracle.getLongBaseUnit(priceFeed), // @gas cache elsewhere?
            Oracle.getShortBaseUnit(priceFeed)
        );
        // Can't trade on an empty pool
        require(availableOi > 0, "PriceImpact: No available liquidity");
        state.oiPercentage = mulDiv(state.sizeDeltaUsd, SCALAR, availableOi).toInt256();

        state.totalOiBefore = state.longOi + state.shortOi;

        state.skewBefore = state.longOi.toInt256() - state.shortOi.toInt256();

        if (_request.input.isIncrease) {
            _request.input.isLong ? state.longOi += state.sizeDeltaUsd : state.shortOi += state.sizeDeltaUsd;
            state.totalOiAfter = state.totalOiBefore + state.sizeDeltaUsd;
        } else {
            _request.input.isLong ? state.longOi -= state.sizeDeltaUsd : state.shortOi -= state.sizeDeltaUsd;
            state.totalOiAfter = state.totalOiBefore - state.sizeDeltaUsd;
        }

        state.skewAfter = state.longOi.toInt256() - state.shortOi.toInt256();

        // If total open interest before or after is zero, calculate impact accordingly
        if (state.totalOiBefore == 0 || state.totalOiAfter == 0) {
            priceImpactUsd = _calculateImpactOnEmptyPool(state);
        } else {
            // Check if a skew flip has occurred
            bool skewFlip = state.skewBefore * state.skewAfter < 0;

            // If Skew Flip -> positive impact until skew = 0, and negative impact after, then combine
            // If no skew flip, impact within bounds
            priceImpactUsd = skewFlip
                ? _calculateFlipImpact(
                    state.impact,
                    state.sizeDeltaUsd.toInt256(),
                    state.totalOiBefore.toInt256(),
                    state.totalOiAfter.toInt256(),
                    state.skewBefore,
                    state.skewAfter,
                    state.oiPercentage
                )
                : _calculateImpactWithinBounds(
                    state.impact,
                    state.sizeDeltaUsd.toInt256(),
                    state.totalOiBefore.toInt256(),
                    state.totalOiAfter.toInt256(),
                    state.skewBefore,
                    state.skewAfter,
                    state.oiPercentage
                );
        }

        // validate the impact delta on pool
        if (priceImpactUsd > 0) {
            priceImpactUsd = _validateImpactDelta(market, _request.input.indexToken, priceImpactUsd);
        }
        // calculate the impacted price
        impactedPrice = _calculateImpactedPrice(
            state.sizeDeltaUsd,
            priceImpactUsd.abs(),
            _orderState.indexBaseUnit,
            _request.input.sizeDelta,
            priceImpactUsd
        );
        // check the slippage if negative
        if (priceImpactUsd < 0) {
            _checkSlippage(impactedPrice, _orderState.indexPrice, _request.input.maxSlippage);
        }
    }

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
    function _calculateImpactOnEmptyPool(ExecutionState memory _state) internal pure returns (int256 priceImpact) {
        if (_state.totalOiAfter == 0) return 0;

        require(_state.totalOiBefore == 0, "PriceImpact: Invalid state");

        // If total open interest before is 0, charge the entire skew factor after
        int256 skewImpact = mulDivSigned(_state.skewAfter, SIGNED_SCALAR, _state.totalOiAfter.toInt256());

        // Price impact will always be negative when total oi before is 0
        int256 skewScalar = _state.impact.negativeSkewScalar;
        int256 liquidityScalar = _state.impact.negativeLiquidityScalar;

        int256 liquidityImpact = mulDivSigned(liquidityScalar, _state.oiPercentage, SIGNED_SCALAR);
        console2.log("Liquidity Impact: ", liquidityImpact);
        // Multiply by -1 as impact should always be negative here
        int256 totalImpact =
            mulDivSigned(mulDivSigned(skewScalar, skewImpact, SIGNED_SCALAR), liquidityImpact, SIGNED_SCALAR);
        // if the total impact is > 0, flip the sign
        if (totalImpact > 0) totalImpact = totalImpact * -1;
        console2.log("Total Impact: ", totalImpact);
        // Don't need to check upper boundary of 1e18, as impact should always be negative here
        if (totalImpact < -1e18 || totalImpact > 0) {
            revert PriceImpact_InvalidTotalImpact(totalImpact);
        }
        priceImpact = mulDivSigned(_state.sizeDeltaUsd.toInt256(), totalImpact, SIGNED_SCALAR);
        console2.log("Price Impact: ", priceImpact);
    }

    // If positive, needs to be capped by the impact pool
    // @audit - math / edge cases
    // @gas - probably more efficient to use PRB Math here
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
            mulDivSigned(_skewBefore, SIGNED_SCALAR, _totalOiBefore)
                - mulDivSigned(_skewAfter, SIGNED_SCALAR, _totalOiAfter),
            SIGNED_SCALAR
        );
        int256 liquidityImpact = mulDivSigned(liquidityScalar, _oiPercentage, SIGNED_SCALAR);

        int256 totalImpact = mulDivSigned(skewImpact, liquidityImpact, SIGNED_SCALAR);

        priceImpactUsd = mulDivSigned(_sizeDeltaUsd, totalImpact, SIGNED_SCALAR);
    }

    // impact is positive toward 0, so positive impact is simply the skew factor before
    // negative impact is the skew factor after
    // @audit - math / edge cases
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

    ///////////////////////////////
    // INTERNAL HELPER FUNCTIONS //
    ///////////////////////////////

    function _checkSlippage(uint256 _impactedPrice, uint256 _signedPrice, uint256 _maxSlippage) internal pure {
        uint256 impactDelta =
            _signedPrice > _impactedPrice ? _signedPrice - _impactedPrice : _impactedPrice - _signedPrice;
        uint256 slippage = mulDiv(impactDelta, SCALAR, _signedPrice);
        require(slippage <= _maxSlippage, "slippage exceeds max");
    }

    function _calculateImpactedPrice(
        uint256 _sizeDeltaUsd,
        uint256 _absPriceImpactUsd,
        uint256 _tokenUnit,
        uint256 _amountIn,
        int256 _priceImpactUsd
    ) internal pure returns (uint256) {
        uint256 impactPercentage = mulDiv(_absPriceImpactUsd, _tokenUnit, _sizeDeltaUsd);
        uint256 absImpactAmount = mulDiv(_amountIn, impactPercentage, SCALAR);
        uint256 indexTokensAfterImpact = _priceImpactUsd > 0 ? _amountIn + absImpactAmount : _amountIn - absImpactAmount;

        return mulDiv(_sizeDeltaUsd, _tokenUnit, indexTokensAfterImpact);
    }

    function _validateImpactDelta(IMarket market, address _indexToken, int256 _priceImpactUsd)
        internal
        view
        returns (int256)
    {
        int256 impactPoolUsd = market.getImpactPool(_indexToken).toInt256();
        if (_priceImpactUsd > impactPoolUsd) {
            return impactPoolUsd;
        } else {
            return _priceImpactUsd;
        }
    }
}
