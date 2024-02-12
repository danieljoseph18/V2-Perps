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

import {Market} from "../markets/Market.sol";
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

    ////////////////////////////
    // DEPOSIT AND WITHDRAWAL //
    ////////////////////////////

    // @audit - review
    // Wrong -> Config is different for LP and Traders
    function executeForMarket(Params memory _params, uint8 _priceImpactExponent, uint256 _priceImpactFactor)
        external
        pure
        returns (uint256 impactedPrice)
    {
        uint256 longTokenValue;
        uint256 shortTokenValue;
        uint256 initSkewUsd;
        uint256 sizeDeltaUsd = _calculateSizeDeltaUsd(_params);
        uint256 finalSkewUsd;
        int256 priceImpactUsd;

        // Refactor to reduce local variables and direct calculation
        (longTokenValue, shortTokenValue) = _calculateTokenValues(_params);
        initSkewUsd = _calculateSkewUsd(longTokenValue, shortTokenValue);

        // Adjust token value based on operation
        if (_params.isLongToken) {
            _params.isIncrease ? longTokenValue += sizeDeltaUsd : longTokenValue -= sizeDeltaUsd;
        } else {
            _params.isIncrease ? shortTokenValue += sizeDeltaUsd : shortTokenValue -= sizeDeltaUsd;
        }

        finalSkewUsd = _calculateSkewUsd(longTokenValue, shortTokenValue);
        priceImpactUsd = _calculateImpactUsd(initSkewUsd, finalSkewUsd, _priceImpactExponent, _priceImpactFactor);

        uint256 tokenUnit = _params.isLongToken ? _params.longBaseUnit : _params.shortBaseUnit;
        impactedPrice =
            _calculateImpactedPrice(sizeDeltaUsd, priceImpactUsd.abs(), tokenUnit, _params.amountIn, priceImpactUsd);

        // Check slippage with the new impacted price
        checkSlippage(
            impactedPrice, _params.isLongToken ? _params.longTokenPrice : _params.shortTokenPrice, _params.maxSlippage
        );
    }

    function generateMarketParams(
        Withdrawal.Data memory _data,
        Pool.Values memory _values,
        uint256 _longTokenPrice,
        uint256 _shortTokenPrice,
        bool _isLongToken,
        bool _isIncrease
    ) external pure returns (Params memory) {
        return PriceImpact.Params({
            longTokenBalance: _values.longTokenBalance,
            shortTokenBalance: _values.shortTokenBalance,
            longTokenPrice: _longTokenPrice,
            shortTokenPrice: _shortTokenPrice,
            amountIn: _data.params.marketTokenAmountIn,
            maxSlippage: _data.params.maxSlippage,
            isIncrease: _isIncrease,
            isLongToken: _isLongToken,
            longBaseUnit: _values.longBaseUnit,
            shortBaseUnit: _values.shortBaseUnit
        });
    }

    // New helper functions to split logic and reduce local variable count

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

    /////////////
    // TRADING //
    /////////////

    // @audit - review - price impact should be able to be positive too
    function execute(
        Market _market,
        Position.Request memory _request,
        uint256 _signedBlockPrice,
        uint256 _indexBaseUnit
    ) external view returns (uint256 impactedPrice) {
        require(_signedBlockPrice != 0, "signedBlockPrice is 0");
        uint256 priceImpact = calculate(_market, _request, _signedBlockPrice, _indexBaseUnit);
        if (_request.input.isLong) {
            if (_request.input.isIncrease) {
                impactedPrice = _signedBlockPrice + priceImpact;
            } else {
                impactedPrice = _signedBlockPrice - priceImpact;
            }
        } else {
            if (_request.input.isIncrease) {
                impactedPrice = _signedBlockPrice - priceImpact;
            } else {
                impactedPrice = _signedBlockPrice + priceImpact;
            }
        }
        checkSlippage(impactedPrice, _signedBlockPrice, _request.input.maxSlippage);
    }

    // Returns Price impact in USD
    function calculate(
        Market _market,
        Position.Request memory _request,
        uint256 _signedBlockPrice,
        uint256 _indexBaseUnit
    ) public view returns (uint256 priceImpact) {
        require(_signedBlockPrice != 0, "signedBlockPrice is 0");

        uint256 longOI = MarketUtils.getLongOpenInterestUSD(_market, _signedBlockPrice, _indexBaseUnit);
        uint256 shortOI = MarketUtils.getShortOpenInterestUSD(_market, _signedBlockPrice, _indexBaseUnit);
        uint256 sizeDeltaUSD = mulDiv(_request.input.sizeDelta, _signedBlockPrice, _indexBaseUnit);

        uint256 skewBefore = longOI > shortOI ? longOI - shortOI : shortOI - longOI;
        if (_request.input.isIncrease) {
            _request.input.isLong ? longOI += sizeDeltaUSD : shortOI += sizeDeltaUSD;
        } else {
            _request.input.isLong ? longOI -= sizeDeltaUSD : shortOI -= sizeDeltaUSD;
        }
        uint256 skewAfter = longOI > shortOI ? longOI - shortOI : shortOI - longOI;

        priceImpact =
            _calculateImpactUsd(skewBefore, skewAfter, _market.priceImpactExponent(), _market.priceImpactFactor()).abs();

        uint256 maxImpact = mulDiv(_signedBlockPrice, MAX_PRICE_IMPACT, SCALAR);
        if (priceImpact > maxImpact) {
            priceImpact = maxImpact;
        }
    }

    function checkSlippage(uint256 _impactedPrice, uint256 _signedPrice, uint256 _maxSlippage) public pure {
        uint256 impactDelta =
            _signedPrice > _impactedPrice ? _signedPrice - _impactedPrice : _impactedPrice - _signedPrice;
        uint256 slippage = mulDiv(impactDelta, SCALAR, _signedPrice);
        require(slippage <= _maxSlippage, "slippage exceeds max");
    }

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
}
