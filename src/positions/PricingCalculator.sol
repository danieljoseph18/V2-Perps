// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {MarketStructs} from "../markets/MarketStructs.sol";
import {IMarketStorage} from "../markets/interfaces/IMarketStorage.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {ITradeStorage} from "../positions/interfaces/ITradeStorage.sol";
import {ILiquidityVault} from "../markets/interfaces/ILiquidityVault.sol";
import {IWUSDC} from "../token/interfaces/IWUSDC.sol";
import {IPriceOracle} from "../oracle/interfaces/IPriceOracle.sol";
import {MarketHelper} from "../markets/MarketHelper.sol";

/*
    weightedAverageEntryPrice = x(indexSizeUSD * entryPrice) / sigmaIndexSizesUSD
    PNL = (Current price of index tokens - Weighted average entry price) * (Total position size / Current price of index tokens)
 */

library PricingCalculator {
    // if long, entry - position = pnl, if short, position - entry = pnl
    /// PNL = (Current price of index tokens - Weighted average entry price) * (Total position size / Current price of index tokens)
    function calculatePnL(address _market, MarketStructs.Position memory _position) external view returns (int256) {
        uint256 indexPrice = IMarket(_market).getPrice(_position.indexToken);
        int256 deltaPriceUsd = int256(indexPrice) - int256(_position.pnlParams.weightedAvgEntryPrice);
        uint256 scalar = _position.positionSize / indexPrice;

        return _position.isLong ? deltaPriceUsd * int256(scalar) : -deltaPriceUsd * int256(scalar);
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

    /// @dev Positive for profit, negative for loss
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
    /// Note If decreasing a position and realizing PNL, it's crucial to adjust the WAEP
    function getDecreasePositionPnL(uint256 _sizeDelta, uint256 _positionWAEP, uint256 _currentPrice, bool _isLong)
        external
        pure
        returns (int256)
    {
        // only realise a percentage equivalent to the percentage of the position being closed
        int256 valueDelta = int256(_sizeDelta * _positionWAEP) - int256(_sizeDelta * _currentPrice);
        // if long, > 0 is profit, < 0 is loss
        // if short, > 0 is loss, < 0 is profit
        int256 pnl;
        // if profit, add to realised pnl
        if (valueDelta >= 0) {
            _isLong ? pnl += valueDelta : pnl -= valueDelta;
        } else {
            // subtract from realised pnl
            _isLong ? pnl -= valueDelta : pnl += valueDelta;
        }
        return pnl;
    }
}
