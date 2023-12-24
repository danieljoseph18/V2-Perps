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
pragma solidity 0.8.22;

import {MarketStructs} from "../markets/MarketStructs.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";

/// @dev Note, need to handle the case where velocity crosses 0 (pos -> neg or neg -> pos)
library FundingCalculator {
    uint256 constant PRECISION = 1e18;

    /// @dev Calculate the funding rate velocity.
    function calculateFundingRateVelocity(address _market, int256 _skew) external view returns (int256 velocity) {
        uint256 c = (IMarket(_market).maxFundingVelocity() * PRECISION) / IMarket(_market).skewScale();
        int256 skew = _skew;
        velocity = (int256(c) * skew) / int256(PRECISION);
    }

    /// @dev Get the total funding fees accumulated for each side
    function getFundingFees(address _market) external view returns (uint256 longFunding, uint256 shortFunding) {
        IMarket market = IMarket(_market);

        (uint256 longFundingSinceUpdate, uint256 shortFundingSinceUpdate) = _calculateAdjustedFunding(
            address(market),
            market.fundingRate(),
            market.fundingRateVelocity(),
            market.maxFundingRate(),
            market.minFundingRate()
        );

        longFunding = market.longCumulativeFundingFees() + longFundingSinceUpdate;
        shortFunding = market.shortCumulativeFundingFees() + shortFundingSinceUpdate;
    }

    /// @dev Returns fees earned and fees owed in tokens
    function getTotalPositionFees(address _market, MarketStructs.Position memory _position)
        external
        view
        returns (uint256 earned, uint256 owed)
    {
        uint256 shortFees =
            IMarket(_market).shortCumulativeFundingFees() - _position.fundingParams.lastShortCumulativeFunding;
        uint256 longFees =
            IMarket(_market).longCumulativeFundingFees() - _position.fundingParams.lastLongCumulativeFunding;

        uint256 accumulatedFundingEarned;
        uint256 accumulatedFundingOwed;
        if (_position.isLong) {
            accumulatedFundingEarned = shortFees;
            accumulatedFundingOwed = longFees;
        } else {
            accumulatedFundingEarned = longFees;
            accumulatedFundingOwed = shortFees;
        }
        (uint256 feesEarned, uint256 feesOwed) = getFeesSinceLastMarketUpdate(_market, _position.isLong);
        return (
            feesEarned + _position.fundingParams.feesEarned
                + ((accumulatedFundingEarned * _position.positionSize) / PRECISION),
            feesOwed + _position.fundingParams.feesOwed
                + ((accumulatedFundingOwed * _position.positionSize) / PRECISION)
        );
    }

    function getCurrentFundingRate(address _market) external view returns (int256) {
        IMarket market = IMarket(_market);
        uint256 timeElapsed = block.timestamp - market.lastFundingUpdateTime();
        int256 fundingRate = market.fundingRate();
        int256 fundingRateVelocity = market.fundingRateVelocity();

        return fundingRate + (fundingRateVelocity * int256(timeElapsed));
    }

    /// @dev Get the funding fees earned and owed since the last market update
    function getFeesSinceLastMarketUpdate(address _market, bool _isLong)
        public
        view
        returns (uint256 feesEarned, uint256 feesOwed)
    {
        IMarket market = IMarket(_market);

        (uint256 longFees, uint256 shortFees) = _calculateAdjustedFunding(
            _market,
            market.fundingRate(),
            market.fundingRateVelocity(),
            market.maxFundingRate(),
            market.minFundingRate()
        );

        if (_isLong) {
            feesEarned = shortFees;
            feesOwed = longFees;
        } else {
            feesEarned = longFees;
            feesOwed = shortFees;
        }
    }

    /// @dev Adjusts the total funding calculation when max or min limits are reached, or when the sign flips.
    function _calculateAdjustedFunding(
        address _market,
        int256 _fundingRate,
        int256 _fundingRateVelocity,
        int256 _maxFundingRate,
        int256 _minFundingRate
    ) internal view returns (uint256 longFees, uint256 shortFees) {
        uint256 timeElapsed = block.timestamp - IMarket(_market).lastFundingUpdateTime();
        if (timeElapsed == 0) {
            return (0, 0);
        }
        // Calculate final funding rate after time elapsed
        int256 finalFundingRate = _fundingRate + (_fundingRateVelocity * int256(timeElapsed));
        bool flipsSign = (_fundingRate >= 0 && finalFundingRate < 0) || (_fundingRate < 0 && finalFundingRate >= 0);
        bool crossesBoundary = finalFundingRate > _maxFundingRate || finalFundingRate < _minFundingRate;

        if (crossesBoundary && flipsSign) {
            return _calculateForDoubleCross(_fundingRate, _fundingRateVelocity, _maxFundingRate, timeElapsed);
        } else if (crossesBoundary) {
            return _calculateForBoundaryCross(_fundingRate, _fundingRateVelocity, _maxFundingRate, timeElapsed);
        } else if (flipsSign) {
            return _calculateForSignFlip(_fundingRate, _fundingRateVelocity, timeElapsed);
        } else {
            uint256 fee = _calculateSeriesSum(_fundingRate, _fundingRateVelocity, timeElapsed);
            return _fundingRate >= 0 ? (fee, uint256(0)) : (uint256(0), fee);
        }
    }

    /// @dev For calculations when the funding rate crosses the max or min boundary and the sign flips.
    function _calculateForDoubleCross(
        int256 _fundingRate,
        int256 _fundingRateVelocity,
        int256 _maxFundingRate,
        uint256 _timeElapsed
    ) internal pure returns (uint256 longFees, uint256 shortFees) {
        uint256 absRate = _fundingRate >= 0 ? uint256(_fundingRate) : uint256(-_fundingRate);
        uint256 absVelocity = _fundingRateVelocity >= 0 ? uint256(_fundingRateVelocity) : uint256(-_fundingRateVelocity);
        uint256 timeToFlip = absRate / absVelocity;
        uint256 timeToBoundary = _fundingRate >= 0
            ? uint256((_maxFundingRate + _fundingRate)) / absVelocity
            : uint256((_maxFundingRate + -_fundingRate)) / absVelocity;
        uint256 fundingUntilFlip = _calculateSeriesSum(_fundingRate, _fundingRateVelocity, timeToFlip);
        int256 fundingRateAfterFlip = _fundingRate + (_fundingRateVelocity * int256(timeToFlip));
        uint256 fundingUntilBoundary =
            _calculateSeriesSum(fundingRateAfterFlip, _fundingRateVelocity, timeToBoundary - timeToFlip);
        uint256 fundingAfterBoundary = uint256(_maxFundingRate) * (_timeElapsed - timeToBoundary);
        return _fundingRate >= 0
            ? (fundingUntilFlip, fundingUntilBoundary + fundingAfterBoundary)
            : (fundingUntilBoundary + fundingAfterBoundary, fundingUntilFlip);
    }

    /// @dev For calculations when the funding rate crosses the max or min boundary.
    function _calculateForBoundaryCross(
        int256 _fundingRate,
        int256 _fundingRateVelocity,
        int256 _maxFundingRate,
        uint256 _timeElapsed
    ) internal pure returns (uint256 longFees, uint256 shortFees) {
        uint256 absRate = _fundingRate >= 0 ? uint256(_fundingRate) : uint256(-_fundingRate);
        uint256 absVelocity = _fundingRateVelocity >= 0 ? uint256(_fundingRateVelocity) : uint256(-_fundingRateVelocity);
        uint256 timeToBoundary = (uint256(_maxFundingRate) - absRate) / absVelocity;
        uint256 fundingUntilBoundary = _calculateSeriesSum(_fundingRate, _fundingRateVelocity, timeToBoundary);
        uint256 fundingAfterBoundary = uint256(_maxFundingRate) * (_timeElapsed - timeToBoundary);
        return _fundingRate >= 0
            ? (fundingUntilBoundary + fundingAfterBoundary, uint256(0))
            : (uint256(0), fundingUntilBoundary + fundingAfterBoundary);
    }

    /// @dev For calculations when the funding rate sign flips.
    function _calculateForSignFlip(int256 _fundingRate, int256 _fundingRateVelocity, uint256 _timeElapsed)
        internal
        pure
        returns (uint256 longFees, uint256 shortFees)
    {
        uint256 absRate = _fundingRate >= 0 ? uint256(_fundingRate) : uint256(-_fundingRate);
        uint256 absVelocity = _fundingRateVelocity >= 0 ? uint256(_fundingRateVelocity) : uint256(-_fundingRateVelocity);
        uint256 timeToFlip = absRate / absVelocity;
        uint256 fundingUntilFlip = _calculateSeriesSum(_fundingRate, _fundingRateVelocity, timeToFlip);
        int256 fundingRateAfterFlip = _fundingRate + (_fundingRateVelocity * int256(timeToFlip));
        uint256 fundingAfterFlip =
            _calculateSeriesSum(fundingRateAfterFlip, _fundingRateVelocity, _timeElapsed - timeToFlip);
        return _fundingRate >= 0 ? (fundingUntilFlip, fundingAfterFlip) : (fundingAfterFlip, fundingUntilFlip);
    }

    /// @dev Calculates the sum of an arithmetic series with the formula S = n/2(2a + (n-1)d
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
