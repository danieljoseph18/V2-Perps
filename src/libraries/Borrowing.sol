// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IMarket} from "../markets/interfaces/IMarket.sol";
import {MarketUtils} from "../markets/MarketUtils.sol";
import {mulDiv} from "@prb/math/Common.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";

/// @dev Library responsible for handling Borrowing related Calculations
library Borrowing {
    using SignedMath for int256;

    uint256 private constant PRECISION = 1e18;
    uint256 private constant SECONDS_PER_DAY = 86400;

    function updateState(
        IMarket market,
        IMarket.BorrowingValues memory borrowing,
        bytes32 _assetId,
        uint256 _collateralPrice,
        uint256 _collateralBaseUnit,
        bool _isLong
    ) external view returns (IMarket.BorrowingValues memory) {
        if (_isLong) {
            borrowing.longCumulativeBorrowFees +=
                calculateFeesSinceUpdate(borrowing.longBorrowingRate, borrowing.lastBorrowUpdate);
            borrowing.longBorrowingRate = calculateRate(market, _assetId, _collateralPrice, _collateralBaseUnit, true);
        } else {
            borrowing.shortCumulativeBorrowFees +=
                calculateFeesSinceUpdate(borrowing.shortBorrowingRate, borrowing.lastBorrowUpdate);
            borrowing.shortBorrowingRate = calculateRate(market, _assetId, _collateralPrice, _collateralBaseUnit, false);
        }

        borrowing.lastBorrowUpdate = uint48(block.timestamp);

        return borrowing;
    }

    /**
     * Borrow scale represents the maximium possible borrowing fee per day.
     * We then apply a factor to the scale to get the actual borrowing fee.
     * The calculation for the factor is simply (open interest usd / max open interest usd).
     * If OI is low, fee will be low, if OI is close to max, fee will be close to max.
     */
    function calculateRate(
        IMarket market,
        bytes32 _assetId,
        uint256 _collateralPrice,
        uint256 _collateralBaseUnit,
        bool _isLong
    ) public view returns (uint256 borrowRatePerDay) {
        uint256 factor = mulDiv(
            MarketUtils.getOpenInterest(market, _assetId, _isLong),
            PRECISION,
            MarketUtils.getAvailableOiUsd(market, _assetId, _collateralPrice, _collateralBaseUnit, _isLong)
        );
        borrowRatePerDay = mulDiv(market.borrowScale(), factor, PRECISION);
    }

    function calculateFeesSinceUpdate(uint256 _rate, uint256 _lastUpdate) public view returns (uint256 fee) {
        uint256 timeElapsed = block.timestamp - _lastUpdate;
        if (timeElapsed == 0) return 0;
        fee = mulDiv(_rate, timeElapsed, SECONDS_PER_DAY);
    }

    function getTotalFeesOwedByMarkets(IMarket market, bool _isLong) external view returns (uint256 totalFeeUsd) {
        bytes32[] memory assetIds = market.getAssetIds();
        uint256 len = assetIds.length;
        totalFeeUsd;
        for (uint256 i = 0; i < len;) {
            totalFeeUsd += getTotalFeesOwedByMarket(market, assetIds[i], _isLong);
            unchecked {
                ++i;
            }
        }
    }

    function getTotalFeesOwedByMarket(IMarket market, bytes32 _assetId, bool _isLong)
        public
        view
        returns (uint256 totalFeesOwedUsd)
    {
        uint256 accumulatedFees = MarketUtils.getCumulativeBorrowFee(market, _assetId, _isLong)
            - MarketUtils.getAverageCumulativeBorrowFee(market, _assetId, _isLong);
        uint256 openInterest = MarketUtils.getOpenInterest(market, _assetId, _isLong);
        totalFeesOwedUsd = mulDiv(accumulatedFees, openInterest, PRECISION);
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
    function getNextAverageCumulative(IMarket market, bytes32 _assetId, int256 _sizeDeltaUsd, bool _isLong)
        external
        view
        returns (uint256 nextAverageCumulative)
    {
        // Get the abs size delta
        uint256 absSizeDelta = _sizeDeltaUsd.abs();
        // Get the Open Interest
        uint256 openInterestUsd = MarketUtils.getOpenInterest(market, _assetId, _isLong);
        // Get the current cumulative fee on the market
        uint256 currentCumulative = MarketUtils.getCumulativeBorrowFee(market, _assetId, _isLong)
            + calculatePendingFees(market, _assetId, _isLong);
        // Get the last weighted average entry cumulative fee
        uint256 lastCumulative = MarketUtils.getAverageCumulativeBorrowFee(market, _assetId, _isLong);
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
        uint256 relativeSize = mulDiv(absSizeDelta, PRECISION, openInterestUsd);
        // Calculate the new weighted average entry cumulative fee
        nextAverageCumulative = mulDiv(lastCumulative, PRECISION - relativeSize, PRECISION)
            + mulDiv(currentCumulative, relativeSize, PRECISION);
    }

    /// @dev Units: Fees as a percentage (e.g 0.03e18 = 3%)
    /// @dev Gets fees since last time the cumulative market rate was updated
    function calculatePendingFees(IMarket market, bytes32 _assetId, bool _isLong)
        public
        view
        returns (uint256 pendingFees)
    {
        uint256 borrowRate = MarketUtils.getBorrowingRate(market, _assetId, _isLong);
        if (borrowRate == 0) return 0;
        uint256 timeElapsed = block.timestamp - MarketUtils.getLastBorrowingUpdate(market, _assetId);
        if (timeElapsed == 0) return 0;
        pendingFees = borrowRate * timeElapsed;
    }
}
