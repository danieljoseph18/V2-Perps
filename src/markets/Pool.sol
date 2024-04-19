// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IMarket} from "./interfaces/IMarket.sol";
import {Funding} from "../libraries/Funding.sol";
import {Borrowing} from "../libraries/Borrowing.sol";
import {MarketUtils} from "./MarketUtils.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";

library Pool {
    using SignedMath for int256;

    event MarketStateUpdated(string ticker, bool isLong);

    error Pool_InvalidTicker();

    struct Storage {
        Config config;
        Cumulatives cumulatives;
        uint256 longOpenInterest;
        uint256 shortOpenInterest;
        /**
         * The rate at which funding is accumulated.
         */
        int64 fundingRate;
        /**
         * The rate at which the funding rate is changing.
         */
        int64 fundingRateVelocity;
        /**
         * The rate at which borrowing fees are accruing for longs.
         */
        uint64 longBorrowingRate;
        /**
         * The rate at which borrowing fees are accruing for shorts.
         */
        uint64 shortBorrowingRate;
        /**
         * The last time the storage was updated.
         */
        uint48 lastUpdate;
        /**
         * Number of shares allocated to each sub-market.
         * A market can contain multiple index tokens, each of which have
         * a percentage of liquidity allocated to them.
         * Units are in shares, where 100% = 100
         * Cumulative allocations must total up to 100.
         */
        uint8 allocationShare;
        /**
         * The value (in USD) of total market funding accumulated.
         * Swings back and forth across 0 depending on the velocity / funding rate.
         */
        int256 fundingAccruedUsd;
        /**
         * The size of the Price impact pool.
         * Negative price impact is accumulated in the pool.
         * Positive price impact is paid out of the pool.
         * Units in USD (30 D.P).
         */
        uint256 impactPool;
    }

    struct Cumulatives {
        /**
         * The weighted average entry price of all long positions in the market.
         */
        uint256 longAverageEntryPriceUsd;
        /**
         * The weighted average entry price of all short positions in the market.
         */
        uint256 shortAverageEntryPriceUsd;
        /**
         * The value (%) of the total market borrowing fees accumulated for longs.
         */
        uint256 longCumulativeBorrowFees;
        /**
         * The value (%) of the total market borrowing fees accumulated for shorts.
         */
        uint256 shortCumulativeBorrowFees;
        /**
         * The average cumulative borrow fees at entry for long positions in the market.
         * Used to calculate total borrow fees owed for the market.
         */
        uint256 weightedAvgCumulativeLong;
        /**
         * The average cumulative borrow fees at entry for short positions in the market.
         * Used to calculate total borrow fees owed for the market.
         */
        uint256 weightedAvgCumulativeShort;
    }

    struct Config {
        /**
         * Maximum Leverage for the Market
         * Value to 0 decimal places. E.g. 5 = 5x leverage.
         */
        uint8 maxLeverage;
        /**
         * Percentage of the position's size that must be maintained as margin.
         * Used to prevent liquidation threshold from being at the point
         * of insolvency.
         * 2 d.p. precision. 1050 = 10.5%
         */
        uint16 maintenanceMargin;
        /**
         * % of liquidity that CAN'T be allocated to positions
         * Reserves should be higher for more volatile markets.
         * 2 d.p precision. 2500 = 25%
         */
        uint16 reserveFactor;
        /**
         * Maximum Funding Velocity
         * Units: % Per Day
         * 2 d.p precision. 1000 = 10%
         */
        int16 maxFundingVelocity;
        /**
         * Sensitivity to Market Skew
         * Units: USD
         * No decimals --> 1_000_000 = $1,000,000
         */
        int48 skewScale;
        /**
         * Dampening factor for the effect of skew in positive price impact.
         * Value as a percentage, with 2 d.p of precision.
         * Needs to be expanded to 30 dp for USD calculations.
         */
        int16 positiveSkewScalar;
        /**
         * Dampening factor for the effect of skew in negative price impact.
         * Value as a percentage, with 2 d.p of precision.
         * Needs to be expanded to 30 dp for USD calculations.
         */
        int16 negativeSkewScalar;
        /**
         * Dampening factor for the effect of liquidity in positive price impact.
         * Value as a percentage, with 2 d.p of precision.
         * Needs to be expanded to 30 dp for USD calculations.
         */
        int16 positiveLiquidityScalar;
        /**
         * Dampening factor for the effect of liquidity in negative price impact.
         * Value as a percentage, with 2 d.p of precision.
         * Needs to be expanded to 30 dp for USD calculations.
         */
        int16 negativeLiquidityScalar;
    }

    function initialize(Storage storage pool, Config memory _config) internal {
        pool.allocationShare = 100;
        pool.config = _config;
        pool.lastUpdate = uint48(block.timestamp);
    }

    function updateState(
        Storage storage pool,
        string calldata _ticker,
        uint256 _sizeDelta,
        uint256 _indexPrice,
        uint256 _impactedPrice,
        uint256 _collateralPrice,
        uint256 _collateralBaseUnit,
        bool _isLong,
        bool _isIncrease
    ) internal {
        IMarket market = IMarket(address(this));
        // If invalid ticker, revert
        if (!market.isAssetInMarket(_ticker)) revert Pool_InvalidTicker();
        // 1. Depends on Open Interest Delta to determine Skew
        Funding.updateState(market, pool, _ticker, _indexPrice);
        if (_sizeDelta != 0) {
            // Use Impacted Price for Entry
            // 2. Relies on Open Interest Delta
            _updateWeightedAverages(
                pool,
                market,
                _ticker,
                _impactedPrice == 0 ? _indexPrice : _impactedPrice, // If no price impact, set to the index price
                _isIncrease ? int256(_sizeDelta) : -int256(_sizeDelta),
                _isLong
            );
            // 3. Updated pre-borrowing rate if size delta > 0
            if (_isIncrease) {
                if (_isLong) {
                    pool.longOpenInterest += _sizeDelta;
                } else {
                    pool.shortOpenInterest += _sizeDelta;
                }
            } else {
                if (_isLong) {
                    pool.longOpenInterest -= _sizeDelta;
                } else {
                    pool.shortOpenInterest -= _sizeDelta;
                }
            }
        }
        // 4. Relies on Updated Open interest
        Borrowing.updateState(market, pool, _ticker, _collateralPrice, _collateralBaseUnit, _isLong);
        // 5. Update the last update time
        pool.lastUpdate = uint48(block.timestamp);
        // Fire Event
        emit MarketStateUpdated(_ticker, _isLong);
    }

    function updateImpactPool(Storage storage pool, int256 _priceImpactUsd) internal {
        _priceImpactUsd > 0 ? pool.impactPool += _priceImpactUsd.abs() : pool.impactPool -= _priceImpactUsd.abs();
    }

    /**
     * ========================= Private Functions =========================
     */

    /**
     * Updates the weighted average values for the market. Both rely on the market condition pre-open interest update.
     */
    function _updateWeightedAverages(
        Pool.Storage storage _storage,
        IMarket market,
        string calldata _ticker,
        uint256 _priceUsd,
        int256 _sizeDeltaUsd,
        bool _isLong
    ) private {
        if (_sizeDeltaUsd == 0) return;

        if (_isLong) {
            _storage.cumulatives.longAverageEntryPriceUsd = MarketUtils.calculateWeightedAverageEntryPrice(
                _storage.cumulatives.longAverageEntryPriceUsd, _storage.longOpenInterest, _sizeDeltaUsd, _priceUsd
            );
            _storage.cumulatives.weightedAvgCumulativeLong =
                Borrowing.getNextAverageCumulative(market, _ticker, _sizeDeltaUsd, true);
        } else {
            _storage.cumulatives.shortAverageEntryPriceUsd = MarketUtils.calculateWeightedAverageEntryPrice(
                _storage.cumulatives.shortAverageEntryPriceUsd, _storage.shortOpenInterest, _sizeDeltaUsd, _priceUsd
            );
            _storage.cumulatives.weightedAvgCumulativeShort =
                Borrowing.getNextAverageCumulative(market, _ticker, _sizeDeltaUsd, false);
        }
    }
}
