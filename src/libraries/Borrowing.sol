// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IMarket} from "../markets/interfaces/IMarket.sol";
import {IVault} from "../markets/interfaces/IVault.sol";
import {MarketUtils} from "../markets/MarketUtils.sol";
import {MathUtils} from "./MathUtils.sol";
import {Casting} from "./Casting.sol";
import {Units} from "./Units.sol";
import {Pool} from "../markets/Pool.sol";
import {MarketId, MarketIdLibrary} from "../types/MarketId.sol";

/// @dev Library responsible for handling Borrowing related Calculations
library Borrowing {
    using MathUtils for uint256;
    using Casting for int256;
    using Units for uint256;

    uint256 private constant PRECISION = 1e18;
    uint256 private constant SECONDS_PER_DAY = 86400;

    function updateState(
        MarketId _id,
        IMarket market,
        IVault vault,
        Pool.Storage storage pool,
        string calldata _ticker,
        uint256 _collateralPrice,
        uint256 _collateralBaseUnit,
        bool _isLong
    ) internal {
        if (_isLong) {
            pool.cumulatives.longCumulativeBorrowFees +=
                calculateFeesSinceUpdate(pool.longBorrowingRate, pool.lastUpdate);

            pool.longBorrowingRate =
                uint64(calculateRate(_id, market, vault, _ticker, _collateralPrice, _collateralBaseUnit, true));
        } else {
            pool.cumulatives.shortCumulativeBorrowFees +=
                calculateFeesSinceUpdate(pool.shortBorrowingRate, pool.lastUpdate);

            pool.shortBorrowingRate =
                uint64(calculateRate(_id, market, vault, _ticker, _collateralPrice, _collateralBaseUnit, false));
        }
    }

    function getTotalFeesOwedByMarket(MarketId _id, IMarket market, bool _isLong)
        internal
        view
        returns (uint256 totalFeeUsd)
    {
        string[] memory tickers = market.getTickers(_id);
        uint256 len = tickers.length;

        totalFeeUsd;
        for (uint256 i = 0; i < len;) {
            totalFeeUsd += getTotalFeesOwedForAsset(_id, market, tickers[i], _isLong);

            unchecked {
                ++i;
            }
        }
    }

    /**
     * This function stores an average of the "lastCumulativeBorrowFee" for all positions combined.
     * It's used to track the average borrowing fee for all positions.
     * The average is calculated by taking the old average
     *
     * w_new = (w_last * (1 - p)) + (f_current * p)
     *
     * w_new: New weighted average entry cumulative fee
     * w_last: Last weighted average entry cumulative fee
     * f_current: The current cumulative fee on the market.
     * p: The proportion of the new position size relative to the total open interest.
     */
    function getNextAverageCumulative(
        MarketId _id,
        IMarket market,
        string calldata _ticker,
        int256 _sizeDeltaUsd,
        bool _isLong
    ) internal view returns (uint256 nextAverageCumulative) {
        uint256 absSizeDelta = _sizeDeltaUsd.abs();

        uint256 openInterestUsd = market.getOpenInterest(_id, _ticker, _isLong);

        uint256 currentCumulative =
            market.getCumulativeBorrowFee(_id, _ticker, _isLong) + calculatePendingFees(_id, market, _ticker, _isLong);

        uint256 lastCumulative = market.getAverageCumulativeBorrowFee(_id, _ticker, _isLong);

        if (openInterestUsd == 0 || lastCumulative == 0) return currentCumulative;

        if (_sizeDeltaUsd < 0) {
            // If full decrease, reset the average cumulative.
            if (absSizeDelta == openInterestUsd) return 0;
            // For regular decreases, the cumulative shouldn't change.
            else return lastCumulative;
        }

        // Relative Size = (absSizeDelta / openInterestUsd)
        uint256 relativeSize = absSizeDelta.divWad(openInterestUsd);

        /**
         * nextCumulative = lastCumulative * (PRECISION - relativeSize) + currentCumulative * (relativeSize);
         */
        nextAverageCumulative = lastCumulative.mulWad(PRECISION - relativeSize) + currentCumulative.mulWad(relativeSize);
    }

    /// @dev Units: Fees as a percentage (e.g 0.03e18 = 3%)
    /// @dev Gets fees since last time the cumulative market rate was updated
    function calculatePendingFees(MarketId _id, IMarket market, string calldata _ticker, bool _isLong)
        public
        view
        returns (uint256 pendingFees)
    {
        uint256 borrowRate = market.getBorrowingRate(_id, _ticker, _isLong);

        if (borrowRate == 0) return 0;

        uint256 timeElapsed = block.timestamp - market.getLastUpdate(_id, _ticker);

        if (timeElapsed == 0) return 0;

        pendingFees = borrowRate * timeElapsed;
    }

    function calculateFeesSinceUpdate(uint256 _rate, uint256 _lastUpdate) public view returns (uint256 fee) {
        uint256 timeElapsed = block.timestamp - _lastUpdate;

        if (timeElapsed == 0) return 0;

        // Fees = (borrowRatePerDay * timeElapsed (days))
        fee = _rate.percentage(timeElapsed, SECONDS_PER_DAY);
    }

    /**
     * Borrow scale represents the maximium possible borrowing fee per day.
     * We then apply a factor to the scale to get the actual borrowing fee.
     * The calculation for the factor is simply (open interest usd / max open interest usd).
     * If OI is low, fee will be low, if OI is close to max, fee will be close to max.
     */
    function calculateRate(
        MarketId _id,
        IMarket market,
        IVault vault,
        string calldata _ticker,
        uint256 _collateralPrice,
        uint256 _collateralBaseUnit,
        bool _isLong
    ) public view returns (uint256 borrowRatePerDay) {
        uint256 openInterest = market.getOpenInterest(_id, _ticker, _isLong);

        uint256 maxOi =
            MarketUtils.getMaxOpenInterest(_id, market, vault, _ticker, _collateralPrice, _collateralBaseUnit, _isLong);

        borrowRatePerDay = market.getBorrowScale(_id);

        // Opposite case can occur if collateral decreases in value significantly.
        if (openInterest < maxOi) {
            uint256 factor = openInterest.divWad(maxOi);
            borrowRatePerDay = borrowRatePerDay.percentage(factor);
        }
        // If Oi > Max Oi, default rate to max rate per day
    }

    function getTotalFeesOwedForAsset(MarketId _id, IMarket market, string memory _ticker, bool _isLong)
        public
        view
        returns (uint256 totalFeesOwedUsd)
    {
        uint256 accumulatedFees = market.getCumulativeBorrowFee(_id, _ticker, _isLong)
            - market.getAverageCumulativeBorrowFee(_id, _ticker, _isLong);

        uint256 openInterest = market.getOpenInterest(_id, _ticker, _isLong);

        totalFeesOwedUsd = accumulatedFees.mulWad(openInterest);
    }
}
