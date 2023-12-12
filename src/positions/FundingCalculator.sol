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
        bool flipsSign = (_fundingRate >= 0 && finalFundingRate < 0) || (_fundingRate < 0 && finalFundingRate >= 0);
        bool crossesBoundary = finalFundingRate > _maxFundingRate || finalFundingRate < _minFundingRate;

        if (crossesBoundary && flipsSign) {
            return _calculateForDoubleCross(_fundingRate, _fundingRateVelocity, _maxFundingRate, _timeElapsed);
        } else if (crossesBoundary) {
            return _calculateForBoundaryCross(_fundingRate, _fundingRateVelocity, _maxFundingRate, _timeElapsed);
        } else if (flipsSign) {
            return _calculateForSignFlip(_fundingRate, _fundingRateVelocity, _timeElapsed);
        } else {
            int256 fee = _calculateSeriesSum(_fundingRate, _fundingRateVelocity, _timeElapsed);
            return fee >= 0 ? (uint256(fee), uint256(0)) : (uint256(0), uint256(-fee));
        }
    }

    function _calculateForDoubleCross(
        int256 _fundingRate,
        int256 _fundingRateVelocity,
        int256 _maxFundingRate,
        uint256 _timeElapsed
    ) internal pure returns (uint256 longFees, uint256 shortFees) {
        uint256 absRate = _fundingRate > 0 ? uint256(_fundingRate) : uint256(-_fundingRate);
        uint256 absVelocity = _fundingRateVelocity > 0 ? uint256(_fundingRateVelocity) : uint256(-_fundingRateVelocity);
        uint256 timeToFlip = absRate / absVelocity;
        uint256 timeToBoundary = _fundingRate > 0
            ? uint256((_maxFundingRate + _fundingRate)) / absVelocity
            : uint256((_maxFundingRate + -_fundingRate)) / absVelocity;
        int256 fundingUntilFlip = _calculateSeriesSum(_fundingRate, _fundingRateVelocity, timeToFlip);
        int256 fundingRateAfterFlip = _fundingRate + (_fundingRateVelocity * int256(timeToFlip));
        int256 fundingUntilBoundary =
            _calculateSeriesSum(fundingRateAfterFlip, _fundingRateVelocity, timeToBoundary - timeToFlip);
        int256 fundingAfterBoundary = _maxFundingRate * int256(_timeElapsed - timeToBoundary);
        return _fundingRate >= 0
            ? (uint256(fundingUntilFlip), uint256(fundingUntilBoundary) + uint256(fundingAfterBoundary))
            : (uint256(fundingUntilBoundary) + uint256(fundingAfterBoundary), uint256(fundingUntilFlip));
    }

    function _calculateForBoundaryCross(
        int256 _fundingRate,
        int256 _fundingRateVelocity,
        int256 _maxFundingRate,
        uint256 _timeElapsed
    ) internal pure returns (uint256 longFees, uint256 shortFees) {
        uint256 absRate = _fundingRate > 0 ? uint256(_fundingRate) : uint256(-_fundingRate);
        uint256 absVelocity = _fundingRateVelocity > 0 ? uint256(_fundingRateVelocity) : uint256(-_fundingRateVelocity);
        uint256 timeToBoundary = (uint256(_maxFundingRate) - absRate) / absVelocity;
        int256 fundingUntilBoundary = _calculateSeriesSum(_fundingRate, _fundingRateVelocity, timeToBoundary);
        int256 fundingAfterBoundary = _maxFundingRate * int256(_timeElapsed - timeToBoundary);
        return _fundingRate >= 0
            ? (uint256(fundingUntilBoundary) + uint256(fundingAfterBoundary), uint256(0))
            : (uint256(0), uint256(fundingUntilBoundary) + uint256(fundingAfterBoundary));
    }

    function _calculateForSignFlip(int256 _fundingRate, int256 _fundingRateVelocity, uint256 _timeElapsed)
        internal
        pure
        returns (uint256 longFees, uint256 shortFees)
    {
        uint256 absRate = _fundingRate > 0 ? uint256(_fundingRate) : uint256(-_fundingRate);
        uint256 absVelocity = _fundingRateVelocity > 0 ? uint256(_fundingRateVelocity) : uint256(-_fundingRateVelocity);
        uint256 timeToFlip = absRate / absVelocity;
        int256 fundingUntilFlip = _calculateSeriesSum(_fundingRate, _fundingRateVelocity, timeToFlip);
        int256 fundingRateAfterFlip = _fundingRate + (_fundingRateVelocity * int256(timeToFlip));
        int256 fundingAfterFlip =
            _calculateSeriesSum(fundingRateAfterFlip, _fundingRateVelocity, _timeElapsed - timeToFlip);
        return _fundingRate >= 0
            ? (uint256(fundingUntilFlip), uint256(fundingAfterFlip))
            : (uint256(fundingAfterFlip), uint256(fundingUntilFlip));
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
        int256 endRate = _fundingRate + (_fundingRateVelocity * int256(_timeElapsed - 1));

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
