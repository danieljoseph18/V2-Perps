// SPDX-License-Identifier: BUSL-1.1
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

    error ImpactCalculator_ZeroParameters();

    function applyPriceImpact(uint256 _signedBlockPrice, int256 _priceImpact) external pure returns (uint256) {
        if (_signedBlockPrice == 0 || _priceImpact == 0) revert ImpactCalculator_ZeroParameters();
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
        if (_signedBlockPrice == 0 || _market == address(0) || _positionRequest.user == address(0)) {
            revert ImpactCalculator_ZeroParameters();
        }
        IMarket market = IMarket(_market);
        uint256 longOI = market.getIndexOpenInterestUSD(true);
        uint256 shortOI = market.getIndexOpenInterestUSD(false);

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

        SD59x18 exponent = sd(market.priceImpactExponent().toInt256());
        SD59x18 factor = sd(market.priceImpactFactor().toInt256());

        SD59x18 priceImpact = (skewBefore.pow(exponent)).mul(factor) - (skewAfter.pow(exponent)).mul(factor);

        if (unwrap(priceImpact) > market.MAX_PRICE_IMPACT()) priceImpact = sd(market.MAX_PRICE_IMPACT());

        return unwrap(priceImpact.div(sd(sizeDeltaUSD.toInt256())));
    }
}
