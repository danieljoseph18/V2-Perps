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

import {IMarketStorage} from "../markets/interfaces/IMarketStorage.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {IDataOracle} from "../oracle/interfaces/IDataOracle.sol";
import {MarketHelper} from "../markets/MarketHelper.sol";
import {Types} from "../libraries/Types.sol";

// library responsible for handling all price impact calculations
library PriceImpact {
    uint256 public constant SCALAR = 1e18;
    uint256 public constant MAX_PRICE_IMPACT = 0.33e18; // 33%

    function execute(
        address _market,
        address _marketStorage,
        address _dataOracle,
        address _priceOracle,
        Types.Request memory _request,
        uint256 _signedBlockPrice
    ) external view returns (uint256 impactedPrice) {
        require(_signedBlockPrice != 0, "signedBlockPrice is 0");
        uint256 priceImpact = calculate(_market, _marketStorage, _dataOracle, _priceOracle, _request, _signedBlockPrice);
        if (_request.isLong) {
            if (_request.isIncrease) {
                impactedPrice = _signedBlockPrice + priceImpact;
            } else {
                impactedPrice = _signedBlockPrice - priceImpact;
            }
        } else {
            if (_request.isIncrease) {
                impactedPrice = _signedBlockPrice - priceImpact;
            } else {
                impactedPrice = _signedBlockPrice + priceImpact;
            }
        }
        checkSlippage(impactedPrice, _signedBlockPrice, _request.maxSlippage);
    }

    // Returns Price impact in USD
    function calculate(
        address _market,
        address _marketStorage,
        address _dataOracle,
        address _priceOracle,
        Types.Request memory _request,
        uint256 _signedBlockPrice
    ) public view returns (uint256 priceImpact) {
        require(_signedBlockPrice != 0, "signedBlockPrice is 0");

        IMarket market = IMarket(_market);

        uint256 longOI =
            MarketHelper.getIndexOpenInterestUSD(_marketStorage, _dataOracle, _priceOracle, market.indexToken(), true);
        uint256 shortOI =
            MarketHelper.getIndexOpenInterestUSD(_marketStorage, _dataOracle, _priceOracle, market.indexToken(), false);
        address indexToken = IMarket(_market).indexToken();
        uint256 sizeDeltaUSD =
            (_request.sizeDelta * _signedBlockPrice) / (IDataOracle(_dataOracle).getBaseUnits(indexToken));

        uint256 skewBefore = longOI > shortOI ? longOI - shortOI : shortOI - longOI;
        if (_request.isIncrease) {
            _request.isLong ? longOI += sizeDeltaUSD : shortOI += sizeDeltaUSD;
        } else {
            _request.isLong ? longOI -= sizeDeltaUSD : shortOI -= sizeDeltaUSD;
        }
        uint256 skewAfter = longOI > shortOI ? longOI - shortOI : shortOI - longOI;

        priceImpact = _calculateExponentiatedImpact(
            skewBefore, skewAfter, market.priceImpactExponent(), market.priceImpactFactor()
        );

        uint256 maxImpact = (_signedBlockPrice * MAX_PRICE_IMPACT) / SCALAR;
        if (priceImpact > maxImpact) {
            priceImpact = maxImpact;
        }
    }

    function checkSlippage(uint256 _impactedPrice, uint256 _signedPrice, uint256 _maxSlippage) public pure {
        uint256 impactDelta =
            _signedPrice > _impactedPrice ? _signedPrice - _impactedPrice : _impactedPrice - _signedPrice;
        uint256 slippage = (impactDelta * SCALAR) / _signedPrice;
        require(slippage <= _maxSlippage, "slippage exceeds max");
    }

    // Helper function to handle exponentiation
    function _calculateExponentiatedImpact(uint256 _skewBefore, uint256 _skewAfter, uint256 _exponent, uint256 _factor)
        internal
        pure
        returns (uint256 exponentiatedImpact)
    {
        uint256 absBefore = _skewBefore / SCALAR;
        uint256 absAfter = _skewAfter / SCALAR;

        // Exponentiate and then apply factor
        uint256 impactBefore = (absBefore ** _exponent) * _factor;
        uint256 impactAfter = (absAfter ** _exponent) * _factor;

        exponentiatedImpact = impactBefore > impactAfter ? impactBefore - impactAfter : impactAfter - impactBefore;
    }
}
