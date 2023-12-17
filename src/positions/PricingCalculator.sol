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
import {ITradeStorage} from "../positions/interfaces/ITradeStorage.sol";
import {ILiquidityVault} from "../markets/interfaces/ILiquidityVault.sol";
import {IWUSDC} from "../token/interfaces/IWUSDC.sol";
import {IPriceOracle} from "../oracle/interfaces/IPriceOracle.sol";
import {IDataOracle} from "../oracle/interfaces/IDataOracle.sol";
import {MarketHelper} from "../markets/MarketHelper.sol";

/*
    weightedAverageEntryPrice = x(indexSizeUSD * entryPrice) / sigmaIndexSizesUSD
    PNL = (Current price of index tokens - Weighted average entry price) * (Total position size / Current price of index tokens)
 */

library PricingCalculator {
    uint256 public constant PRICE_PRECISION = 1e18;

    /// @dev returns PNL in USD
    function calculatePnL(address _priceOracle, address _dataOracle, MarketStructs.Position memory _position)
        external
        view
        returns (int256)
    {
        uint256 indexPrice = IPriceOracle(_priceOracle).getPrice(_position.indexToken);
        uint256 baseUnits = IDataOracle(_dataOracle).getBaseUnits(_position.indexToken);
        uint256 entryValue = (_position.positionSize * _position.pnlParams.weightedAvgEntryPrice) / baseUnits;
        uint256 currentValue = (_position.positionSize * indexPrice) / baseUnits;
        return _position.isLong ? int256(currentValue) - int256(entryValue) : int256(entryValue) - int256(currentValue);
    }

    /// weightedAverageEntryPrice = x(indexSizeUSD * entryPrice) / sigmaIndexSizesUSD
    /// @dev Calculates the Next WAEP after a delta in a position
    function calculateWeightedAverageEntryPrice(
        uint256 _prevWAEP,
        uint256 _prevSISU,
        int256 _sizeDeltaUsd,
        uint256 _price
    ) external pure returns (uint256) {
        if (_prevWAEP == 0 && _prevSISU == 0) {
            return uint256(_price);
        } else {
            return _sizeDeltaUsd > 0
                ? (_prevWAEP * _prevSISU + uint256(_sizeDeltaUsd) * uint256(_price)) / (_prevSISU + uint256(_sizeDeltaUsd))
                : (_prevWAEP * _prevSISU - uint256(-_sizeDeltaUsd) * uint256(_price))
                    / (_prevSISU - uint256(-_sizeDeltaUsd));
        }
    }

    /// @dev Positive for profit, negative for loss. Returns PNL in USD
    function getNetPnL(address _market, address _marketStorage, address _dataOracle, address _priceOracle, bool _isLong)
        external
        view
        returns (int256)
    {
        address indexToken = IMarket(_market).indexToken();
        // Get OI in USD
        uint256 indexValue =
            MarketHelper.getIndexOpenInterestUSD(_marketStorage, _dataOracle, _priceOracle, indexToken, _isLong);
        uint256 entryValue = MarketHelper.getTotalEntryValue(_market, _marketStorage, _dataOracle, _isLong);

        return _isLong ? int256(indexValue) - int256(entryValue) : int256(entryValue) - int256(indexValue);
    }

    /// RealisedPNL=(Current price − Weighted average entry price)×(Realised position size/Current price)
    /// int256 pnl = int256(amountToRealise * currentTokenPrice) - int256(amountToRealise * userPos.entryPriceWeighted);
    /// @dev Returns fractional PNL in USD
    function getDecreasePositionPnL(
        address _dataOracle,
        address _indexToken,
        uint256 _sizeDelta,
        uint256 _positionWAEP,
        uint256 _currentPrice,
        bool _isLong
    ) external view returns (int256) {
        // only realise a percentage equivalent to the percentage of the position being closed
        uint256 baseUnit = IDataOracle(_dataOracle).getBaseUnits(_indexToken);
        uint256 entryValue = (_sizeDelta * _positionWAEP) / baseUnit;
        uint256 exitValue = (_sizeDelta * _currentPrice) / baseUnit;
        // if long, > 0 is profit, < 0 is loss
        // if short, > 0 is loss, < 0 is profit
        if (_isLong) {
            return int256(exitValue) - int256(entryValue);
        } else {
            return int256(entryValue) - int256(exitValue);
        }
    }
}
