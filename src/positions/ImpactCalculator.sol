// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {MarketStructs} from "../markets/MarketStructs.sol";
import {IMarketStorage} from "../markets/interfaces/IMarketStorage.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {SD59x18, sd, unwrap, pow} from "@prb/math/SD59x18.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

// library responsible for handling all price impact calculations
library ImpactCalculator {
    using SafeCast for uint256;
    using SafeCast for int256;

    function applyPriceImpact(uint256 _signedBlockPrice, int256 _priceImpact) external pure returns (uint256) {
        // multiply price impact by signed block price => e.g 0.05e18 * 1000e18 = 50e18 (5%)
        int256 impactUSD = _priceImpact * _signedBlockPrice.toInt256();
        // negative, subtract, positive add
        uint256 impactedPrice = (_signedBlockPrice.toInt256() + impactUSD).toUint256();
        // return new price
        return impactedPrice;
    }

    // Returns Price impact as a decimal
    function calculatePriceImpact(
        address _market,
        MarketStructs.PositionRequest memory _positionRequest,
        uint256 _signedBlockPrice
    ) external view returns (int256) {
        uint256 longOI = IMarket(_market).getIndexOpenInterestUSD(true);
        uint256 shortOI = IMarket(_market).getIndexOpenInterestUSD(false);

        SD59x18 skewBefore =
            longOI > shortOI ? sd(longOI.toInt256() - shortOI.toInt256()) : sd(shortOI.toInt256() - longOI.toInt256());

        uint256 sizeDeltaUSD = _positionRequest.sizeDelta * _signedBlockPrice;

        if (_positionRequest.isIncrease) {
            _positionRequest.isLong ? longOI += sizeDeltaUSD : shortOI += sizeDeltaUSD;
        } else {
            _positionRequest.isLong ? longOI -= sizeDeltaUSD : shortOI -= sizeDeltaUSD;
        }

        SD59x18 skewAfter =
            longOI > shortOI ? sd(longOI.toInt256() - shortOI.toInt256()) : sd(shortOI.toInt256() - longOI.toInt256());

        SD59x18 exponent = sd(_getPriceImpactExponent(_market).toInt256());
        SD59x18 factor = sd(_getPriceImpactFactor(_market).toInt256());

        SD59x18 priceImpact = (skewBefore.pow(exponent)).mul(factor) - (skewAfter.pow(exponent)).mul(factor);

        if (unwrap(priceImpact) > _getMaxPriceImpact(_market)) priceImpact = sd(_getMaxPriceImpact(_market));

        return unwrap(priceImpact.div(sd(sizeDeltaUSD.toInt256())));
    }

    function _getPriceImpactFactor(address _market) internal view returns (uint256) {
        return IMarket(_market).priceImpactFactor();
    }

    function _getPriceImpactExponent(address _market) internal view returns (uint256) {
        return IMarket(_market).priceImpactExponent();
    }

    function _getMaxPriceImpact(address _market) internal view returns (int256) {
        return IMarket(_market).MAX_PRICE_IMPACT();
    }
}
