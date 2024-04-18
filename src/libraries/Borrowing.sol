// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IMarket} from "../markets/interfaces/IMarket.sol";
import {MarketUtils} from "../markets/MarketUtils.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {MathUtils} from "./MathUtils.sol";
import {console2} from "forge-std/Test.sol";

/// @dev Library responsible for handling Borrowing related Calculations
library Borrowing {
    using SignedMath for int256;
    using MathUtils for uint256;

    uint256 private constant PRECISION = 1e18;
    uint256 private constant SECONDS_PER_DAY = 86400;

    function updateState(
        IMarket market,
        IMarket.BorrowingValues memory borrowing,
        string calldata _ticker,
        uint256 _collateralPrice,
        uint256 _collateralBaseUnit,
        bool _isLong
    ) external view returns (IMarket.BorrowingValues memory) {
        if (_isLong) {
            borrowing.longCumulativeBorrowFees +=
                _calculateFeesSinceUpdate(borrowing.longBorrowingRate, borrowing.lastBorrowUpdate);
            borrowing.longBorrowingRate = _calculateRate(market, _ticker, _collateralPrice, _collateralBaseUnit, true);
        } else {
            borrowing.shortCumulativeBorrowFees +=
                _calculateFeesSinceUpdate(borrowing.shortBorrowingRate, borrowing.lastBorrowUpdate);
            borrowing.shortBorrowingRate = _calculateRate(market, _ticker, _collateralPrice, _collateralBaseUnit, false);
        }

        borrowing.lastBorrowUpdate = uint48(block.timestamp);

        return borrowing;
    }

    function getTotalFeesOwedByMarket(IMarket market, bool _isLong) external view returns (uint256 totalFeeUsd) {
        string[] memory tickers = market.getTickers();
        uint256 len = tickers.length;
        totalFeeUsd;
        for (uint256 i = 0; i < len;) {
            totalFeeUsd += _getTotalFeesOwedForAsset(market, tickers[i], _isLong);
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
    function getNextAverageCumulative(IMarket market, string calldata _ticker, int256 _sizeDeltaUsd, bool _isLong)
        external
        view
        returns (uint256 nextAverageCumulative)
    {
        // Get the abs size delta
        uint256 absSizeDelta = _sizeDeltaUsd.abs();
        // Get the Open Interest
        uint256 openInterestUsd = MarketUtils.getOpenInterest(market, _ticker, _isLong);
        // Get the current cumulative fee on the market
        uint256 currentCumulative = MarketUtils.getCumulativeBorrowFee(market, _ticker, _isLong)
            + calculatePendingFees(market, _ticker, _isLong);
        // Get the last weighted average entry cumulative fee
        uint256 lastCumulative = MarketUtils.getAverageCumulativeBorrowFee(market, _ticker, _isLong);
        // If OI before is 0, or last cumulative = 0, return current cumulative
        if (openInterestUsd == 0 || lastCumulative == 0) return currentCumulative;
        // If Position is Decrease
        if (_sizeDeltaUsd < 0) {
            // If full decrease, reset the average cumulative
            if (absSizeDelta == openInterestUsd) return 0;
            // Else, the cumulative shouldn't change
            else return lastCumulative;
        }
        // If this point in execution is reached -> calculate the next average cumulative
        // Get the percentage of the new position size relative to the total open interest
        // Relative Size = (absSizeDelta / openInterestUsd)
        uint256 relativeSize = absSizeDelta.div(openInterestUsd);
        // Calculate the new weighted average entry cumulative fee
        /**
         * lastCumulative.mul(PRECISION - relativeSize) + currentCumulative.mul(relativeSize);
         */
        nextAverageCumulative = lastCumulative.mul(PRECISION - relativeSize) + currentCumulative.mul(relativeSize);
    }

    /// @dev Units: Fees as a percentage (e.g 0.03e18 = 3%)
    /// @dev Gets fees since last time the cumulative market rate was updated
    function calculatePendingFees(IMarket market, string calldata _ticker, bool _isLong)
        public
        view
        returns (uint256 pendingFees)
    {
        uint256 borrowRate = MarketUtils.getBorrowingRate(market, _ticker, _isLong);
        if (borrowRate == 0) return 0;
        uint256 timeElapsed = block.timestamp - MarketUtils.getLastBorrowingUpdate(market, _ticker);
        if (timeElapsed == 0) return 0;
        pendingFees = borrowRate * timeElapsed;
    }

    /**
     * ============================== Private Functions ==============================
     */

    /**
     * Borrow scale represents the maximium possible borrowing fee per day.
     * We then apply a factor to the scale to get the actual borrowing fee.
     * The calculation for the factor is simply (open interest usd / max open interest usd).
     * If OI is low, fee will be low, if OI is close to max, fee will be close to max.
     */
    function _calculateRate(
        IMarket market,
        string calldata _ticker,
        uint256 _collateralPrice,
        uint256 _collateralBaseUnit,
        bool _isLong
    ) private view returns (uint256 borrowRatePerDay) {
        // Factor = (open interest usd / max open interest usd)
        uint256 openInterest = MarketUtils.getOpenInterest(market, _ticker, _isLong);

        uint256 maxOi = MarketUtils.getMaxOpenInterest(market, _ticker, _collateralPrice, _collateralBaseUnit, _isLong);

        uint256 factor = openInterest.div(maxOi);

        borrowRatePerDay = market.borrowScale();

        // Opposite case cann occur if collateral decreases in value significantly.
        if (openInterest < maxOi) {
            borrowRatePerDay = borrowRatePerDay.percentage(factor);
        }
    }

    function _getTotalFeesOwedForAsset(IMarket market, string memory _ticker, bool _isLong)
        private
        view
        returns (uint256 totalFeesOwedUsd)
    {
        uint256 accumulatedFees = MarketUtils.getCumulativeBorrowFee(market, _ticker, _isLong)
            - MarketUtils.getAverageCumulativeBorrowFee(market, _ticker, _isLong);
        uint256 openInterest = MarketUtils.getOpenInterest(market, _ticker, _isLong);
        // Total Fees Owed = cumulativeFeePercentage * openInterestUsd
        totalFeesOwedUsd = accumulatedFees.mul(openInterest);
    }

    function _calculateFeesSinceUpdate(uint256 _rate, uint256 _lastUpdate) private view returns (uint256 fee) {
        uint256 timeElapsed = block.timestamp - _lastUpdate;
        if (timeElapsed == 0) return 0;
        // Fees = (borrowRatePerDay * timeElapsed)
        fee = _rate.percentage(timeElapsed, SECONDS_PER_DAY);
    }
}
