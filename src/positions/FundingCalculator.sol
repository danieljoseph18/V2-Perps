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

    // returns percentage of position size that is paid as funding fees
    /// Note Gets the total funding fees by a position, doesn't account for realised funding fees
    /// Review Could this be gamed by adjusting the position size?
    // Only calculates what the user owes, not what they could be owed
    // Update so it returns what a short would owe and what a long would owe
    // if return value is negative, they're owed funding fees
    // if return value is positive, they owe funding fees
    function getFundingFees(address _market, MarketStructs.Position memory _position)
        public
        view
        returns (uint256, uint256)
    {
        uint256 longLastFunding = _position.fundingParams.lastLongCumulativeFunding;
        uint256 shortLastFunding = _position.fundingParams.lastShortCumulativeFunding;

        uint256 longAccumulatedFunding = IMarket(_market).longCumulativeFundingFees() - longLastFunding;
        uint256 shortAccumulatedFunding = IMarket(_market).shortCumulativeFundingFees() - shortLastFunding;

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
}
