// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {MarketStructs} from "../markets/MarketStructs.sol";
import {IMarketStorage} from "../markets/interfaces/IMarketStorage.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {MarketHelper} from "../markets/MarketHelper.sol";

// library responsible for handling all price impact calculations
library ImpactCalculator {
    error ImpactCalculator_ZeroParameters();
    error ImpactCalculator_SlippageExceedsMax();

    function applyPriceImpact(uint256 _signedBlockPrice, int256 _priceImpact) external pure returns (uint256) {
        if (_signedBlockPrice == 0 || _priceImpact == 0) revert ImpactCalculator_ZeroParameters();
        // multiply price impact by signed block price => e.g 0.05e18 * 1000e18 = 50e18 (5%)
        int256 impactUSD = _priceImpact * int256(_signedBlockPrice);
        // negative, subtract, positive add
        uint256 impactedPrice = uint256(int256(_signedBlockPrice) + impactUSD);
        // return new price
        return impactedPrice;
    }

    // Returns Price impact as a decimal
    function calculatePriceImpact(
        address _market,
        address _marketStorage,
        address _dataOracle,
        address _priceOracle,
        MarketStructs.PositionRequest memory _positionRequest,
        uint256 _signedBlockPrice
    ) external view returns (int256) {
        if (_signedBlockPrice == 0 || _market == address(0) || _positionRequest.user == address(0)) {
            revert ImpactCalculator_ZeroParameters();
        }

        IMarket market = IMarket(_market);
        address indexToken = market.indexToken();
        uint256 longOI =
            MarketHelper.getIndexOpenInterestUSD(_marketStorage, _dataOracle, _priceOracle, indexToken, true);
        uint256 shortOI =
            MarketHelper.getIndexOpenInterestUSD(_marketStorage, _dataOracle, _priceOracle, indexToken, false);

        uint256 skewBefore = longOI > shortOI ? longOI - shortOI : shortOI - longOI;

        uint256 sizeDeltaUSD = _positionRequest.sizeDelta * _signedBlockPrice;

        if (_positionRequest.isIncrease) {
            _positionRequest.isLong ? longOI += sizeDeltaUSD : shortOI += sizeDeltaUSD;
        } else {
            _positionRequest.isLong ? longOI -= sizeDeltaUSD : shortOI -= sizeDeltaUSD;
        }

        uint256 skewAfter = longOI > shortOI ? longOI - shortOI : shortOI - longOI;

        uint256 exponent = market.priceImpactExponent();
        uint256 factor = market.priceImpactFactor();

        int256 priceImpact = int256((skewBefore ** exponent) * factor) - int256((skewAfter ** exponent) * factor);

        if (priceImpact > market.MAX_PRICE_IMPACT()) priceImpact = market.MAX_PRICE_IMPACT();

        return priceImpact / int256(sizeDeltaUSD);
    }

    function checkSlippage(uint256 _impactedPrice, uint256 _signedPrice, uint256 _maxSlippage) external pure {
        uint256 slippage = 1e18 - ((_impactedPrice * 1e18) / _signedPrice);
        if (slippage > _maxSlippage) revert ImpactCalculator_SlippageExceedsMax();
    }
}
