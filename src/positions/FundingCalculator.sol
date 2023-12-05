// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {MarketStructs} from "../markets/MarketStructs.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";

library FundingCalculator {
    /// @dev 18 D.P -> 0.33 = 0.33e18
    function calculateFundingRateVelocity(address _market, int256 _skew) external view returns (int256) {
        uint256 c = (IMarket(_market).maxFundingVelocity() * 1e18) / IMarket(_market).skewScale();
        int256 skew = _skew;
        return int256(c) * skew;
    }

    /// @dev Get the Funding Fees Accumulated Since Last Update For Both Sides
    function getFundingFees(address _market) external view returns (uint256, uint256) {
        uint256 longAccumulatedFunding = IMarket(_market).longCumulativeFundingFees();
        uint256 shortAccumulatedFunding = IMarket(_market).shortCumulativeFundingFees();

        uint256 timeElapsed = block.timestamp - IMarket(_market).lastFundingUpdateTime();

        // is the current funding rate +ve or -ve ?
        // if +ve, need to add accumulated funding to long, if -ve need to add to short
        int256 fundingRate = IMarket(_market).fundingRate();
        if (fundingRate >= 0) {
            longAccumulatedFunding += (timeElapsed * uint256(fundingRate));
        } else {
            shortAccumulatedFunding += (timeElapsed * uint256(-fundingRate));
        }

        return (longAccumulatedFunding, shortAccumulatedFunding);
    }

    function getTotalPositionFeeOwed(address _market, MarketStructs.Position calldata _position)
        external
        view
        returns (uint256)
    {
        uint256 feesOwed;
        (, feesOwed) = getFeesSinceLastPositionUpdate(_market, _position);
        return feesOwed += _position.fundingParams.feesOwed;
    }

    /// @dev Get the Funding Fees Owed by a Position Since Last Update
    /// Value is in index tokens, not USD to prevent price discrepency issues
    function getFeesSinceLastPositionUpdate(address _market, MarketStructs.Position memory _position)
        public
        view
        returns (uint256 feesEarned, uint256 feesOwed)
    {
        uint256 longAccumulatedFunding =
            IMarket(_market).longCumulativeFundingFees() - _position.fundingParams.lastLongCumulativeFunding;
        uint256 shortAccumulatedFunding =
            IMarket(_market).shortCumulativeFundingFees() - _position.fundingParams.lastShortCumulativeFunding;

        uint256 longFundingFees;
        uint256 shortFundingFees;

        // Avoid division by zero
        if (longAccumulatedFunding != 0) {
            uint256 longDivisor = 1e18 / longAccumulatedFunding;
            longFundingFees = _position.positionSize / longDivisor;
        }

        if (shortAccumulatedFunding != 0) {
            uint256 shortDivisor = 1e18 / shortAccumulatedFunding;
            shortFundingFees = _position.positionSize / shortDivisor;
        }

        // Calculate fees earned and owed
        feesEarned = _position.isLong ? shortFundingFees : longFundingFees;
        feesOwed = _position.isLong ? longFundingFees : shortFundingFees;
    }
}
