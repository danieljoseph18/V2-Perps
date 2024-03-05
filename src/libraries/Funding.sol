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
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Order} from "../positions/Order.sol";

/// @dev Library for Funding Related Calculations
library Funding {
    using SafeCast for uint256;
    using SafeCast for int256;
    using SignedMath for int256;

    uint256 constant PRECISION = 1e18;
    uint256 constant ZERO = 0;

    struct FundingState {
        int256 startingFundingRate;
        int256 velocity;
        uint256 longFundingSinceUpdate;
        uint256 shortFundingSinceUpdate;
        int256 finalFundingRate;
        int256 maxFundingRate;
        int256 minFundingRate;
        uint256 absRate;
        uint256 absVelocity;
        uint256 timeElapsed;
        bool crossesBoundary;
        bool flipsSign;
    }

    function calculateSkewUsd(IMarket market, address _indexToken, uint256 _indexPrice, uint256 _indexBaseUnit)
        external
        view
        returns (int256 skewUsd)
    {
        uint256 longOI = MarketUtils.getOpenInterestUsd(market, _indexToken, _indexPrice, _indexBaseUnit, true);
        uint256 shortOI = MarketUtils.getOpenInterestUsd(market, _indexToken, _indexPrice, _indexBaseUnit, false);

        skewUsd = longOI.toInt256() - shortOI.toInt256();
    }

    /// @dev Calculate the funding rate velocity
    /// @dev velocity units = % per second (18 dp)
    function calculateVelocity(IMarket market, address _indexToken, int256 _skew)
        external
        view
        returns (int256 velocity)
    {
        IMarket.FundingConfig memory funding = market.getFundingConfig(_indexToken);
        uint256 c = mulDiv(funding.maxVelocity, PRECISION, funding.skewScale);
        velocity = mulDivSigned(c.toInt256(), _skew, PRECISION.toInt256());
    }

    /// @dev Get the total funding fees accumulated for each side
    /// @notice For External Queries
    // @audit - math
    function getTotalAccumulatedFees(IMarket market, address _indexToken)
        external
        view
        returns (uint256 longAccumulatedFees, uint256 shortAccumulatedFees)
    {
        (uint256 longFundingSinceUpdate, uint256 shortFundingSinceUpdate) =
            _calculateFeesSinceLastUpdate(market, _indexToken);

        longAccumulatedFees = market.getCumulativeFundingFees(_indexToken, true) + longFundingSinceUpdate;
        shortAccumulatedFees = market.getCumulativeFundingFees(_indexToken, false) + shortFundingSinceUpdate;
    }

    /// @dev Returns fees earned and fees owed in collateral tokens
    /// units: fee per index token (18 dp) e.g 0.01e18 = 1%
    function getTotalPositionFees(Position.Data memory _position, Order.ExecutionState memory _state)
        external
        view
        returns (uint256 collateralFeeEarned, uint256 collateralFeeOwed)
    {
        // Get the fees accumulated since the last position update
        uint256 shortAccumulatedFees = _state.market.getCumulativeFundingFees(_position.indexToken, false)
            - _position.fundingParams.lastShortCumulativeFunding;
        uint256 longAccumulatedFees = _state.market.getCumulativeFundingFees(_position.indexToken, true)
            - _position.fundingParams.lastLongCumulativeFunding;
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
        uint256 indexFeeEarned =
            _position.fundingParams.feesEarned + mulDiv(accumulatedFundingEarned, _position.positionSize, PRECISION);
        uint256 indexFeeOwed =
            _position.fundingParams.feesOwed + mulDiv(accumulatedFundingOwed, _position.positionSize, PRECISION);
        // Flag avoids unnecessary heavy computation
        if (_state.market.getLastFundingUpdate(_position.indexToken) != block.timestamp) {
            (uint256 feesEarnedSinceUpdate, uint256 feesOwedSinceUpdate) =
                getFeesSinceLastMarketUpdate(_state.market, _position.indexToken, _position.isLong);
            // Calculate the Total Fees Earned and Owed
            indexFeeEarned += feesEarnedSinceUpdate;
            indexFeeOwed += feesOwedSinceUpdate;
        }
        // Convert Fees to USD
        uint256 feeEarnedUsd = mulDiv(indexFeeEarned, _state.indexPrice, _state.indexBaseUnit);
        uint256 feeOwedUsd = mulDiv(indexFeeOwed, _state.indexPrice, _state.indexBaseUnit);
        // Convert Fees to Collateral
        collateralFeeEarned = mulDiv(feeEarnedUsd, _state.collateralBaseUnit, _state.collateralPrice);
        collateralFeeOwed = mulDiv(feeOwedUsd, _state.collateralBaseUnit, _state.collateralPrice);
    }

    // Rate to 18 D.P
    function getCurrentRate(IMarket market, address _indexToken) external view returns (int256) {
        uint256 timeElapsed = block.timestamp - market.getLastFundingUpdate(_indexToken);
        (int256 fundingRate, int256 fundingRateVelocity) = market.getFundingRates(_indexToken);
        // currentRate = prevRate + (velocity * timeElapsed)
        return fundingRate + (fundingRateVelocity * int256(timeElapsed));
    }

    /// @dev Get the funding fees earned and owed since the last market update
    /// units: fee per index token (18 dp) e.g 0.01e18 = 1%
    function getFeesSinceLastMarketUpdate(IMarket market, address _indexToken, bool _isLong)
        public
        view
        returns (uint256 feesEarned, uint256 feesOwed)
    {
        (uint256 longFees, uint256 shortFees) = _calculateFeesSinceLastUpdate(market, _indexToken);

        if (_isLong) {
            feesEarned = shortFees;
            feesOwed = longFees;
        } else {
            feesEarned = longFees;
            feesOwed = shortFees;
        }
    }

    /**
     * The Funding Rate is changing by fundingVelocity every second.
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
    function _calculateFeesSinceLastUpdate(IMarket market, address _indexToken)
        internal
        view
        returns (uint256 longFees, uint256 shortFees)
    {
        FundingState memory state;
        IMarket.FundingConfig memory funding = market.getFundingConfig(_indexToken);

        // If no update, return
        state.timeElapsed = block.timestamp - market.getLastFundingUpdate(_indexToken);

        if (state.timeElapsed == 0) {
            return (0, 0);
        }
        // state Variables
        state.maxFundingRate = funding.maxRate;
        state.minFundingRate = funding.minRate;
        (state.startingFundingRate, state.velocity) = market.getFundingRates(_indexToken);

        if (state.velocity == 0) {
            if (state.startingFundingRate > 0) {
                return (state.startingFundingRate.abs() * state.timeElapsed, 0);
            } else {
                return (0, state.startingFundingRate.abs() * state.timeElapsed);
            }
        }

        // If Funding Rate Already at Max and Velocity is Positive
        if (state.startingFundingRate == state.maxFundingRate && state.velocity >= 0) {
            return (state.maxFundingRate.abs() * state.timeElapsed, 0);
        }

        // If Funding Rate Already at Min and Velocity is Negative
        if (state.startingFundingRate == state.minFundingRate && state.velocity <= 0) {
            return (0, state.minFundingRate.abs() * state.timeElapsed);
        }

        state.finalFundingRate = state.startingFundingRate + (state.velocity * state.timeElapsed.toInt256());
        // Calculate which logical path to follow
        if (state.startingFundingRate == 0 || state.finalFundingRate == 0) {
            // If the starting / ending rate is 0, there's no sign flip
            state.flipsSign = false;
        } else {
            // Check for Sign Flip
            bool startRatePositive = state.startingFundingRate > 0;
            bool finalRatePositive = state.finalFundingRate > 0;
            state.flipsSign = startRatePositive != finalRatePositive;
        }

        bool crossesBoundary =
            state.finalFundingRate > state.maxFundingRate || state.finalFundingRate < state.minFundingRate;
        // Direct the calculation down a path depending on the case
        if (crossesBoundary && state.flipsSign) {
            return _calculateForDoubleCross(state);
        } else if (crossesBoundary) {
            return _calculateForBoundaryCross(state);
        } else if (state.flipsSign) {
            return _calculateForSignFlip(state);
        } else {
            uint256 fee = _calculateSeriesSum(state.startingFundingRate, state.velocity, state.timeElapsed);
            // If Rate started at 0, fees are on side of velocity
            if (state.startingFundingRate == 0) {
                if (state.velocity > 0) {
                    return (fee, ZERO);
                } else {
                    return (ZERO, fee);
                }
            } else if (state.startingFundingRate > 0) {
                return (fee, ZERO);
            } else {
                return (ZERO, fee);
            }
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
    // @audit - review math on divs - should they be ceil or floor?
    function _calculateForDoubleCross(FundingState memory _state)
        internal
        pure
        returns (uint256 longFees, uint256 shortFees)
    {
        // Invariant Check for 0 starting rate
        require(_state.startingFundingRate != 0, "Funding: Invalid Double Cross");
        _state.absRate = _state.startingFundingRate.abs();
        _state.absVelocity = _state.velocity.abs();
        // Calculate no. of seconds until sign flip
        uint256 timeToFlip = Math.ceilDiv(_state.absRate, _state.absVelocity);
        // As sign flips and a boundary is crossed, distance is always 1 whole side + the delta
        // from the first side to 0
        uint256 fundingDistance = _state.maxFundingRate.abs() + _state.startingFundingRate.abs();
        // Calculate no. of seconds until max/min boundary
        uint256 timeToBoundary = Math.ceilDiv(fundingDistance, _state.absVelocity);
        // Calculate the funding until the sign flip
        uint256 fundingUntilFlip = _calculateSeriesSum(_state.startingFundingRate, _state.velocity, timeToFlip);
        // Get the new funding rate after the sign flip
        int256 newFundingRate = _state.startingFundingRate + (_state.velocity * timeToFlip.toInt256());
        // Calculate the funding from the sign flip until the max/min boundary
        uint256 fundingUntilBoundary = _calculateSeriesSum(newFundingRate, _state.velocity, timeToBoundary - timeToFlip);
        // Calculate the funding after the max/min boundary is reached
        uint256 fundingAfterBoundary = _state.maxFundingRate.toUint256() * (_state.timeElapsed - timeToBoundary);
        // Combine all 3 variables to get the total funding
        (longFees, shortFees) = _state.startingFundingRate > 0
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
    function _calculateForBoundaryCross(FundingState memory _state)
        internal
        pure
        returns (uint256 longFees, uint256 shortFees)
    {
        uint256 absRate = _state.startingFundingRate.abs();
        uint256 absVelocity = _state.velocity.abs();
        // Calculate no. of seconds until max/min boundary - @audit math
        uint256 timeToBoundary = Math.ceilDiv(_state.maxFundingRate.abs() - absRate, absVelocity);
        // Calculate the funding until the max/min boundary
        uint256 fundingUntilBoundary = _calculateSeriesSum(_state.startingFundingRate, _state.velocity, timeToBoundary);
        // Calculate the funding after the max/min boundary is reached
        uint256 fundingAfterBoundary = _state.maxFundingRate.abs() * (_state.timeElapsed - timeToBoundary);
        // Combine both variables to get the total funding
        if (_state.startingFundingRate == 0) {
            if (_state.velocity > 0) {
                return (fundingUntilBoundary + fundingAfterBoundary, ZERO);
            } else {
                return (ZERO, fundingUntilBoundary + fundingAfterBoundary);
            }
        } else {
            if (_state.startingFundingRate > 0) {
                return (fundingUntilBoundary + fundingAfterBoundary, ZERO);
            } else {
                return (ZERO, fundingUntilBoundary + fundingAfterBoundary);
            }
        }
    }

    /**
     * timeToFlip = |rate| / |velocity|
     * fundingUntilFlip = sum(rate, velocity, timeToFlip)
     * newFundingRate = rate + (timeToFlip * velocity)
     * fundingAfterFlip = sum(newFundingRate, velocity, timeElapsed - timeToFlip)
     */

    /// @notice For calculations when the funding rate sign flips.
    function _calculateForSignFlip(FundingState memory _state)
        internal
        pure
        returns (uint256 longFees, uint256 shortFees)
    {
        // Invariant Check for 0 starting rate
        require(_state.startingFundingRate != 0, "Funding: Invalid Sign Flip");
        _state.absRate = _state.startingFundingRate.abs();
        _state.absVelocity = _state.velocity.abs();
        // Calculate no. of seconds until sign flip
        uint256 timeToFlip = Math.ceilDiv(_state.absRate, _state.absVelocity);
        require(timeToFlip <= _state.timeElapsed, "Funding: Invalid Sign Flip");

        // Calculate funding fees before sign flip
        uint256 fundingUntilFlip = _calculateSeriesSum(_state.startingFundingRate, _state.velocity, timeToFlip);
        // Get the new funding rate after the sign flip
        int256 newFundingRate = _state.startingFundingRate + (timeToFlip.toInt256() * _state.velocity);
        // Calculate funding fees after sign flip
        uint256 fundingAfterFlip = _calculateSeriesSum(newFundingRate, _state.velocity, _state.timeElapsed - timeToFlip);
        // Direct the funding towards the relevant sides and return
        if (_state.startingFundingRate > 0) {
            longFees = fundingUntilFlip;
            shortFees = fundingAfterFlip;
        } else {
            longFees = fundingAfterFlip;
            shortFees = fundingUntilFlip;
        }
    }

    /// @notice Calculates the sum of an arithmetic series with the formula S = n/2 * (2a + (n - 1)d)
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
            return _fundingRate.abs();
        }
        int256 time = _timeElapsed.toInt256();
        int256 endRate = _fundingRate + (_fundingRateVelocity * (time - 1));
        int256 sum = mulDivSigned(time, _fundingRate + endRate, 2);

        return sum.abs();
    }
}
