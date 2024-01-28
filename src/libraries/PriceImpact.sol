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

import {IMarketMaker} from "../markets/interfaces/IMarketMaker.sol";
import {IDataOracle} from "../oracle/interfaces/IDataOracle.sol";
import {MarketHelper} from "../markets/MarketHelper.sol";
import {Market} from "../structs/Market.sol";
import {PositionRequest} from "../structs/PositionRequest.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {ud, UD60x18, unwrap} from "@prb/math/UD60x18.sol";

// library responsible for handling all price impact calculations
library PriceImpact {
    using SignedMath for int256;

    uint256 public constant SCALAR = 1e18;
    uint256 public constant MAX_PRICE_IMPACT = 0.33e18; // 33%

    struct Params {
        uint256 longTokenBalance;
        uint256 shortTokenBalance;
        uint256 longTokenPrice;
        uint256 shortTokenPrice;
        uint256 amount;
        bool isIncrease;
        bool isLongToken;
        uint256 longTokenDecimals;
        uint256 shortTokenDecimals;
        address marketMaker;
        bytes32 marketKey;
    }

    struct TokenData {
        uint256 balance;
        uint256 price;
        uint256 unit;
        uint256 value;
    }

    // @audit - review
    function executeForMarket(Params memory _params) external view returns (uint256 impactedPrice) {
        // Refactor local variables by grouping related data
        // Initialize TokenData struct with all required fields
        TokenData memory longTokenData = TokenData(
            _params.longTokenBalance,
            _params.longTokenPrice,
            10 ** _params.longTokenDecimals,
            0 // Initialize the 'value' field to 0
        );
        TokenData memory shortTokenData = TokenData(
            _params.shortTokenBalance,
            _params.shortTokenPrice,
            10 ** _params.shortTokenDecimals,
            0 // Initialize the 'value' field to 0
        );

        // Inline calculation of token values
        longTokenData.value = Math.mulDiv(longTokenData.balance, longTokenData.price, longTokenData.unit);
        shortTokenData.value = Math.mulDiv(shortTokenData.balance, shortTokenData.price, shortTokenData.unit);

        // Inline calculation of initial skew
        uint256 initSkewUsd =
            Math.max(longTokenData.value, shortTokenData.value) - Math.min(longTokenData.value, shortTokenData.value);

        Market.Config memory marketConfig = IMarketMaker(_params.marketMaker).markets(_params.marketKey).config;
        uint256 sizeDeltaUsd = _calculateSizeDeltaUsd(_params, longTokenData, shortTokenData);

        // Refactor value update to a separate internal function
        _updateTokenValues(_params, sizeDeltaUsd, longTokenData, shortTokenData);

        uint256 finalSkewUsd =
            Math.max(longTokenData.value, shortTokenData.value) - Math.min(longTokenData.value, shortTokenData.value);
        int256 priceImpactUsd = _calculateImpactUsd(
            initSkewUsd, finalSkewUsd, marketConfig.priceImpactExponent, marketConfig.priceImpactFactor
        );

        uint256 tokenUnit = _params.isLongToken ? longTokenData.unit : shortTokenData.unit;
        uint256 unsignedIndexTokenImpact = Math.mulDiv(uint256(priceImpactUsd.abs()), tokenUnit, sizeDeltaUsd);
        int256 indexTokenImpact =
            priceImpactUsd < 0 ? -int256(unsignedIndexTokenImpact) : int256(unsignedIndexTokenImpact);

        uint256 indexTokensAfterImpact = indexTokenImpact >= 0
            ? _params.amount + uint256(indexTokenImpact)
            : _params.amount - uint256(-indexTokenImpact);

        impactedPrice = Math.mulDiv(sizeDeltaUsd, tokenUnit, indexTokensAfterImpact);
    }

    function _calculateSizeDeltaUsd(
        Params memory _params,
        TokenData memory longTokenData,
        TokenData memory shortTokenData
    ) internal pure returns (uint256 sizeDeltaUsd) {
        // Inline calculation of sizeDeltaUsd
        return _params.isLongToken
            ? Math.mulDiv(_params.amount, longTokenData.price, longTokenData.unit)
            : Math.mulDiv(_params.amount, shortTokenData.price, shortTokenData.unit);
    }

    function _updateTokenValues(
        Params memory _params,
        uint256 sizeDeltaUsd,
        TokenData memory longTokenData,
        TokenData memory shortTokenData
    ) internal pure {
        if (_params.isLongToken) {
            longTokenData.value =
                _params.isIncrease ? longTokenData.value + sizeDeltaUsd : longTokenData.value - sizeDeltaUsd;
        } else {
            shortTokenData.value =
                _params.isIncrease ? shortTokenData.value + sizeDeltaUsd : shortTokenData.value - sizeDeltaUsd;
        }
    }

    function execute(
        bytes32 _marketKey,
        address _marketMaker,
        address _dataOracle,
        address _priceOracle,
        PositionRequest.Data memory _request,
        uint256 _signedBlockPrice
    ) external view returns (uint256 impactedPrice) {
        // require(_signedBlockPrice != 0, "signedBlockPrice is 0");
        // uint256 priceImpact =
        //     calculate(_marketKey, _marketMaker, _dataOracle, _priceOracle, _request, _signedBlockPrice);
        // if (_request.isLong) {
        //     if (_request.isIncrease) {
        //         impactedPrice = _signedBlockPrice + priceImpact;
        //     } else {
        //         impactedPrice = _signedBlockPrice - priceImpact;
        //     }
        // } else {
        //     if (_request.isIncrease) {
        //         impactedPrice = _signedBlockPrice - priceImpact;
        //     } else {
        //         impactedPrice = _signedBlockPrice + priceImpact;
        //     }
        // }
        // checkSlippage(impactedPrice, _signedBlockPrice, _request.maxSlippage);
    }

    // Returns Price impact in USD
    function calculate(
        bytes32 _marketKey,
        address _marketMaker,
        address _dataOracle,
        address _priceOracle,
        PositionRequest.Data memory _request,
        uint256 _signedBlockPrice
    ) public view returns (uint256 priceImpact) {
        // require(_signedBlockPrice != 0, "signedBlockPrice is 0");
        // Market.Config memory marketConfig = IMarketMaker(_marketMaker).markets(_marketKey).config;

        // uint256 longOI =
        //     MarketHelper.getIndexOpenInterestUSD(_marketMaker, _dataOracle, _priceOracle, _request.indexToken, true);
        // uint256 shortOI =
        //     MarketHelper.getIndexOpenInterestUSD(_marketMaker, _dataOracle, _priceOracle, _request.indexToken, false);
        // uint256 sizeDeltaUSD =
        //     (_request.sizeDelta * _signedBlockPrice) / (IDataOracle(_dataOracle).getBaseUnits(_request.indexToken));

        // uint256 skewBefore = longOI > shortOI ? longOI - shortOI : shortOI - longOI;
        // if (_request.isIncrease) {
        //     _request.isLong ? longOI += sizeDeltaUSD : shortOI += sizeDeltaUSD;
        // } else {
        //     _request.isLong ? longOI -= sizeDeltaUSD : shortOI -= sizeDeltaUSD;
        // }
        // uint256 skewAfter = longOI > shortOI ? longOI - shortOI : shortOI - longOI;

        // priceImpact = _calculateImpactUsd(
        //     skewBefore, skewAfter, marketConfig.priceImpactExponent, marketConfig.priceImpactFactor
        // );

        // uint256 maxImpact = (_signedBlockPrice * MAX_PRICE_IMPACT) / SCALAR;
        // if (priceImpact > maxImpact) {
        //     priceImpact = maxImpact;
        // }
    }

    function checkSlippage(uint256 _impactedPrice, uint256 _signedPrice, uint256 _maxSlippage) public pure {
        uint256 impactDelta =
            _signedPrice > _impactedPrice ? _signedPrice - _impactedPrice : _impactedPrice - _signedPrice;
        uint256 slippage = (impactDelta * SCALAR) / _signedPrice;
        require(slippage <= _maxSlippage, "slippage exceeds max");
    }

    function _calculateImpactUsd(uint256 _skewBefore, uint256 _skewAfter, uint256 _exponent, uint256 _factor)
        internal
        pure
        returns (int256 impactUsd)
    {
        // Perform exponentiation using UD60x18 library
        uint256 impactBefore = unwrap(ud(_skewBefore).pow(ud(_exponent)));
        uint256 impactAfter = unwrap(ud(_skewAfter).pow(ud(_exponent)));

        // Apply factor
        impactBefore = impactBefore * _factor;
        impactAfter = impactAfter * _factor;

        // Calculate impact in USD
        impactUsd = int256(impactBefore) - int256(impactAfter);
    }
}
