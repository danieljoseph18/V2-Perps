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
import {Pool} from "../liquidity/Pool.sol";
import {Withdrawal} from "../liquidity/Withdrawal.sol";
import {mulDiv} from "@prb/math/Common.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Oracle} from "../oracle/Oracle.sol";

// library responsible for handling all price impact calculations
library PriceImpact {
    using SignedMath for int256;
    using SafeCast for uint256;
    using SafeCast for int256;

    uint256 public constant SCALAR = 1e18;

    struct ExecuteCache {
        IMarket.ImpactConfig impact;
        uint256 longOI;
        uint256 shortOI;
        uint256 sizeDeltaUSD;
        uint256 skewBefore;
        uint256 skewAfter;
        int256 priceImpactUsd;
        bool startingSkewLong;
        bool skewFlip;
    }

    function execute(IMarket market, Position.Request memory _request, uint256 _indexPrice, uint256 _indexBaseUnit)
        external
        view
        returns (uint256 impactedPrice, int256 priceImpactUsd)
    {
        // Construct the Cache
        ExecuteCache memory cache;

        cache.impact = market.getImpactConfig();
        cache.longOI = MarketUtils.getOpenInterestUsd(market, _indexPrice, _indexBaseUnit, true);
        cache.shortOI = MarketUtils.getOpenInterestUsd(market, _indexPrice, _indexBaseUnit, false);
        cache.sizeDeltaUSD = mulDiv(_request.input.sizeDelta, _indexPrice, _indexBaseUnit);
        cache.startingSkewLong = cache.longOI >= cache.shortOI;
        cache.skewBefore = cache.startingSkewLong ? cache.longOI - cache.shortOI : cache.shortOI - cache.longOI;
        if (_request.input.isIncrease) {
            _request.input.isLong ? cache.longOI += cache.sizeDeltaUSD : cache.shortOI += cache.sizeDeltaUSD;
        } else {
            _request.input.isLong ? cache.longOI -= cache.sizeDeltaUSD : cache.shortOI -= cache.sizeDeltaUSD;
        }
        cache.skewAfter = cache.longOI >= cache.shortOI ? cache.longOI - cache.shortOI : cache.shortOI - cache.longOI;
        cache.skewFlip = cache.longOI >= cache.shortOI != cache.startingSkewLong;
        // Calculate the Price Impact
        if (cache.skewFlip) {
            priceImpactUsd = _calculateSkewFlipImpactUsd(
                cache.skewBefore,
                cache.skewAfter,
                cache.impact.exponent,
                cache.impact.positiveFactor,
                cache.impact.negativeFactor
            );
        } else {
            priceImpactUsd = _calculateImpactUsd(
                cache.skewBefore,
                cache.skewAfter,
                cache.impact.exponent,
                cache.skewAfter >= cache.skewBefore ? cache.impact.negativeFactor : cache.impact.positiveFactor
            );
        }

        if (priceImpactUsd > 0) priceImpactUsd = _validateImpactDelta(market, priceImpactUsd);

        // Execute the Price Impact
        impactedPrice = _calculateImpactedPrice(
            cache.sizeDeltaUSD, priceImpactUsd.abs(), _indexBaseUnit, _request.input.sizeDelta, priceImpactUsd
        );
        // Check Slippage on Negative Impact
        if (priceImpactUsd < 0) {
            _checkSlippage(impactedPrice, _indexPrice, _request.input.maxSlippage);
        }
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

    // Correct for same side rebalance
    function _calculateImpactUsd(uint256 _skewBefore, uint256 _skewAfter, uint256 _exponent, uint256 _factor)
        internal
        pure
        returns (int256 impactUsd)
    {
        // Perform exponentiation using PRB Math library
        UD60x18 impactBefore = (ud(_skewBefore).powu(_exponent)).mul(ud(_factor));
        UD60x18 impactAfter = (ud(_skewAfter).powu(_exponent)).mul(ud(_factor));

        // Calculate impact in USD
        impactUsd = unwrap(impactBefore).toInt256() - unwrap(impactAfter).toInt256();
    }

    function _calculateSkewFlipImpactUsd(
        uint256 _skewBefore,
        uint256 _skewAfter,
        uint256 _exponent,
        uint256 _positiveFactor,
        uint256 _negativeFactor
    ) internal pure returns (int256 impactUsd) {
        // Perform exponentiation using PRB Math library
        UD60x18 impactBefore = (ud(_skewBefore).powu(_exponent)).mul(ud(_positiveFactor));
        UD60x18 impactAfter = (ud(_skewAfter).powu(_exponent)).mul(ud(_negativeFactor));

        // Calculate impact in USD
        impactUsd = unwrap(impactBefore).toInt256() - unwrap(impactAfter).toInt256();
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

    function _validateImpactDelta(IMarket market, int256 _priceImpactUsd) internal view returns (int256) {
        int256 impactPoolUsd = market.impactPoolUsd().toInt256();
        if (_priceImpactUsd > impactPoolUsd) {
            return impactPoolUsd;
        } else {
            return _priceImpactUsd;
        }
    }
}
