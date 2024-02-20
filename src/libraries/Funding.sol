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

/// @dev Library for Funding Related Calculations
library Funding {
    using SafeCast for uint256;
    using SafeCast for int256;
    using SignedMath for int256;

    uint256 constant PRECISION = 1e18;

    struct FundingCache {
        SD59x18 fundingRate;
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
        uint256 c = mulDiv(funding.maxVelocity, PRECISION, funding.skewScale);
        velocity = mulDivSigned(c.toInt256(), _skew, PRECISION.toInt256());
    }

    /// @dev Get the total funding fees accumulated for each side
    /// @notice For External Queries
    // @audit - math
    function getTotalAccumulatedFees(IMarket market)
        external
        view
        returns (uint256 longAccumulatedFees, uint256 shortAccumulatedFees)
    {
        (UD60x18 longFundingSinceUpdate, UD60x18 shortFundingSinceUpdate) = _calculateAdjustedFees(market);

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
        (UD60x18 longFees, UD60x18 shortFees) = _calculateAdjustedFees(market);

        if (_isLong) {
            feesEarned = unwrap(shortFees);
            feesOwed = unwrap(longFees);
        } else {
            feesEarned = unwrap(longFees);
            feesOwed = unwrap(shortFees);
        }
    }

    /// @dev Adjusts the total funding calculation when max or min limits are reached, or when the sign flips.
    /// @dev Mainly for external queries, as lastUpdate is updated before for position edits.
    function _calculateAdjustedFees(IMarket market) internal view returns (UD60x18 longFees, UD60x18 shortFees) {
        FundingCache memory cache;
        IMarket.FundingConfig memory funding = market.getFundingConfig();

        uint256 timeElapsed = block.timestamp - market.lastFundingUpdate();
        if (timeElapsed == 0) {
            return (UD_ZERO, UD_ZERO);
        }
        cache.fundingRate = sd(market.fundingRate());
        cache.velocity = sd(market.fundingRateVelocity());
        // Calculate which logical path to follow
        cache.finalFundingRate = cache.fundingRate + (cache.velocity.mul(sd(timeElapsed.toInt256())));
        cache.flipsSign = (
            gte(cache.fundingRate, ZERO) && lt(cache.finalFundingRate, ZERO)
                || lt(cache.fundingRate, ZERO) && gte(cache.finalFundingRate, ZERO)
        );
        cache.maxFundingRate = sd(funding.maxRate);
        cache.minFundingRate = sd(funding.minRate);
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
            UD60x18 fee = _calculateSeriesSum(cache.fundingRate, cache.velocity, cache.timeElapsed);
            (longFees, shortFees) = gte(cache.fundingRate, ZERO) ? (fee, ud(0)) : (ud(0), fee);
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
        _cache.absRate = ud(unwrap(_cache.fundingRate).abs());
        _cache.absVelocity = ud(unwrap(_cache.velocity).abs());
        // Calculate no. of seconds until sign flip
        UD60x18 timeToFlip = _cache.absRate.div(_cache.absVelocity);
        UD60x18 fundingDistance = ud(unwrap(_cache.maxFundingRate).abs()).add(ud(unwrap(_cache.fundingRate).abs()));
        // Calculate no. of seconds until max/min boundary
        UD60x18 timeToBoundary = fundingDistance.div(_cache.absVelocity);
        // Calculate the funding until the sign flip
        UD60x18 fundingUntilFlip = _calculateSeriesSum(_cache.fundingRate, _cache.velocity, timeToFlip);
        // Get the new funding rate after the sign flip
        SD59x18 newFundingRate = _cache.fundingRate.add(_cache.velocity.mul(sd(unwrap(timeToFlip).toInt256())));
        // Calculate the funding from the sign flip until the max/min boundary
        UD60x18 fundingUntilBoundary = _calculateSeriesSum(newFundingRate, _cache.velocity, timeToBoundary - timeToFlip);
        // Calculate the funding after the max/min boundary is reached
        UD60x18 fundingAfterBoundary =
            ud(unwrap(_cache.maxFundingRate).toUint256()).mul(_cache.timeElapsed.sub(timeToBoundary));
        // Combine all 3 variables to get the total funding
        (longFees, shortFees) = gte(_cache.fundingRate, ZERO)
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
        UD60x18 absRate = ud(unwrap(_cache.fundingRate).abs());
        UD60x18 absVelocity = ud(unwrap(_cache.velocity).abs());
        // Calculate no. of seconds until max/min boundary
        UD60x18 timeToBoundary = (ud(unwrap(_cache.maxFundingRate).abs()).sub(absRate)).div(absVelocity);
        // Calculate the funding until the max/min boundary
        UD60x18 fundingUntilBoundary = _calculateSeriesSum(_cache.fundingRate, _cache.velocity, timeToBoundary);
        // Calculate the funding after the max/min boundary is reached
        UD60x18 fundingAfterBoundary =
            ud(unwrap(_cache.maxFundingRate).abs()).mul(_cache.timeElapsed.sub(timeToBoundary));
        // Combine both variables to get the total funding
        (longFees, shortFees) = gte(_cache.fundingRate, ZERO)
            ? (fundingUntilBoundary.add(fundingAfterBoundary), ud(0))
            : (ud(0), fundingUntilBoundary.add(fundingAfterBoundary));
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
        _cache.absRate = ud(unwrap(_cache.fundingRate).abs());
        _cache.absVelocity = ud(unwrap(_cache.velocity).abs());
        // Calculate no. of seconds until sign flip
        UD60x18 timeToFlip = _cache.absRate.div(_cache.absVelocity);

        // If timeToFlip is greater than the time elapsed, set it to the time elapsed
        if (gt(timeToFlip, _cache.timeElapsed)) {
            timeToFlip = _cache.timeElapsed;
        }

        // Calculate funding fees before sign flip
        UD60x18 fundingUntilFlip = _calculateSeriesSum(_cache.fundingRate, _cache.velocity, timeToFlip);
        // Get the new funding rate after the sign flip
        SD59x18 newFundingRate = _cache.fundingRate.add(sd(unwrap(timeToFlip).toInt256()).mul(_cache.velocity));
        // Calculate funding fees after sign flip
        UD60x18 fundingAfterFlip =
            _calculateSeriesSum(newFundingRate, _cache.velocity, _cache.timeElapsed.sub(timeToFlip));
        // Direct the funding towards the relevant sides and return
        if (gte(_cache.fundingRate, ZERO)) {
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
            return ud(0);
        }

        if (eq(_fundingRate, ZERO) && eq(_fundingRateVelocity, ZERO)) {
            return ud(0);
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
