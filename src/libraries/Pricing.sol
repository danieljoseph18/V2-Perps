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

import {ITradeStorage} from "../positions/interfaces/ITradeStorage.sol";
import {ILiquidityVault} from "../markets/interfaces/ILiquidityVault.sol";
import {IPriceOracle} from "../oracle/interfaces/IPriceOracle.sol";
import {IDataOracle} from "../oracle/interfaces/IDataOracle.sol";
import {MarketHelper} from "../markets/MarketHelper.sol";
import {Market} from "../structs/Market.sol";
import {Position} from "../structs/Position.sol";

/*
    weightedAverageEntryPrice = x(indexSizeUSD * entryPrice) / sigmaIndexSizesUSD
    PNL = (Current price of index tokens - Weighted average entry price) * (Total position size / Current price of index tokens)
 */
/// @dev Library for pricing related functions
library Pricing {
    uint256 public constant PRICE_PRECISION = 1e18;

    /// @dev returns PNL in USD
    function calculatePnL(uint256 _indexPriceUsd, address _dataOracle, Position.Data memory _position)
        external
        view
        returns (int256)
    {
        uint256 baseUnits = IDataOracle(_dataOracle).getBaseUnits(_position.indexToken);
        uint256 entryValue = (_position.positionSize * _position.pnl.weightedAvgEntryPrice) / baseUnits;
        uint256 currentValue = (_position.positionSize * _indexPriceUsd) / baseUnits;
        return _position.isLong ? int256(currentValue) - int256(entryValue) : int256(entryValue) - int256(currentValue);
    }

    /// weightedAverageEntryPrice = Σ(indexSizeUSD * entryPrice) / Σ(IndexSizesUSD)
    /// @dev Calculates the Next WAEP after a delta in a position
    function calculateWeightedAverageEntryPrice(
        uint256 _prevWAEP, // PREV WEIGHTED AVG ENTRY PRICE
        uint256 _prevSISU, // Σ INDEX SIZE USD
        int256 _sizeDeltaUsd, // Δ SIZE
        uint256 _price
    ) external pure returns (uint256 weightedAvgEntryPrice) {
        if (_prevWAEP == 0 && _prevSISU == 0) {
            weightedAvgEntryPrice = uint256(_price);
        } else {
            if (_sizeDeltaUsd > 0) {
                weightedAvgEntryPrice = (_prevWAEP * _prevSISU + uint256(_sizeDeltaUsd) * uint256(_price))
                    / (_prevSISU + uint256(_sizeDeltaUsd));
            } else {
                weightedAvgEntryPrice = (_prevWAEP * _prevSISU - uint256(-_sizeDeltaUsd) * uint256(_price))
                    / (_prevSISU - uint256(-_sizeDeltaUsd));
            }
        }
    }

    /// @dev Positive for profit, negative for loss. Returns PNL in USD
    function getNetPnL(
        address _indexToken,
        address _marketMaker,
        address _dataOracle,
        address _priceOracle,
        bool _isLong
    ) external view returns (int256 netPnl) {
        // Get OI in USD
        uint256 indexValue =
            MarketHelper.getIndexOpenInterestUSD(_marketMaker, _dataOracle, _priceOracle, _indexToken, _isLong);
        uint256 entryValue = MarketHelper.getTotalEntryValueUsd(_indexToken, _marketMaker, _dataOracle, _isLong);

        netPnl = _isLong ? int256(indexValue) - int256(entryValue) : int256(entryValue) - int256(indexValue);
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
    ) external view returns (int256 decreasePositionPnl) {
        // only realise a percentage equivalent to the percentage of the position being closed
        uint256 baseUnit = IDataOracle(_dataOracle).getBaseUnits(_indexToken);
        uint256 entryValue = (_sizeDelta * _positionWAEP) / baseUnit;
        uint256 exitValue = (_sizeDelta * _currentPrice) / baseUnit;
        // if long, > 0 is profit, < 0 is loss
        // if short, > 0 is loss, < 0 is profit
        if (_isLong) {
            decreasePositionPnl = int256(exitValue) - int256(entryValue);
        } else {
            decreasePositionPnl = int256(entryValue) - int256(exitValue);
        }
    }
}
