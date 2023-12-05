// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {MarketStructs} from "../markets/MarketStructs.sol";
import {IMarketStorage} from "../markets/interfaces/IMarketStorage.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {IDataOracle} from "../oracle/interfaces/IDataOracle.sol";
import {MarketHelper} from "../markets/MarketHelper.sol";

// library responsible for handling all price impact calculations
library ImpactCalculator {
    error ImpactCalculator_ZeroParameters();
    error ImpactCalculator_SlippageExceedsMax();

    uint256 public constant IMPACT_SCALAR = 1e18;
    uint256 public constant MAX_PRICE_IMPACT = 0.33e18; // 33%

    function applyPriceImpact(uint256 _signedBlockPrice, int256 _priceImpactUsd) external pure returns (uint256) {
        if (_signedBlockPrice == 0) revert ImpactCalculator_ZeroParameters();
        return _priceImpactUsd >= 0
            ? _signedBlockPrice + uint256(_priceImpactUsd)
            : _signedBlockPrice - uint256(-_priceImpactUsd);
    }

    // Returns Price impact in USD
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

        uint256 skewBefore = longOI > shortOI ? (longOI - shortOI) / IMPACT_SCALAR : (shortOI - longOI) / IMPACT_SCALAR;

        uint256 sizeDeltaUSD = (
            (_positionRequest.sizeDelta * _signedBlockPrice) / (10 ** IDataOracle(_dataOracle).getDecimals(indexToken))
                / IMPACT_SCALAR
        );

        if (_positionRequest.isIncrease) {
            _positionRequest.isLong ? longOI += sizeDeltaUSD : shortOI += sizeDeltaUSD;
        } else {
            _positionRequest.isLong ? longOI -= sizeDeltaUSD : shortOI -= sizeDeltaUSD;
        }

        uint256 skewAfter = longOI > shortOI ? (longOI - shortOI) / IMPACT_SCALAR : (shortOI - longOI) / IMPACT_SCALAR;

        uint256 exponent = market.priceImpactExponent();
        uint256 factor = market.priceImpactFactor();

        int256 priceImpact =
            int256((skewBefore ** exponent) * factor) - int256((skewAfter ** exponent) * factor) * int256(IMPACT_SCALAR);

        uint256 maxImpact = (_signedBlockPrice * MAX_PRICE_IMPACT) / IMPACT_SCALAR;

        if (priceImpact > int256(maxImpact)) {
            priceImpact = int256(maxImpact);
        } else if (priceImpact < -int256(maxImpact)) {
            priceImpact = -int256(maxImpact);
        }

        return priceImpact;
    }

    function checkSlippage(uint256 _impactedPrice, uint256 _signedPrice, uint256 _maxSlippage) external pure {
        uint256 slippage = 1e18 - ((_impactedPrice * 1e18) / _signedPrice);
        if (slippage > _maxSlippage) revert ImpactCalculator_SlippageExceedsMax();
    }
}
