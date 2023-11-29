// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {MarketStructs} from "../markets/MarketStructs.sol";
import {IMarketStorage} from "../markets/interfaces/IMarketStorage.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {ITradeStorage} from "../positions/interfaces/ITradeStorage.sol";
import {ILiquidityVault} from "../markets/interfaces/ILiquidityVault.sol";
import {IWUSDC} from "../token/interfaces/IWUSDC.sol";
import {IPriceOracle} from "../oracle/interfaces/IPriceOracle.sol";

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
        uint256 nextSISU = _sizeDeltaUsd > 0 ? _prevSISU + uint256(_sizeDeltaUsd) : _prevSISU - uint256(-_sizeDeltaUsd);
        uint256 prevSum = _prevWAEP * _prevSISU;
        int256 positionSum = _sizeDeltaUsd * int256(_price);
        uint256 sum = positionSum > 0 ? prevSum + uint256(positionSum) : prevSum - uint256(positionSum);
        return sum / nextSISU;
    }

    /// @dev Positive for profit, negative for loss
    function getNetPnL(address _market, address _marketStorage, bytes32 _marketKey, bool _isLong)
        external
        view
        returns (int256)
    {
        uint256 indexValue = IMarket(_market).getIndexOpenInterestUSD(_isLong);
        uint256 entryValue = getTotalEntryValue(_market, _marketStorage, _marketKey, _isLong);

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

    function getPoolBalanceUSD(address _liquidityVault, bytes32 _marketKey, address _priceOracle, address _usdc)
        external
        view
        returns (uint256)
    {
        return getPoolBalance(_liquidityVault, _marketKey) * IPriceOracle(_priceOracle).getPrice(_usdc);
    }

    function calculateTotalCollateralOpenInterestUSD(
        address _marketStorage,
        address _market,
        address _priceOracle,
        bytes32 _marketKey
    ) external view returns (uint256) {
        return calculateCollateralOpenInterestUSD(_marketStorage, _priceOracle, _market, _marketKey, true)
            + calculateCollateralOpenInterestUSD(_marketStorage, _priceOracle, _market, _marketKey, false);
    }

    function calculateTotalIndexOpenInterestUSD(
        address _marketStorage,
        address _market,
        bytes32 _marketKey,
        address _indexToken
    ) external view returns (uint256) {
        return calculateIndexOpenInterestUSD(_marketStorage, _market, _marketKey, _indexToken, true)
            + calculateIndexOpenInterestUSD(_marketStorage, _market, _marketKey, _indexToken, false);
    }

    function calculateTotalCollateralOpenInterest(address _marketStorage, bytes32 _marketKey)
        external
        view
        returns (uint256)
    {
        return calculateCollateralOpenInterest(_marketStorage, _marketKey, true)
            + calculateCollateralOpenInterest(_marketStorage, _marketKey, false);
    }

    function getTotalEntryValue(address _market, address _marketStorage, bytes32 _marketKey, bool _isLong)
        public
        view
        returns (uint256)
    {
        uint256 totalWAEP = _isLong ? IMarket(_market).longTotalWAEP() : IMarket(_market).shortTotalWAEP();
        return totalWAEP * calculateIndexOpenInterest(_marketStorage, _marketKey, _isLong);
    }

    // returns total trade open interest in stablecoins
    function calculateCollateralOpenInterest(address _marketStorage, bytes32 _marketKey, bool _isLong)
        public
        view
        returns (uint256)
    {
        // If long, return the long open interest
        // If short, return the short open interest
        return _isLong
            ? IMarketStorage(_marketStorage).collatTokenLongOpenInterest(_marketKey)
            : IMarketStorage(_marketStorage).collatTokenShortOpenInterest(_marketKey);
    }

    // returns the open interest in tokens of the index token
    // basically how many collateral tokens have been exchanged for index tokens
    function calculateIndexOpenInterest(address _marketStorage, bytes32 _marketKey, bool _isLong)
        public
        view
        returns (uint256)
    {
        return _isLong
            ? IMarketStorage(_marketStorage).indexTokenLongOpenInterest(_marketKey)
            : IMarketStorage(_marketStorage).indexTokenShortOpenInterest(_marketKey);
    }

    function calculateCollateralOpenInterestUSD(
        address _marketStorage,
        address _priceOracle,
        address _usdc,
        bytes32 _marketKey,
        bool _isLong
    ) public view returns (uint256) {
        uint256 collateralOpenInterest = calculateCollateralOpenInterest(_marketStorage, _marketKey, _isLong);
        return collateralOpenInterest * IPriceOracle(_priceOracle).getPrice(_usdc);
    }

    /// Note Make sure variables scaled by 1e18
    function calculateIndexOpenInterestUSD(
        address _marketStorage,
        address _market,
        bytes32 _marketKey,
        address _indexToken,
        bool _isLong
    ) public view returns (uint256) {
        uint256 indexOpenInterest = calculateIndexOpenInterest(_marketStorage, _marketKey, _isLong);
        uint256 indexPrice = IMarket(_market).getPrice(_indexToken);
        return indexOpenInterest * indexPrice;
    }

    function calculateTotalIndexOpenInterest(address _marketStorage, bytes32 _marketKey)
        public
        view
        returns (uint256)
    {
        return calculateIndexOpenInterest(_marketStorage, _marketKey, true)
            + calculateIndexOpenInterest(_marketStorage, _marketKey, false);
    }

    function getPoolBalance(address _marketStorage, bytes32 _marketKey) public view returns (uint256) {
        return IMarketStorage(_marketStorage).marketAllocations(_marketKey);
    }
}
