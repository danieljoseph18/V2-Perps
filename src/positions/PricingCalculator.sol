// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {MarketStructs} from "../markets/MarketStructs.sol";
import {IMarketStorage} from "../markets/interfaces/IMarketStorage.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {ITradeStorage} from "../positions/interfaces/ITradeStorage.sol";
import {ILiquidityVault} from "../markets/interfaces/ILiquidityVault.sol";
import {SD59x18, sd, unwrap, pow} from "@prb/math/SD59x18.sol";
import {UD60x18, ud, unwrap} from "@prb/math/UD60x18.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IWUSDC} from "../token/interfaces/IWUSDC.sol";
import {IPriceOracle} from "../oracle/interfaces/IPriceOracle.sol";

/*
    weightedAverageEntryPrice = x(indexSizeUSD * entryPrice) / sigmaIndexSizesUSD
    PNL = (Current price of index tokens - Weighted average entry price) * (Total position size / Current price of index tokens)
 */

library PricingCalculator {
    using SafeCast for uint256;
    using SafeCast for int256;

    /////////
    // PNL //
    /////////

    // if long, entry - position = pnl, if short, position - entry = pnl
    /// PNL = (Current price of index tokens - Weighted average entry price) * (Total position size / Current price of index tokens)
    function calculatePnL(address _market, MarketStructs.Position memory _position) external view returns (int256) {
        uint256 indexPrice = IMarket(_market).getPrice(_position.indexToken);
        int256 deltaPriceUsd = indexPrice.toInt256() - _position.pnlParams.weightedAvgEntryPrice.toInt256();
        uint256 scalar = unwrap(ud(_position.positionSize).div(ud(indexPrice)));

        return _position.isLong ? deltaPriceUsd * scalar.toInt256() : -deltaPriceUsd * scalar.toInt256();
    }

    /// weightedAverageEntryPrice = x(indexSizeUSD * entryPrice) / sigmaIndexSizesUSD
    /// @dev Calculates the Next WAEP after a delta in a position
    function calculateWeightedAverageEntryPrice(
        uint256 _prevWAEP,
        uint256 _prevSISU,
        int256 _sizeDeltaUsd,
        uint256 _price
    ) external pure returns (uint256) {
        uint256 nextSISU =
            _sizeDeltaUsd > 0 ? _prevSISU + _sizeDeltaUsd.toUint256() : _prevSISU - _sizeDeltaUsd.toUint256();
        uint256 prevSum = _prevWAEP * _prevSISU;
        int256 nextSum = _sizeDeltaUsd * _price.toInt256();
        uint256 sum = nextSum > 0 ? prevSum + nextSum.toUint256() : prevSum - nextSum.toUint256();
        return sum / nextSISU;
    }

    function getNetPnL(address _market, address _marketStorage, bytes32 _marketKey, bool _isLong)
        external
        view
        returns (int256)
    {
        uint256 indexValue = IMarket(_market).getIndexOpenInterestUSD(_isLong);
        uint256 entryValue = getTotalEntryValue(_market, _marketStorage, _marketKey, _isLong);

        return _isLong ? indexValue.toInt256() - entryValue.toInt256() : entryValue.toInt256() - indexValue.toInt256();
    }

    /// RealizedPNL=(Current price − Weighted average entry price)×(Realized position size/Current price)
    /// int256 pnl = int256(amountToRealize * currentTokenPrice) - int256(amountToRealize * userPos.entryPriceWeighted);
    /// Note If decreasing a position and realizing PNL, it's crucial to adjust the WAEP
    function getDecreasePositionPnL(uint256 _sizeDelta, uint256 _positionWAEP, uint256 _currentPrice, bool _isLong)
        external
        pure
        returns (int256)
    {
        // only realise a percentage equivalent to the percentage of the position being closed
        int256 valueDelta = (_sizeDelta * _positionWAEP).toInt256() - (_sizeDelta * _currentPrice).toInt256();
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

    // Get the principle deposited for the amount of index tokens being realised
    function getDecreasePositionPrinciple(uint256 _sizeDelta, uint256 _positionWAEP, uint256 _leverage)
        external
        pure
        returns (uint256)
    {
        // principle = (sizeDelta * WAEP) / leverage
        return (_sizeDelta * _positionWAEP) / _leverage;
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

    function getPoolBalance(address _liquidityVault, bytes32 _marketKey) public view returns (uint256) {
        return ILiquidityVault(_liquidityVault).getMarketAllocation(_marketKey);
    }
}
