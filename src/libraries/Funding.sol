//  ,----,------------------------------,------.
//   | ## |                              |    - |
//   | ## |                              |    - |
//   |    |------------------------------|    - |
//   |    ||............................||      |
//   |    ||,-                        -.||      |
//   |    ||___                      ___||    ##|
//   |    ||---`--------------------'---||      |
//   `--mb'|_|______________________==__|`------'

//    ____  ____  ___ _   _ _____ _____ ____
//   |  _ \|  _ \|_ _| \ | |_   _|___ /|  _ \
//   | |_) | |_) || ||  \| | | |   |_ \| |_) |
//   |  __/|  _ < | || |\  | | |  ___) |  _ <
//   |_|   |_| \_\___|_| \_| |_| |____/|_| \_\

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {IMarketMaker} from "../markets/interfaces/IMarketMaker.sol";
import {Market} from "../structs/Market.sol";
import {Position} from "../structs/Position.sol";

/// @dev Library for Funding Related Calculations
library Funding {
    uint256 constant PRECISION = 1e18;

    /// @dev Calculate the funding rate velocity
    /// @dev velocity units = % per second (18 dp)
    function calculateVelocity(address _marketMaker, bytes32 _marketKey, int256 _skew)
        external
        view
        returns (int256 velocity)
    {
        Market.Data memory market = IMarketMaker(_marketMaker).markets(_marketKey);
        uint256 c = (market.config.maxFundingVelocity * PRECISION) / market.config.skewScale;
        int256 skew = _skew;
        velocity = (int256(c) * skew) / int256(PRECISION);
    }

    /// @dev Get the total funding fees accumulated for each side
    /// @notice For External Queries
    function getTotalAccumulatedFees(address _marketMaker, bytes32 _marketKey)
        external
        view
        returns (uint256 longAccumulatedFees, uint256 shortAccumulatedFees)
    {
        Market.Data memory market = IMarketMaker(_marketMaker).markets(_marketKey);

        (uint256 longFundingSinceUpdate, uint256 shortFundingSinceUpdate) = _calculateAdjustedFees(market);

        longAccumulatedFees = market.funding.longCumulativeFundingFees + longFundingSinceUpdate;
        shortAccumulatedFees = market.funding.shortCumulativeFundingFees + shortFundingSinceUpdate;
    }

    /// @dev Returns fees earned and fees owed in tokens
    /// units: fee per index token (18 dp) e.g 0.01e18 = 1%
    /// to charge for a position need to go: index -> usd -> collateral
    function getTotalPositionFees(address _marketMaker, Position.Data memory _position)
        external
        view
        returns (uint256 indexFeeEarned, uint256 indexFeeOwed)
    {
        bytes32 marketKey = keccak256(abi.encode(_position.indexToken));
        Market.Data memory market = IMarketMaker(_marketMaker).markets(marketKey);
        // Get the fees accumulated since the last position update
        uint256 shortAccumulatedFees =
            market.funding.shortCumulativeFundingFees - _position.funding.lastShortCumulativeFunding;
        uint256 longAccumulatedFees =
            market.funding.longCumulativeFundingFees - _position.funding.lastLongCumulativeFunding;
        // Separate Short and Long Fees to Earned and Owed
        uint256 accumulatedFundingEarned;
        uint256 accumulatedFundingOwed;
        if (_position.isLong) {
            accumulatedFundingEarned = shortAccumulatedFees;
            accumulatedFundingOwed = longAccumulatedFees;
        } else {
            accumulatedFundingEarned = longAccumulatedFees;
            accumulatedFundingOwed = shortAccumulatedFees;
        }
        // Get the fees accumulated since the last market update
        (uint256 feesEarnedSinceUpdate, uint256 feesOwedSinceUpdate) =
            getFeesSinceLastMarketUpdate(market, _position.isLong);
        // Calculate the Total Fees Earned and Owed
        indexFeeEarned = feesEarnedSinceUpdate + _position.funding.feesEarned
            + ((accumulatedFundingEarned * _position.positionSize) / PRECISION);
        indexFeeOwed = feesOwedSinceUpdate + _position.funding.feesOwed
            + ((accumulatedFundingOwed * _position.positionSize) / PRECISION);
    }

    // Rate to 18 D.P
    function getCurrentRate(address _marketMaker, bytes32 _marketKey) external view returns (int256) {
        Market.Data memory market = IMarketMaker(_marketMaker).markets(_marketKey);
        uint256 timeElapsed = block.timestamp - market.funding.lastFundingUpdateTime;
        int256 fundingRate = market.funding.fundingRate;
        int256 fundingRateVelocity = market.funding.fundingRateVelocity;
        // currentRate = prevRate + (velocity * timeElapsed)
        return fundingRate + (fundingRateVelocity * int256(timeElapsed));
    }

    /// @dev Get the funding fees earned and owed since the last market update
    /// units: fee per index token (18 dp) e.g 0.01e18 = 1%
    function getFeesSinceLastMarketUpdate(Market.Data memory _market, bool _isLong)
        public
        view
        returns (uint256 feesEarned, uint256 feesOwed)
    {
        (uint256 longFees, uint256 shortFees) = _calculateAdjustedFees(_market);

        if (_isLong) {
            feesEarned = shortFees;
            feesOwed = longFees;
        } else {
            feesEarned = longFees;
            feesOwed = shortFees;
        }
    }

    /// @dev Adjusts the total funding calculation when max or min limits are reached, or when the sign flips.
    /// @dev Mainly for external queries, as lastFundingUpdateTIme is updated before for position edits.
    function _calculateAdjustedFees(Market.Data memory _market)
        internal
        view
        returns (uint256 longFees, uint256 shortFees)
    {
        uint256 timeElapsed = block.timestamp - _market.funding.lastFundingUpdateTime;
        if (timeElapsed == 0) {
            return (0, 0);
        }
        // Calculate which logical path to follow
        int256 finalFundingRate =
            _market.funding.fundingRate + (_market.funding.fundingRateVelocity * int256(timeElapsed));
        bool flipsSign = (_market.funding.fundingRate >= 0 && finalFundingRate < 0)
            || (_market.funding.fundingRate < 0 && finalFundingRate >= 0);
        bool crossesBoundary =
            finalFundingRate > _market.config.maxFundingRate || finalFundingRate < _market.config.minFundingRate;

        // Direct the calculation down a path depending on the case
        if (crossesBoundary && flipsSign) {
            (longFees, shortFees) = _calculateForDoubleCross(
                _market.funding.fundingRate,
                _market.funding.fundingRateVelocity,
                _market.config.maxFundingRate,
                timeElapsed
            );
        } else if (crossesBoundary) {
            (longFees, shortFees) = _calculateForBoundaryCross(
                _market.funding.fundingRate,
                _market.funding.fundingRateVelocity,
                _market.config.maxFundingRate,
                timeElapsed
            );
        } else if (flipsSign) {
            (longFees, shortFees) =
                _calculateForSignFlip(_market.funding.fundingRate, _market.funding.fundingRateVelocity, timeElapsed);
        } else {
            uint256 fee =
                _calculateSeriesSum(_market.funding.fundingRate, _market.funding.fundingRateVelocity, timeElapsed);
            (longFees, shortFees) = _market.funding.fundingRate >= 0 ? (fee, uint256(0)) : (uint256(0), fee);
        }
    }

    /**
     * timeToFlip = |rate| / |velocity|
     * timeToBoundary = (maxRate - |rate|) / |velocity|
     * fundingUntilFlip = sum(rate, velocity, timeToFlip)
     * newFundingRate = rate + (timeToFlip * velocity)
     * fundingUntilBoundary = sum(newFundingRate, velocity, timeToBoundary - timeToFlip)
     * fundingAfterBoundary = maxRate * (timeElapsed - timeToBoundary)
     * totalFunding = fundingUntilBoundary + fundingAfterBoundary
     */

    /// @notice For calculations when the funding rate crosses the max or min boundary and the sign flips.
    function _calculateForDoubleCross(
        int256 _fundingRate,
        int256 _fundingRateVelocity,
        int256 _maxFundingRate,
        uint256 _timeElapsed
    ) internal pure returns (uint256 longFees, uint256 shortFees) {
        uint256 absRate = _fundingRate >= 0 ? uint256(_fundingRate) : uint256(-_fundingRate);
        uint256 absVelocity = _fundingRateVelocity >= 0 ? uint256(_fundingRateVelocity) : uint256(-_fundingRateVelocity);
        // Calculate no. of seconds until sign flip
        uint256 timeToFlip = absRate / absVelocity;
        uint256 fundingDistance =
            _fundingRate >= 0 ? uint256((_maxFundingRate + _fundingRate)) : uint256((_maxFundingRate + -_fundingRate));
        // Calculate no. of seconds until max/min boundary
        uint256 timeToBoundary = fundingDistance / absVelocity;
        // Calculate the funding until the sign flip
        uint256 fundingUntilFlip = _calculateSeriesSum(_fundingRate, _fundingRateVelocity, timeToFlip);
        // Get the new funding rate after the sign flip
        int256 newFundingRate = _fundingRate + (_fundingRateVelocity * int256(timeToFlip));
        // Calculate the funding from the sign flip until the max/min boundary
        uint256 fundingUntilBoundary =
            _calculateSeriesSum(newFundingRate, _fundingRateVelocity, timeToBoundary - timeToFlip);
        // Calculate the funding after the max/min boundary is reached
        uint256 fundingAfterBoundary = uint256(_maxFundingRate) * (_timeElapsed - timeToBoundary);
        // Combine all 3 variables to get the total funding
        (longFees, shortFees) = _fundingRate >= 0
            ? (fundingUntilFlip, fundingUntilBoundary + fundingAfterBoundary)
            : (fundingUntilBoundary + fundingAfterBoundary, fundingUntilFlip);
    }

    /**
     * timeToBoundary = (maxRate - |rate|) / |velocity|
     * fundingUntilBoundary = sum(rate, velocity, timeToBoundary)
     * fundingAfterBoundary = maxRate * (timeElapsed - timeToBoundary)
     * totalFunding = fundingUntilBoundary + fundingAfterBoundary
     */

    /// @notice For calculations when the funding rate crosses the max or min boundary.
    function _calculateForBoundaryCross(
        int256 _fundingRate,
        int256 _fundingRateVelocity,
        int256 _maxFundingRate,
        uint256 _timeElapsed
    ) internal pure returns (uint256 longFees, uint256 shortFees) {
        uint256 absRate = _fundingRate >= 0 ? uint256(_fundingRate) : uint256(-_fundingRate);
        uint256 absVelocity = _fundingRateVelocity >= 0 ? uint256(_fundingRateVelocity) : uint256(-_fundingRateVelocity);
        // Calculate no. of seconds until max/min boundary
        uint256 timeToBoundary = (uint256(_maxFundingRate) - absRate) / absVelocity;
        // Calculate the funding until the max/min boundary
        uint256 fundingUntilBoundary = _calculateSeriesSum(_fundingRate, _fundingRateVelocity, timeToBoundary);
        // Calculate the funding after the max/min boundary is reached
        uint256 fundingAfterBoundary = uint256(_maxFundingRate) * (_timeElapsed - timeToBoundary);
        // Combine both variables to get the total funding
        (longFees, shortFees) = _fundingRate >= 0
            ? (fundingUntilBoundary + fundingAfterBoundary, uint256(0))
            : (uint256(0), fundingUntilBoundary + fundingAfterBoundary);
    }

    /**
     * timeToFlip = |rate| / |velocity|
     * fundingUntilFlip = sum(rate, velocity, timeToFlip)
     * newFundingRate = rate + (timeToFlip * velocity)
     * fundingAfterFlip = sum(newFundingRate, velocity, timeElapsed - timeToFlip)
     */

    /// @notice For calculations when the funding rate sign flips.
    function _calculateForSignFlip(int256 _fundingRate, int256 _fundingRateVelocity, uint256 _timeElapsed)
        internal
        pure
        returns (uint256 longFees, uint256 shortFees)
    {
        uint256 absRate = _fundingRate >= 0 ? uint256(_fundingRate) : uint256(-_fundingRate);
        uint256 absVelocity = _fundingRateVelocity >= 0 ? uint256(_fundingRateVelocity) : uint256(-_fundingRateVelocity);
        // Calculate no. of seconds until sign flip
        uint256 timeToFlip = absRate / absVelocity;

        // If timeToFlip is greater than the time elapsed, set it to the time elapsed
        if (timeToFlip > _timeElapsed) {
            timeToFlip = _timeElapsed;
        }

        // Calculate funding fees before sign flip
        uint256 fundingUntilFlip = _calculateSeriesSum(_fundingRate, _fundingRateVelocity, timeToFlip);
        // Get the new funding rate after the sign flip
        int256 newFundingRate = _fundingRate + (int256(timeToFlip) * _fundingRateVelocity);
        // Calculate funding fees after sign flip
        uint256 fundingAfterFlip = _calculateSeriesSum(newFundingRate, _fundingRateVelocity, _timeElapsed - timeToFlip);
        // Direct the funding towards the relevant sides and return
        if (_fundingRate >= 0) {
            longFees = fundingUntilFlip;
            shortFees = fundingAfterFlip;
        } else {
            longFees = fundingAfterFlip;
            shortFees = fundingUntilFlip;
        }
    }

    /// @notice Calculates the sum of an arithmetic series with the formula S = n/2(2a + (n-1)d
    function _calculateSeriesSum(int256 _fundingRate, int256 _fundingRateVelocity, uint256 _timeElapsed)
        internal
        pure
        returns (uint256)
    {
        if (_timeElapsed == 0) {
            return 0;
        }

        if (_fundingRate == 0 && _fundingRateVelocity == 0) {
            return 0;
        }

        if (_timeElapsed == 1) {
            return _fundingRate > 0 ? uint256(_fundingRate) : uint256(-_fundingRate);
        }

        int256 startRate = _fundingRate;
        int256 endRate = _fundingRate + (_fundingRateVelocity * int256(_timeElapsed - 1));
        int256 sum = int256(_timeElapsed) * (startRate + endRate) / 2;

        return sum > 0 ? uint256(sum) : uint256(-sum);
    }
}
