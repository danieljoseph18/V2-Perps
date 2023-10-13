// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {MarketStructs} from "../markets/MarketStructs.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMarketStorage} from "../markets/interfaces/IMarketStorage.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
import { SD59x18, sd, unwrap, pow } from "@prb/math/SD59x18.sol";
import { UD60x18, ud, unwrap } from "@prb/math/UD60x18.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";


library FundingCalculator {
    using SafeCast for uint256;
    using SafeCast for int256;
    // library responsible for handling all funding calculations

    // if return value is negative, they're owed funding fees
    // if return value is positive, they owe funding fees
    function _getFundingFees(address _marketStorage, MarketStructs.Position memory _position) internal view returns (uint256 _longFunding, uint256 _shortFunding) {
        address market = IMarketStorage(_marketStorage).getMarket(_position.market).market;
        return IMarket(market).getFundingFees(_position);
    }

     function updateFundingRate(address _market, uint256 _positionSize, bool _isLong) external {
        uint256 longOI = IMarket(_market).getIndexOpenInterestUSD(true);
        uint256 shortOI = IMarket(_market).getIndexOpenInterestUSD(false);
        _isLong ? longOI += _positionSize : shortOI += _positionSize;
        int256 skew = unwrap(sd(longOI.toInt256()) - sd(shortOI.toInt256())); // 500 USD skew = 500e18
        int256 velocity = _calculateFundingRateVelocity(_market, skew); // int scaled by 1e18

        // Calculate time since last funding update
        uint256 timeElapsed = unwrap(ud(block.timestamp) - ud(IMarket(_market).lastFundingUpdateTime()));
        // Add the previous velocity to the funding rate
        int256 deltaRate = unwrap((sd(IMarket(_market).fundingRateVelocity())).mul(sd(timeElapsed.toInt256())).div(sd(1 days)));

        int256 fundingRate = IMarket(_market).fundingRate();
        // Update Cumulative Fees
        if (fundingRate > 0) {
            // update long cumulative funding fees
            // longCumulativeFundingFees += (fundingRate.toUint256() * timeElapsed); // if funding rate has 18 decimals, rate per token = rate
        } else if (fundingRate < 0) {
            // update short cumulative funding fees
            // shortCumulativeFundingFees += ((-fundingRate).toUint256() * timeElapsed);
        }

        // if funding rate addition puts it above / below limit, set to limit
        if (fundingRate + deltaRate > IMarket(_market).maxFundingRate()) {
            // update funding rate
            // fundingRate = maxFundingRate;
        } else if (fundingRate - deltaRate < IMarket(_market).minFundingRate()){
            // update funding rate
            // fundingRate = -maxFundingRate;
        } else {
            // update funding rate
            // fundingRate += deltaRate;
        }
        // update FRV
        // fundingRateVelocity = velocity;
        // update last funding update time
        // lastFundingUpdateTime = block.timestamp;
    }

    function _calculateFundingRateVelocity(address _market, int256 _skew) internal view returns (int256) {
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
    function _calculateFundingFees(address _market, MarketStructs.Position memory _position) internal view returns (uint256, uint256) {
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

    function getFundingFees(address _market, MarketStructs.Position memory _position) external view returns (uint256, uint256) {
        return _calculateFundingFees(_market, _position);
    }




}