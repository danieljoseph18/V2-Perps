// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {MarketStructs} from "../markets/MarketStructs.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {SD59x18, sd, unwrap, pow} from "@prb/math/SD59x18.sol";
import {UD60x18, ud, unwrap} from "@prb/math/UD60x18.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

library FundingCalculator {
    using SafeCast for uint256;
    using SafeCast for int256;
    // library responsible for handling all funding calculations

    /// Note Used by Market
    function calculateFundingRateVelocity(address _market, int256 _skew) external view returns (int256) {
        uint256 c = unwrap(ud(IMarket(_market).maxFundingVelocity()).div(ud(IMarket(_market).skewScale()))); // will underflow (3 mil < 10 mil)
        SD59x18 skew = sd(_skew); // skew of 1 = 1e18
        // scaled by 1e18
        // c = 3/10000 = 0.0003 * 100 =  0.3% = 3e14
        return c.toInt256() * unwrap(skew);
    }

    /// @dev Get the Funding Fees Accumulated Since Last Update For Both Sides
    function getFundingFees(address _market) external view returns (uint256, uint256) {
        uint256 longAccumulatedFunding = IMarket(_market).longCumulativeFundingFees();
        uint256 shortAccumulatedFunding = IMarket(_market).shortCumulativeFundingFees();

        uint256 timeSinceUpdate = block.timestamp - IMarket(_market).lastFundingUpdateTime(); // might need to scale by 1e18

        // is the current funding rate +ve or -ve ?
        // if +ve, need to add accumulated funding to long, if -ve need to add to short
        int256 fundingRate = IMarket(_market).fundingRate();
        if (fundingRate > 0) {
            longAccumulatedFunding += (timeSinceUpdate * fundingRate.toUint256());
        } else {
            shortAccumulatedFunding += (timeSinceUpdate * (-fundingRate).toUint256());
        }

        return (longAccumulatedFunding, shortAccumulatedFunding);
    }

    /// @dev Get the Funding Fees Owed by a Position Since Last Update
    function getFeesSinceLastPositionUpdate(address _market, MarketStructs.Position memory _position)
        external
        view
        returns (uint256 feesEarned, uint256 feesOwed)
    {
        // get cumulative funding fees since last update
        uint256 longAccumulatedFunding =
            IMarket(_market).longCumulativeFundingFees() - _position.fundingParams.lastLongCumulativeFunding;
        uint256 shortAccumulatedFunding =
            IMarket(_market).shortCumulativeFundingFees() - _position.fundingParams.lastShortCumulativeFunding;
        // multiply by size
        uint256 longFundingFees = longAccumulatedFunding * _position.positionSize;
        uint256 shortFundingFees = shortAccumulatedFunding * _position.positionSize;
        // if long, add short fees to fees earned, if short, add long fees to fees earned
        feesEarned = _position.isLong ? shortFundingFees : longFundingFees;
        // if short, add short fees to fees owed, if long, add long fees to fees owed
        feesOwed = _position.isLong ? longFundingFees : shortFundingFees;
    }
}
