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

    function applyPriceImpact(uint256 _signedBlockPrice, uint256 _priceImpactUsd, bool _isLong, bool _isIncrease)
        external
        pure
        returns (uint256)
    {
        if (_signedBlockPrice == 0) revert ImpactCalculator_ZeroParameters();
        if (_isLong && _isIncrease || !_isLong && !_isIncrease) {
            return _signedBlockPrice + _priceImpactUsd;
        } else {
            return _signedBlockPrice - _priceImpactUsd;
        }
    }

    // Returns Price impact in USD
    function calculatePriceImpact(
        address _market,
        address _marketStorage,
        address _dataOracle,
        address _priceOracle,
        MarketStructs.PositionRequest memory _positionRequest,
        uint256 _signedBlockPrice
    ) external view returns (uint256) {
        if (_signedBlockPrice == 0 || _market == address(0) || _positionRequest.user == address(0)) {
            revert ImpactCalculator_ZeroParameters();
        }

        IMarket market = IMarket(_market);

        (uint256 longOI, uint256 shortOI, uint256 sizeDeltaUSD) = getOpenInterestAndSizeDelta(
            _marketStorage, _dataOracle, _priceOracle, _market, _positionRequest, _signedBlockPrice
        );

        uint256 skewBefore = longOI > shortOI ? longOI - shortOI : shortOI - longOI;
        if (_positionRequest.isIncrease) {
            _positionRequest.isLong ? longOI += sizeDeltaUSD : shortOI += sizeDeltaUSD;
        } else {
            _positionRequest.isLong ? longOI -= sizeDeltaUSD : shortOI -= sizeDeltaUSD;
        }
        uint256 skewAfter = longOI > shortOI ? longOI - shortOI : shortOI - longOI;

        uint256 priceImpact = calculateExponentiatedImpact(
            skewBefore, skewAfter, market.priceImpactExponent(), market.priceImpactFactor()
        );

        uint256 maxImpact = (_signedBlockPrice * MAX_PRICE_IMPACT) / IMPACT_SCALAR;
        return adjustPriceImpactWithinLimits(priceImpact, maxImpact);
    }

    function getOpenInterestAndSizeDelta(
        address _marketStorage,
        address _dataOracle,
        address _priceOracle,
        address _market,
        MarketStructs.PositionRequest memory _positionRequest,
        uint256 _signedBlockPrice
    ) internal view returns (uint256 longOI, uint256 shortOI, uint256 sizeDeltaUSD) {
        address indexToken = IMarket(_market).indexToken();
        longOI = MarketHelper.getIndexOpenInterestUSD(_marketStorage, _dataOracle, _priceOracle, indexToken, true);
        shortOI = MarketHelper.getIndexOpenInterestUSD(_marketStorage, _dataOracle, _priceOracle, indexToken, false);

        sizeDeltaUSD =
            (_positionRequest.sizeDelta * _signedBlockPrice) / (IDataOracle(_dataOracle).getBaseUnits(indexToken));
    }

    // Helper function to handle exponentiation
    function calculateExponentiatedImpact(uint256 _skewBefore, uint256 _skewAfter, uint256 _exponent, uint256 _factor)
        internal
        pure
        returns (uint256)
    {
        uint256 absBefore = _skewBefore / IMPACT_SCALAR;
        uint256 absAfter = _skewAfter / IMPACT_SCALAR;

        // Exponentiate and then apply factor
        uint256 impactBefore = (absBefore ** _exponent) * _factor;
        uint256 impactAfter = (absAfter ** _exponent) * _factor;

        return impactBefore > impactAfter ? impactBefore - impactAfter : impactAfter - impactBefore;
    }

    function adjustPriceImpactWithinLimits(uint256 _priceImpact, uint256 _maxImpact) internal pure returns (uint256) {
        if (_priceImpact > _maxImpact) {
            return _maxImpact;
        } else {
            return _priceImpact;
        }
    }

    function checkSlippage(uint256 _impactedPrice, uint256 _signedPrice, uint256 _maxSlippage) external pure {
        uint256 impactDelta =
            _signedPrice > _impactedPrice ? _signedPrice - _impactedPrice : _impactedPrice - _signedPrice;
        uint256 slippage = (impactDelta * IMPACT_SCALAR) / _signedPrice;
        if (slippage > _maxSlippage) revert ImpactCalculator_SlippageExceedsMax();
    }
}
