// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.21;

import {MarketStructs} from "../markets/MarketStructs.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";

/// @dev Note, need to handle the case where velocity crosses 0 (pos -> neg or neg -> pos)
library FundingCalculator {
    /// @dev Calculate the funding rate velocity.
    function calculateFundingRateVelocity(address _market, int256 _skew) external view returns (int256) {
        uint256 c = (IMarket(_market).maxFundingVelocity() * 1e18) / IMarket(_market).skewScale();
        int256 skew = _skew;
        return (int256(c) * skew) / 1e18;
    }

    /// @dev Get the total funding fees accumulated for long and short sides since the last update.
    function getFundingFees(address _market) external view returns (uint256, uint256) {
        IMarket market = IMarket(_market);
        return _getAccumulatedFunding(market);
    }

    /// @dev Get the total funding fees Earned by a position.
    function getTotalPositionFeeEarned(address _market, MarketStructs.Position memory _position)
        external
        view
        returns (uint256)
    {
        // Funding Accumulated (Earned)
        uint256 accumulatedFunding = _position.isLong
            ? IMarket(_market).shortCumulativeFundingFees() - _position.fundingParams.lastShortCumulativeFunding
            : IMarket(_market).longCumulativeFundingFees() - _position.fundingParams.lastLongCumulativeFunding;
        (uint256 feesEarned,) =
            getFeesSinceTimestamp(_market, IMarket(_market).lastFundingUpdateTime(), _position.isLong);
        return feesEarned + _position.fundingParams.feesEarned + ((accumulatedFunding * _position.positionSize) / 1e18);
    }

    /// @dev Get the total funding fees Owed by a position.
    function getTotalPositionFeeOwed(address _market, MarketStructs.Position memory _position)
        external
        view
        returns (uint256)
    {
        // Funding Accumulated (Owed)
        uint256 accumulatedFunding = _position.isLong
            ? IMarket(_market).longCumulativeFundingFees() - _position.fundingParams.lastLongCumulativeFunding
            : IMarket(_market).shortCumulativeFundingFees() - _position.fundingParams.lastShortCumulativeFunding;
        // Velocity-Based Funding Accumulated
        (, uint256 feesOwed) =
            getFeesSinceTimestamp(_market, IMarket(_market).lastFundingUpdateTime(), _position.isLong);
        return feesOwed + _position.fundingParams.feesOwed + ((accumulatedFunding * _position.positionSize) / 1e18);
    }

    function getCurrentFundingRate(address _market) external view returns (int256) {
        IMarket market = IMarket(_market);
        uint256 timeElapsed = block.timestamp - market.lastFundingUpdateTime();
        int256 fundingRate = market.fundingRate();
        int256 fundingRateVelocity = market.fundingRateVelocity();

        return fundingRate + (fundingRateVelocity * int256(timeElapsed));
    }

    /// @dev Get the funding fees earned and owed by a position since its last update.
    function getFeesSinceTimestamp(address _market, uint256 _accumulationDuration, bool _isLong)
        public
        view
        returns (uint256 feesEarned, uint256 feesOwed)
    {
        IMarket market = IMarket(_market);

        (uint256 longFees, uint256 shortFees) = _calculateAdjustedFunding(
            market.fundingRate(),
            market.fundingRateVelocity(),
            _accumulationDuration,
            market.maxFundingRate(),
            market.minFundingRate()
        );

        feesEarned = _isLong ? shortFees : longFees;
        feesOwed = _isLong ? longFees : shortFees;
    }

    /// @dev Adjusts the total funding calculation when max or min limits are reached, or when the sign flips.
    function _calculateAdjustedFunding(
        int256 _fundingRate,
        int256 _fundingRateVelocity,
        uint256 _timeElapsed,
        int256 _maxFundingRate,
        int256 _minFundingRate
    ) internal pure returns (uint256 longFees, uint256 shortFees) {
        // Calculate final funding rate after time elapsed
        int256 finalFundingRate = _fundingRate + _fundingRateVelocity * int256(_timeElapsed);

        // Check for boundary crossing and sign flip
        if (finalFundingRate > _maxFundingRate || finalFundingRate < _minFundingRate) {
            // Case 1: Crossing the boundary
            uint256 timeToBoundary;
            int256 boundaryRate;

            // Determine the time to reach the boundary and which boundary is hit
            if (finalFundingRate > _maxFundingRate) {
                timeToBoundary = uint256((_maxFundingRate - _fundingRate) / _fundingRateVelocity);
                boundaryRate = _maxFundingRate;
            } else {
                timeToBoundary = uint256((_minFundingRate - _fundingRate) / _fundingRateVelocity);
                boundaryRate = _minFundingRate;
            }

            // Calculate funding until hitting the boundary
            int256 fundingUntilBoundary = _calculateSeriesSum(_fundingRate, _fundingRateVelocity, timeToBoundary);

            // Calculate funding after hitting the boundary
            uint256 timeAfterBoundary = _timeElapsed - timeToBoundary;
            int256 fundingAfterBoundary = boundaryRate * int256(timeAfterBoundary);

            return boundaryRate == _maxFundingRate
                ? (uint256(fundingUntilBoundary) + uint256(fundingAfterBoundary), uint256(0)) // Positive Case
                : (uint256(0), uint256(fundingUntilBoundary) + uint256(fundingAfterBoundary)); // Negative Case
        } else if ((_fundingRate >= 0 && finalFundingRate < 0) || (_fundingRate < 0 && finalFundingRate >= 0)) {
            // Case 2: Sign flip
            // Calculate time to sign flip
            uint256 timeToFlip = uint256(-_fundingRate / _fundingRateVelocity);

            // Calculate funding until the sign flip
            int256 fundingUntilFlip = _calculateSeriesSum(_fundingRate, _fundingRateVelocity, timeToFlip);

            // Remaining time after the flip
            uint256 timeAfterFlip = _timeElapsed - timeToFlip;

            // Calculate funding after the flip with the flipped rate
            int256 flippedRate = _fundingRate + _fundingRateVelocity * int256(timeToFlip);
            int256 fundingAfterFlip = flippedRate * int256(timeAfterFlip);

            return fundingAfterFlip >= 0
                ? (uint256(fundingAfterFlip), uint256(fundingUntilFlip)) // Positive Case
                : (uint256(fundingUntilFlip), uint256(fundingAfterFlip)); // Negative Case
        } else {
            // Case 3: No boundary crossing or sign flip, use standard calculation\
            int256 fee = _calculateSeriesSum(_fundingRate, _fundingRateVelocity, _timeElapsed);
            return fee >= 0
                ? (uint256(fee), uint256(0)) // Positive Case
                : (uint256(0), uint256(-fee)); // Negative Case
        }
    }

    /// @dev Calculates the sum of an arithmetic series.
    function _calculateSeriesSum(int256 _fundingRate, int256 _fundingRateVelocity, uint256 _timeElapsed)
        internal
        pure
        returns (int256)
    {
        if (_timeElapsed == 0) {
            return 0;
        }

        if (_timeElapsed == 0 || (_fundingRate == 0 && _fundingRateVelocity == 0)) {
            return 0;
        }

        if (_timeElapsed == 1) {
            return _fundingRate;
        }

        int256 startRate = _fundingRate;
        int256 endRate = _fundingRate + _fundingRateVelocity * int256(_timeElapsed - 1);

        return int256(_timeElapsed) * (startRate + endRate) / 2;
    }

    /// @dev Helper function to calculate accumulated funding for long and short sides.
    function _getAccumulatedFunding(IMarket _market)
        internal
        view
        returns (uint256 longFunding, uint256 shortFunding)
    {
        uint256 timeElapsed = block.timestamp - _market.lastFundingUpdateTime();
        int256 fundingRate = _market.fundingRate();
        int256 fundingRateVelocity = _market.fundingRateVelocity();

        // Calculate total funding using arithmetic series sum formula
        (uint256 longFundingSinceUpdate, uint256 shortFundingSinceUpdate) = _calculateAdjustedFunding(
            fundingRate, fundingRateVelocity, timeElapsed, _market.maxFundingRate(), _market.minFundingRate()
        );

        longFunding = _market.longCumulativeFundingFees() + longFundingSinceUpdate;
        shortFunding = _market.shortCumulativeFundingFees() + shortFundingSinceUpdate;
    }
}
