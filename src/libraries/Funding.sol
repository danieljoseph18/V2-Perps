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

import {MarketUtils} from "../markets/MarketUtils.sol";
import {Position} from "../positions/Position.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {mulDiv, mulDivSigned} from "@prb/math/Common.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SD59x18, sd, unwrap, gt, gte, eq, ZERO, lt} from "@prb/math/SD59x18.sol";
import {UD60x18, ud, eq, unwrap, gt, ZERO as UD_ZERO} from "@prb/math/UD60x18.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {Test, console, console2} from "forge-std/Test.sol";

/// @dev Library for Funding Related Calculations
library Funding {
    using SafeCast for uint256;
    using SafeCast for int256;
    using SignedMath for int256;

    uint256 constant PRECISION = 1e18;

    struct FundingCache {
        SD59x18 startingFundingRate;
        SD59x18 velocity;
        UD60x18 longFundingSinceUpdate;
        UD60x18 shortFundingSinceUpdate;
        SD59x18 finalFundingRate;
        SD59x18 maxFundingRate;
        SD59x18 minFundingRate;
        UD60x18 absRate;
        UD60x18 absVelocity;
        UD60x18 timeElapsed;
        bool crossesBoundary;
        bool flipsSign;
    }

    function calculateSkewUsd(IMarket market, uint256 _indexPrice, uint256 _indexBaseUnit)
        external
        view
        returns (int256 skewUsd)
    {
        uint256 longOI = MarketUtils.getOpenInterestUsd(market, _indexPrice, _indexBaseUnit, true);
        uint256 shortOI = MarketUtils.getOpenInterestUsd(market, _indexPrice, _indexBaseUnit, false);

        skewUsd = longOI.toInt256() - shortOI.toInt256();
    }

    /// @dev Calculate the funding rate velocity
    /// @dev velocity units = % per second (18 dp)
    function calculateVelocity(IMarket market, int256 _skew) external view returns (int256 velocity) {
        IMarket.FundingConfig memory funding = market.getFundingConfig();
        console.log("Max Velocity: ", funding.maxVelocity);
        console.log("Skew Scale: ", funding.skewScale);
        uint256 c = mulDiv(funding.maxVelocity, PRECISION, funding.skewScale);
        console.log("C: ", c);
        velocity = mulDivSigned(c.toInt256(), _skew, PRECISION.toInt256());
        console2.log("Velocity: ", velocity);
    }

    /// @dev Get the total funding fees accumulated for each side
    /// @notice For External Queries
    // @audit - math
    function getTotalAccumulatedFees(IMarket market)
        external
        view
        returns (uint256 longAccumulatedFees, uint256 shortAccumulatedFees)
    {
        (UD60x18 longFundingSinceUpdate, UD60x18 shortFundingSinceUpdate) = _calculateFeesSinceLastUpdate(market);

        longAccumulatedFees = market.longCumulativeFundingFees() + unwrap(longFundingSinceUpdate);
        shortAccumulatedFees = market.shortCumulativeFundingFees() + unwrap(shortFundingSinceUpdate);
    }

    /// @dev Returns fees earned and fees owed in tokens
    /// units: fee per index token (18 dp) e.g 0.01e18 = 1%
    /// to charge for a position need to go: index -> usd -> collateral
    function getTotalPositionFees(IMarket market, Position.Data memory _position)
        external
        view
        returns (uint256 indexFeeEarned, uint256 indexFeeOwed)
    {
        // Get the fees accumulated since the last position update
        uint256 shortAccumulatedFees =
            market.shortCumulativeFundingFees() - _position.fundingParams.lastShortCumulativeFunding;
        uint256 longAccumulatedFees =
            market.longCumulativeFundingFees() - _position.fundingParams.lastLongCumulativeFunding;
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
        indexFeeEarned =
            _position.fundingParams.feesEarned + mulDiv(accumulatedFundingEarned, _position.positionSize, PRECISION);
        indexFeeOwed =
            _position.fundingParams.feesOwed + mulDiv(accumulatedFundingOwed, _position.positionSize, PRECISION);
        // Flag avoids unnecessary heavy computation
        if (market.lastFundingUpdate() != block.timestamp) {
            (uint256 feesEarnedSinceUpdate, uint256 feesOwedSinceUpdate) =
                getFeesSinceLastMarketUpdate(market, _position.isLong);
            // Calculate the Total Fees Earned and Owed
            indexFeeEarned += feesEarnedSinceUpdate;
            indexFeeOwed += feesOwedSinceUpdate;
        }
    }

    // Rate to 18 D.P
    function getCurrentRate(IMarket market) external view returns (int256) {
        uint256 timeElapsed = block.timestamp - market.lastFundingUpdate();
        int256 fundingRate = market.fundingRate();
        int256 fundingRateVelocity = market.fundingRateVelocity();
        // currentRate = prevRate + (velocity * timeElapsed)
        return fundingRate + (fundingRateVelocity * int256(timeElapsed));
    }

    /// @dev Get the funding fees earned and owed since the last market update
    /// units: fee per index token (18 dp) e.g 0.01e18 = 1%
    function getFeesSinceLastMarketUpdate(IMarket market, bool _isLong)
        public
        view
        returns (uint256 feesEarned, uint256 feesOwed)
    {
        (UD60x18 longFees, UD60x18 shortFees) = _calculateFeesSinceLastUpdate(market);

        if (_isLong) {
            feesEarned = unwrap(shortFees);
            feesOwed = unwrap(longFees);
        } else {
            feesEarned = unwrap(longFees);
            feesOwed = unwrap(shortFees);
        }
    }

    /**
     * The Funding Rate is changing by fundingVelocity every second.
     *
     * This is mainly for external queries, as lastUpdate is updated before this
     * point for standard position edits.
     *
     * This function calculates the funding fees accumulated for each side, by summing
     * the funding rate and velocity over the time since the last update.
     *
     * It uses a series sum to accomplish this. For Example, if Velocity is 0.1 and the Rate is 0,
     * and we want to calculate the funding fees accumulated over a 10 second period:
     * Second 1: Funding Rate = 0.1, accumulated long fees = 0.1
     * Second 2: Funding Rate = 0.2, accumulated long fees = 0.3
     * Second 3: Funding Rate = 0.3, accumulated long fees = 0.6
     * ...
     * Second 10: Funding Rate = 1, accumulated long fees = 5.5
     *
     * To calculate this, a simple arithmetic series sum is used: S = n/2(2a + (n-1)d
     *
     * In the cases where the funding rate is already at a boundary and the velocity is
     * moving in the trajectory of the boundary, the cumulative funding is simply calculated
     * as the boundary rate * timeElapsed.
     *
     * The function is designed to account for a few more complex edge cases:
     *
     * 1. When the funding rate crosses the max or min boundary.
     *
     * To prevent funding getting out of control, a maximum and minimum boundary is set.
     * Once this boundary is crossed, the funding rate stops increasing and remains at the boundary.
     *
     * For Example, if the max boundary is 0.03 and the velocity is 0.1, and the current rate is 0.02,
     * the funding rate will remain at 0.03 until the velocity changes direction.
     *
     * 2. The velocity causes the funding rate to flip signs from positive to negative or vice versa.
     *
     * This will cause one side to stop accumulating fees and the other to start accumulating fees.
     *
     * Here we calculate the funding accumulated before the sign flipped and attribute it to one side,
     * and then calculate the funding accumulated after the sign flipped and attribute it to the other side.
     *
     * 3. Both Cases Combined
     *
     * In this case we calculate the funding accumulated before the sign flipped and attribute it to one side
     *
     * For the other side, we know that the funding rate will increase in a series sum, then eventually
     * reach the boundary and stop increasing.
     *
     * Therefore, we calculate the funding from when the sign flipped, until when the boundary was crossed.
     *
     * Then we calculate the amount of time after the boundary was crossed.
     *
     * We can then add the funding from sign flip -> boundary, with (time at boundary * max rate) to
     * get the total funding accumulated.
     *
     */
    function _calculateFeesSinceLastUpdate(IMarket market)
        internal
        view
        returns (UD60x18 longFees, UD60x18 shortFees)
    {
        FundingCache memory cache;
        IMarket.FundingConfig memory funding = market.getFundingConfig();

        // If no update, return
        uint256 timeElapsed = block.timestamp - market.lastFundingUpdate();
        if (timeElapsed == 0) {
            return (UD_ZERO, UD_ZERO);
        }
        // Cache Variables
        cache.maxFundingRate = sd(funding.maxRate);
        cache.minFundingRate = sd(funding.minRate);
        cache.startingFundingRate = sd(market.fundingRate());
        cache.velocity = sd(market.fundingRateVelocity());

        // If Funding Rate Already at Max and Velocity is Positive
        if (cache.startingFundingRate == cache.maxFundingRate && gt(cache.velocity, ZERO)) {
            return (ud(unwrap(cache.maxFundingRate).toUint256()).mul(ud(timeElapsed)), UD_ZERO);
        }

        // If Funding Rate Already at Min and Velocity is Negative
        if (cache.startingFundingRate == cache.minFundingRate && lt(cache.velocity, ZERO)) {
            return (UD_ZERO, ud(unwrap(cache.minFundingRate).toUint256()).mul(ud(timeElapsed)));
        }

        cache.finalFundingRate = cache.startingFundingRate.add(cache.velocity.mul(sd(timeElapsed.toInt256())));
        // Calculate which logical path to follow
        if (eq(cache.startingFundingRate, ZERO) || eq(cache.finalFundingRate, ZERO)) {
            // If the starting / ending rate is 0, there's no sign flip
            cache.flipsSign = false;
        } else {
            // Check for Sign Flip
            bool startRatePositive = gt(cache.startingFundingRate, ZERO);
            bool finalRatePositive = gt(cache.finalFundingRate, ZERO);
            cache.flipsSign = startRatePositive != finalRatePositive;
        }

        bool crossesBoundary =
            gt(cache.finalFundingRate, cache.maxFundingRate) || lt(cache.finalFundingRate, cache.minFundingRate);
        // Direct the calculation down a path depending on the case
        cache.timeElapsed = ud(timeElapsed);
        if (crossesBoundary && cache.flipsSign) {
            (longFees, shortFees) = _calculateForDoubleCross(cache);
        } else if (crossesBoundary) {
            (longFees, shortFees) = _calculateForBoundaryCross(cache);
        } else if (cache.flipsSign) {
            (longFees, shortFees) = _calculateForSignFlip(cache);
        } else {
            UD60x18 fee = _calculateSeriesSum(cache.startingFundingRate, cache.velocity, cache.timeElapsed);
            (longFees, shortFees) = gte(cache.startingFundingRate, ZERO) ? (fee, UD_ZERO) : (UD_ZERO, fee);
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
    function _calculateForDoubleCross(FundingCache memory _cache)
        internal
        pure
        returns (UD60x18 longFees, UD60x18 shortFees)
    {
        _cache.absRate = ud(unwrap(_cache.startingFundingRate).abs());
        _cache.absVelocity = ud(unwrap(_cache.velocity).abs());
        // Calculate no. of seconds until sign flip
        UD60x18 timeToFlip = _cache.absRate.div(_cache.absVelocity);
        UD60x18 fundingDistance =
            ud(unwrap(_cache.maxFundingRate).abs()).add(ud(unwrap(_cache.startingFundingRate).abs()));
        // Calculate no. of seconds until max/min boundary
        UD60x18 timeToBoundary = fundingDistance.div(_cache.absVelocity);
        // Calculate the funding until the sign flip
        UD60x18 fundingUntilFlip = _calculateSeriesSum(_cache.startingFundingRate, _cache.velocity, timeToFlip);
        // Get the new funding rate after the sign flip
        SD59x18 newFundingRate = _cache.startingFundingRate.add(_cache.velocity.mul(sd(unwrap(timeToFlip).toInt256())));
        // Calculate the funding from the sign flip until the max/min boundary
        UD60x18 fundingUntilBoundary = _calculateSeriesSum(newFundingRate, _cache.velocity, timeToBoundary - timeToFlip);
        // Calculate the funding after the max/min boundary is reached
        UD60x18 fundingAfterBoundary =
            ud(unwrap(_cache.maxFundingRate).toUint256()).mul(_cache.timeElapsed.sub(timeToBoundary));
        // Combine all 3 variables to get the total funding
        (longFees, shortFees) = gte(_cache.startingFundingRate, ZERO)
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
    function _calculateForBoundaryCross(FundingCache memory _cache)
        internal
        pure
        returns (UD60x18 longFees, UD60x18 shortFees)
    {
        UD60x18 absRate = ud(unwrap(_cache.startingFundingRate).abs());
        UD60x18 absVelocity = ud(unwrap(_cache.velocity).abs());
        // Calculate no. of seconds until max/min boundary
        UD60x18 timeToBoundary = (ud(unwrap(_cache.maxFundingRate).abs()).sub(absRate)).div(absVelocity);
        // Calculate the funding until the max/min boundary
        UD60x18 fundingUntilBoundary = _calculateSeriesSum(_cache.startingFundingRate, _cache.velocity, timeToBoundary);
        // Calculate the funding after the max/min boundary is reached
        UD60x18 fundingAfterBoundary =
            ud(unwrap(_cache.maxFundingRate).abs()).mul(_cache.timeElapsed.sub(timeToBoundary));
        // Combine both variables to get the total funding
        (longFees, shortFees) = gte(_cache.startingFundingRate, ZERO)
            ? (fundingUntilBoundary.add(fundingAfterBoundary), UD_ZERO)
            : (UD_ZERO, fundingUntilBoundary.add(fundingAfterBoundary));
    }

    /**
     * timeToFlip = |rate| / |velocity|
     * fundingUntilFlip = sum(rate, velocity, timeToFlip)
     * newFundingRate = rate + (timeToFlip * velocity)
     * fundingAfterFlip = sum(newFundingRate, velocity, timeElapsed - timeToFlip)
     */

    /// @notice For calculations when the funding rate sign flips.
    function _calculateForSignFlip(FundingCache memory _cache)
        internal
        pure
        returns (UD60x18 longFees, UD60x18 shortFees)
    {
        _cache.absRate = ud(unwrap(_cache.startingFundingRate).abs());
        _cache.absVelocity = ud(unwrap(_cache.velocity).abs());
        // Calculate no. of seconds until sign flip
        UD60x18 timeToFlip = _cache.absRate.div(_cache.absVelocity);

        // If timeToFlip is greater than the time elapsed, set it to the time elapsed
        if (gt(timeToFlip, _cache.timeElapsed)) {
            timeToFlip = _cache.timeElapsed;
        }

        // Calculate funding fees before sign flip
        UD60x18 fundingUntilFlip = _calculateSeriesSum(_cache.startingFundingRate, _cache.velocity, timeToFlip);
        // Get the new funding rate after the sign flip
        SD59x18 newFundingRate = _cache.startingFundingRate.add(sd(unwrap(timeToFlip).toInt256()).mul(_cache.velocity));
        // Calculate funding fees after sign flip
        UD60x18 fundingAfterFlip =
            _calculateSeriesSum(newFundingRate, _cache.velocity, _cache.timeElapsed.sub(timeToFlip));
        // Direct the funding towards the relevant sides and return
        if (gte(_cache.startingFundingRate, ZERO)) {
            longFees = fundingUntilFlip;
            shortFees = fundingAfterFlip;
        } else {
            longFees = fundingAfterFlip;
            shortFees = fundingUntilFlip;
        }
    }

    /// @notice Calculates the sum of an arithmetic series with the formula S = n/2(2a + (n-1)d
    function _calculateSeriesSum(SD59x18 _fundingRate, SD59x18 _fundingRateVelocity, UD60x18 _timeElapsed)
        internal
        pure
        returns (UD60x18)
    {
        if (eq(_timeElapsed, UD_ZERO)) {
            return UD_ZERO;
        }

        if (eq(_fundingRate, ZERO) && eq(_fundingRateVelocity, ZERO)) {
            return UD_ZERO;
        }

        if (eq(_timeElapsed, ud(1))) {
            return ud(unwrap(_fundingRate).abs());
        }
        SD59x18 time = sd(unwrap(_timeElapsed).toInt256());
        SD59x18 endRate = _fundingRate.add(_fundingRateVelocity.mul(time.sub(sd(1))));
        SD59x18 sum = time.mul(_fundingRate.add(endRate)).div(sd(2));

        return ud(unwrap(sum).abs());
    }
}
