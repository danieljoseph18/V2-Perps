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
import {ILiquidityVault} from "../liquidity/interfaces/ILiquidityVault.sol";
import {IMarketMaker} from "../markets/interfaces/IMarketMaker.sol";
import {IPriceOracle} from "../oracle/interfaces/IPriceOracle.sol";
import {IDataOracle} from "../oracle/interfaces/IDataOracle.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {MarketUtils} from "../markets/MarketUtils.sol";
import {Position} from "../positions/Position.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/*
    weightedAverageEntryPrice = x(indexSizeUSD * entryPrice) / sigmaIndexSizesUSD
    PNL = (Current price of index tokens - Weighted average entry price) * (Total position size / Current price of index tokens)
 */
/// @dev Library for pricing related functions
library Pricing {
    uint256 public constant PRICE_PRECISION = 1e18;

    /// @dev returns PNL in USD
    function calculatePnL(Position.Data memory _position, uint256 _indexPriceUsd, uint256 _indexBaseUnit)
        external
        pure
        returns (int256)
    {
        uint256 entryValue = (_position.positionSize * _position.pnlParams.weightedAvgEntryPrice) / _indexBaseUnit;
        uint256 currentValue = (_position.positionSize * _indexPriceUsd) / _indexBaseUnit;
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
    function getNetPnL(IMarket _market, uint256 _indexPrice, uint256 _indexBaseUnit, bool _isLong)
        external
        view
        returns (int256 netPnl)
    {
        // Get OI in USD
        if (_isLong) {
            // get index value
            uint256 indexValue = MarketUtils.getLongOpenInterestUSD(_market, _indexPrice, _indexBaseUnit);
            // get entry value
            uint256 entryValue = MarketUtils.getTotalEntryValueUSD(_market, _indexBaseUnit, _isLong);
            // return index value - entry value
            netPnl = int256(indexValue) - int256(entryValue);
        } else {
            // get entry value
            uint256 entryValue = MarketUtils.getTotalEntryValueUSD(_market, _indexBaseUnit, _isLong);
            // get index value
            uint256 indexValue = MarketUtils.getShortOpenInterestUSD(_market, _indexPrice, _indexBaseUnit);
            // return entry value - index value
            netPnl = int256(entryValue) - int256(indexValue);
        }
    }

    /// RealisedPNL=(Current price − Weighted average entry price)×(Realised position size/Current price)
    /// int256 pnl = int256(amountToRealise * currentTokenPrice) - int256(amountToRealise * userPos.entryPriceWeighted);
    /// @dev Returns fractional PNL in USD
    function getDecreasePositionPnL(
        uint256 _indexBaseUnit,
        uint256 _sizeDelta,
        uint256 _positionWAEP,
        uint256 _currentPrice,
        bool _isLong
    ) external pure returns (int256 decreasePositionPnl) {
        // only realise a percentage equivalent to the percentage of the position being closed
        uint256 entryValue = Math.mulDiv(_sizeDelta, _positionWAEP, _indexBaseUnit);
        uint256 exitValue = Math.mulDiv(_sizeDelta, _currentPrice, _indexBaseUnit);
        // if long, > 0 is profit, < 0 is loss
        // if short, > 0 is loss, < 0 is profit
        if (_isLong) {
            decreasePositionPnl = int256(exitValue) - int256(entryValue);
        } else {
            decreasePositionPnl = int256(entryValue) - int256(exitValue);
        }
    }
}
