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

    // Returns Price impact Percentage
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

        uint256 sizeDeltaUSD = (
            (_positionRequest.sizeDelta * _signedBlockPrice) / (10 ** IDataOracle(_dataOracle).getDecimals(indexToken))
        );

        if (_positionRequest.isIncrease) {
            _positionRequest.isLong ? longOI += sizeDeltaUSD : shortOI += sizeDeltaUSD;
        } else {
            _positionRequest.isLong ? longOI -= sizeDeltaUSD : shortOI -= sizeDeltaUSD;
        }

        int256 skewBefore = int256(longOI) - int256(shortOI);
        int256 skewAfter =
            _positionRequest.isLong ? skewBefore + int256(sizeDeltaUSD) : skewBefore - int256(sizeDeltaUSD);

        uint256 exponent = market.priceImpactExponent();
        uint256 factor = market.priceImpactFactor();

        // Adjusting exponentiation to maintain precision and prevent overflow
        int256 priceImpact = calculateExponentiatedImpact(skewBefore, skewAfter, exponent, factor);

        uint256 maxImpact = (_signedBlockPrice * MAX_PRICE_IMPACT) / IMPACT_SCALAR;

        if (priceImpact > int256(maxImpact)) {
            priceImpact = int256(maxImpact);
        } else if (priceImpact < -int256(maxImpact)) {
            priceImpact = -int256(maxImpact);
        }

        return priceImpact;
    }

    // Helper function to handle exponentiation
    function calculateExponentiatedImpact(int256 _before, int256 _after, uint256 _exponent, uint256 _factor)
        internal
        pure
        returns (int256)
    {
        // Convert to positive numbers for exponentiation
        uint256 absBefore = uint256(_before < 0 ? -_before : _before);
        uint256 absAfter = uint256(_after < 0 ? -_after : _after);

        // Exponentiate and then apply factor
        uint256 impactBefore = (absBefore ** _exponent) * _factor / IMPACT_SCALAR;
        uint256 impactAfter = (absAfter ** _exponent) * _factor / IMPACT_SCALAR;

        return int256(impactBefore) - int256(impactAfter);
    }

    function checkSlippage(uint256 _impactedPrice, uint256 _signedPrice, uint256 _maxSlippage) external pure {
        uint256 slippage = 1e18 - ((_impactedPrice * 1e18) / _signedPrice);
        if (slippage > _maxSlippage) revert ImpactCalculator_SlippageExceedsMax();
    }
}
