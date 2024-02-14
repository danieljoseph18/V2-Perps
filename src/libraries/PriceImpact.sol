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

// library responsible for handling all price impact calculations
library PriceImpact {
    using SignedMath for int256;
    using SafeCast for uint256;
    using SafeCast for int256;

    uint256 public constant SCALAR = 1e18;
    uint256 public constant MAX_PRICE_IMPACT = 0.33e18; // 33%

    struct Params {
        uint256 longTokenBalance;
        uint256 shortTokenBalance;
        uint256 longTokenPrice;
        uint256 shortTokenPrice;
        uint256 amountIn;
        uint256 maxSlippage;
        bool isIncrease;
        bool isLongToken;
        uint256 longBaseUnit;
        uint256 shortBaseUnit;
    }

    struct PositionCache {
        uint256 longOI;
        uint256 shortOI;
        uint256 sizeDeltaUSD;
        uint256 skewBefore;
        uint256 skewAfter;
        int256 priceImpactUsd;
        bool startingSkewLong;
        bool skewFlip;
    }

    /////////////
    // TRADING //
    /////////////

    function executeForPosition(
        IMarket _market,
        Position.Request memory _request,
        uint256 _signedBlockPrice,
        uint256 _indexBaseUnit
    ) external view returns (uint256 impactedPrice) {
        // Construct the Cache
        PositionCache memory cache;
        IMarket.ImpactConfig memory impact = _market.getImpactConfig();

        cache.longOI = MarketUtils.getLongOpenInterestUSD(_market, _signedBlockPrice, _indexBaseUnit);
        cache.shortOI = MarketUtils.getShortOpenInterestUSD(_market, _signedBlockPrice, _indexBaseUnit);
        cache.sizeDeltaUSD = mulDiv(_request.input.sizeDelta, _signedBlockPrice, _indexBaseUnit);
        cache.startingSkewLong = cache.longOI > cache.shortOI;
        cache.skewBefore = cache.startingSkewLong ? cache.longOI - cache.shortOI : cache.shortOI - cache.longOI;
        if (_request.input.isIncrease) {
            _request.input.isLong ? cache.longOI += cache.sizeDeltaUSD : cache.shortOI += cache.sizeDeltaUSD;
        } else {
            _request.input.isLong ? cache.longOI -= cache.sizeDeltaUSD : cache.shortOI -= cache.sizeDeltaUSD;
        }
        cache.skewAfter = cache.longOI > cache.shortOI ? cache.longOI - cache.shortOI : cache.shortOI - cache.longOI;
        cache.skewFlip = cache.longOI > cache.shortOI != cache.startingSkewLong;
        // Calculate the Price Impact
        if (cache.skewFlip) {
            cache.priceImpactUsd = _calculateSkewFlipImpactUsd(
                cache.skewBefore, cache.skewAfter, impact.exponent, impact.positiveFactor, impact.negativeFactor
            );
        } else {
            cache.priceImpactUsd =
                _calculateImpactUsd(cache.skewBefore, cache.skewAfter, impact.exponent, impact.positiveFactor);
        }
        // Execute the Price Impact
        impactedPrice = _calculateImpactedPrice(
            cache.sizeDeltaUSD,
            cache.priceImpactUsd.abs(),
            _indexBaseUnit,
            _request.input.sizeDelta,
            cache.priceImpactUsd
        );
        // Check Slippage on Negative Impact
        if (cache.priceImpactUsd < 0) {
            checkSlippage(impactedPrice, _signedBlockPrice, _request.input.maxSlippage);
        }
    }

    function checkSlippage(uint256 _impactedPrice, uint256 _signedPrice, uint256 _maxSlippage) public pure {
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

    function _calculateTokenValues(Params memory _params)
        internal
        pure
        returns (uint256 longTokenValue, uint256 shortTokenValue)
    {
        longTokenValue = mulDiv(_params.longTokenBalance, _params.longTokenPrice, _params.longBaseUnit);
        shortTokenValue = mulDiv(_params.shortTokenBalance, _params.shortTokenPrice, _params.shortBaseUnit);
    }

    function _calculateSkewUsd(uint256 _longTokenValue, uint256 _shortTokenValue) internal pure returns (uint256) {
        return
            _longTokenValue > _shortTokenValue ? _longTokenValue - _shortTokenValue : _shortTokenValue - _longTokenValue;
    }

    // @audit - is this calculation correct?
    function _calculateImpactedPrice(
        uint256 _sizeDeltaUsd,
        uint256 _absolutePriceImpactUsd,
        uint256 _tokenUnit,
        uint256 _amountIn,
        int256 _priceImpactUsd
    ) internal pure returns (uint256) {
        uint256 unsignedIndexTokenImpact = mulDiv(_absolutePriceImpactUsd, _tokenUnit, _sizeDeltaUsd);
        int256 indexTokenImpact =
            _priceImpactUsd < 0 ? (-1 * unsignedIndexTokenImpact.toInt256()) : unsignedIndexTokenImpact.toInt256();

        uint256 indexTokensAfterImpact =
            indexTokenImpact >= 0 ? _amountIn + indexTokenImpact.abs() : _amountIn - indexTokenImpact.abs();

        return mulDiv(_sizeDeltaUsd, _tokenUnit, indexTokensAfterImpact);
    }

    function _calculateSizeDeltaUsd(Params memory _params) internal pure returns (uint256 sizeDeltaUsd) {
        // Inline calculation of sizeDeltaUsd
        return _params.isLongToken
            ? mulDiv(_params.amountIn, _params.longTokenPrice, _params.longBaseUnit)
            : mulDiv(_params.amountIn, _params.shortTokenPrice, _params.shortBaseUnit);
    }
}
