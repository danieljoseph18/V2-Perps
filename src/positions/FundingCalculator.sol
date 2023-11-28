// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {MarketStructs} from "../markets/MarketStructs.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {SD59x18, sd, unwrap, pow} from "@prb/math/SD59x18.sol";
import {UD60x18, ud, unwrap} from "@prb/math/UD60x18.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

library FundingCalculator {
    using SafeCast for uint256;
    using SafeCast for int256;

    function calculateFundingRateVelocity(address _market, int256 _skew) external view returns (int256) {
        UD60x18 c = ud(IMarket(_market).maxFundingVelocity()).div(ud(IMarket(_market).skewScale())); // will underflow (3 mil < 10 mil)
        SD59x18 skew = sd(_skew);
        return unwrap((c.intoSD59x18()).mul(skew));
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
            longAccumulatedFunding += (timeElapsed * fundingRate.toUint256());
        } else {
            shortAccumulatedFunding += (timeElapsed * (-fundingRate).toUint256());
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
    function getFeesSinceLastPositionUpdate(address _market, MarketStructs.Position memory _position)
        public
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
