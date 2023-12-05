// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {MarketStructs} from "../markets/MarketStructs.sol";
import {IMarketStorage} from "../markets/interfaces/IMarketStorage.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {ITradeStorage} from "../positions/interfaces/ITradeStorage.sol";
import {ILiquidityVault} from "../markets/interfaces/ILiquidityVault.sol";
import {IWUSDC} from "../token/interfaces/IWUSDC.sol";
import {IPriceOracle} from "../oracle/interfaces/IPriceOracle.sol";
import {IDataOracle} from "../oracle/interfaces/IDataOracle.sol";
import {MarketHelper} from "../markets/MarketHelper.sol";
import {UD60x18, ud, unwrap} from "prb-math/UD60x18.sol";
import {SD59x18, sd, unwrap} from "prb-math/SD59x18.sol";

/*
    weightedAverageEntryPrice = x(indexSizeUSD * entryPrice) / sigmaIndexSizesUSD
    PNL = (Current price of index tokens - Weighted average entry price) * (Total position size / Current price of index tokens)
 */

library PricingCalculator {
    uint256 public constant PRICE_PRECISION = 1e18;
    // if long, entry - position = pnl, if short, position - entry = pnl
    /// PNL = (Current price of index tokens - Weighted average entry price) * (Total position size / Current price of index tokens)

    function calculatePnL(address _market, MarketStructs.Position memory _position) external view returns (int256) {
        uint256 indexPrice = IMarket(_market).getPrice(_position.indexToken);
        int256 deltaPriceUsd = unwrap(sd(int256(indexPrice)).sub(sd(int256(_position.pnlParams.weightedAvgEntryPrice))));
        uint256 scalar = unwrap(ud(_position.positionSize).div(ud(indexPrice)));

        return _position.isLong
            ? unwrap(sd(deltaPriceUsd).mul(sd(int256(scalar))))
            : unwrap(sd(-deltaPriceUsd).mul(sd(int256(scalar))));
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
            if (_sizeDeltaUsd > 0) {
                uint256 numerator =
                    unwrap((ud(_prevWAEP).mul(ud(_prevSISU))).add(ud(uint256(_sizeDeltaUsd)).mul(ud(_price))));
                uint256 denominator = unwrap(ud(_prevSISU).add(ud(uint256(_sizeDeltaUsd))));
                return unwrap(ud(numerator).div(ud(denominator)));
            } else {
                uint256 numerator =
                    unwrap((ud(_prevWAEP).mul(ud(_prevSISU))).sub(ud(uint256(-_sizeDeltaUsd)).mul(ud(_price))));
                uint256 denominator = unwrap(ud(_prevSISU).sub(ud(uint256(-_sizeDeltaUsd))));
                return unwrap(ud(numerator).div(ud(denominator)));
            }
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
    function getDecreasePositionPnL(
        address _dataOracle,
        address _indexToken,
        uint256 _sizeDelta,
        uint256 _positionWAEP,
        uint256 _currentPrice,
        bool _isLong
    ) external view returns (int256) {
        // only realise a percentage equivalent to the percentage of the position being closed
        uint256 decimals = IDataOracle(_dataOracle).getDecimals(_indexToken);
        uint256 entryValue = unwrap((ud(_sizeDelta).mul(ud(_positionWAEP))).div(ud(10).pow(ud(decimals))));
        uint256 exitValue = unwrap((ud(_sizeDelta).mul(ud(_currentPrice))).div(ud(10).pow(ud(decimals))));
        // if long, > 0 is profit, < 0 is loss
        // if short, > 0 is loss, < 0 is profit
        if (_isLong) {
            return int256(exitValue) - int256(entryValue);
        } else {
            return int256(entryValue) - int256(exitValue);
        }
    }
}
