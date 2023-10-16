// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {MarketStructs} from "../markets/MarketStructs.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMarketStorage} from "../markets/interfaces/IMarketStorage.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {SD59x18, sd, unwrap, pow} from "@prb/math/SD59x18.sol";
import {UD60x18, ud, unwrap} from "@prb/math/UD60x18.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

// library responsible for handling all price impact calculations
library ImpactCalculator {
    using SafeCast for uint256;
    using SafeCast for int256;

    function calculatePriceImpact(
        address _marketStorage,
        bytes32 _marketKey,
        MarketStructs.PositionRequest memory _positionRequest,
        bool _isIncrease
    ) external view returns (int256) {
        address market = IMarketStorage(_marketStorage).getMarket(_marketKey).market;
        return IMarket(market).getPriceImpact(_positionRequest, _isIncrease);
    }

    // Note Wrong => Needs PRB Math not Scale Factor
    // Review
    function applyPriceImpact(uint256 _signedBlockPrice, int256 _priceImpact, bool _isLong)
        external
        pure
        returns (uint256)
    {
        // Scaling factor; for example, 10^4 to handle four decimal places
        uint256 scaleFactor = 10 ** 4;

        // Convert priceImpact to scaled integer (e.g., 0.1% becomes 10 when scaleFactor is 10^4)
        uint256 scaledImpact =
            (uint256(_priceImpact) >= 0 ? uint256(_priceImpact) : uint256(-_priceImpact)) * scaleFactor / 100;

        // Calculate the price change due to impact, then scale down
        uint256 priceDelta = (_signedBlockPrice * scaledImpact) / scaleFactor;

        // Apply the price impact
        if ((_priceImpact >= 0 && !_isLong) || (_priceImpact < 0 && _isLong)) {
            return _signedBlockPrice + priceDelta;
        } else {
            return _signedBlockPrice - priceDelta; // Ensure non-negative
        }
    }

    // Returns Price impact as a percentage of the position size
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

        return unwrap(priceImpact.mul(sd(100)).div(sd(sizeDeltaUSD.toInt256())));
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
