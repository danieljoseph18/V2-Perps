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
pragma solidity 0.8.21;

import {MarketStructs} from "../markets/MarketStructs.sol";
import {IMarketStorage} from "../markets/interfaces/IMarketStorage.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {IDataOracle} from "../oracle/interfaces/IDataOracle.sol";
import {MarketHelper} from "../markets/MarketHelper.sol";

// library responsible for handling all price impact calculations
library ImpactCalculator {
    error ImpactCalculator_ZeroParameters();
    error ImpactCalculator_SlippageExceedsMax();

    uint256 public constant SCALAR = 1e18;
    uint256 public constant MAX_PRICE_IMPACT = 0.33e18; // 33%

    function executePriceImpact(
        address _market,
        address _marketStorage,
        address _dataOracle,
        address _priceOracle,
        MarketStructs.PositionRequest memory _positionRequest,
        uint256 _signedBlockPrice
    ) external view returns (uint256) {
        uint256 priceImpact = calculatePriceImpact(
            _market, _marketStorage, _dataOracle, _priceOracle, _positionRequest, _signedBlockPrice
        );
        uint256 impactedPrice =
            applyPriceImpact(_signedBlockPrice, priceImpact, _positionRequest.isLong, _positionRequest.isIncrease);
        checkSlippage(impactedPrice, _signedBlockPrice, _positionRequest.maxSlippage);
        return impactedPrice;
    }

    function applyPriceImpact(uint256 _signedBlockPrice, uint256 _priceImpactUsd, bool _isLong, bool _isIncrease)
        public
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
    ) public view returns (uint256) {
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

        uint256 priceImpact = _calculateExponentiatedImpact(
            skewBefore, skewAfter, market.priceImpactExponent(), market.priceImpactFactor()
        );

        uint256 maxImpact = (_signedBlockPrice * MAX_PRICE_IMPACT) / SCALAR;
        return _adjustPriceImpactWithinLimits(priceImpact, maxImpact);
    }

    function checkSlippage(uint256 _impactedPrice, uint256 _signedPrice, uint256 _maxSlippage) public pure {
        uint256 impactDelta =
            _signedPrice > _impactedPrice ? _signedPrice - _impactedPrice : _impactedPrice - _signedPrice;
        uint256 slippage = (impactDelta * SCALAR) / _signedPrice;
        if (slippage > _maxSlippage) revert ImpactCalculator_SlippageExceedsMax();
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
    function _calculateExponentiatedImpact(uint256 _skewBefore, uint256 _skewAfter, uint256 _exponent, uint256 _factor)
        internal
        pure
        returns (uint256)
    {
        uint256 absBefore = _skewBefore / SCALAR;
        uint256 absAfter = _skewAfter / SCALAR;

        // Exponentiate and then apply factor
        uint256 impactBefore = (absBefore ** _exponent) * _factor;
        uint256 impactAfter = (absAfter ** _exponent) * _factor;

        return impactBefore > impactAfter ? impactBefore - impactAfter : impactAfter - impactBefore;
    }

    function _adjustPriceImpactWithinLimits(uint256 _priceImpact, uint256 _maxImpact) internal pure returns (uint256) {
        if (_priceImpact > _maxImpact) {
            return _maxImpact;
        } else {
            return _priceImpact;
        }
    }
}
