// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {MarketUtils} from "../markets/MarketUtils.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {Casting} from "./Casting.sol";
import {MathUtils} from "./MathUtils.sol";
import {Pool} from "../markets/Pool.sol";
import {MarketId} from "../types/MarketId.sol";
import {console2} from "forge-std/Test.sol";

/// @dev Library for Funding Related Calculations
library Funding {
    using Casting for *;
    using MathUtils for uint256;
    using MathUtils for int256;
    using MathUtils for int64;
    using MathUtils for int16;
    using MathUtils for uint48;

    int128 constant PRICE_UNIT = 1e30;
    int128 constant sPRICE_UNIT = 1e30;
    int64 constant sUNIT = 1e18;
    int64 constant sMAX_FUNDING_RATE = 0.0075e18; // 0.75%
    uint32 constant SECONDS_IN_DAY = 86400;

    /**
     * Funding needs to:
     * - Store the funding elapsed at the previous rate
     * - Calculate the new rate and velocity based on the UPDATED open interest
     *
     */
    function updateState(
        MarketId _id,
        IMarket market,
        Pool.Storage storage pool,
        string calldata _ticker,
        uint256 _indexPrice,
        int256 _sizeDelta,
        bool _isLong
    ) internal {
        int256 nextSkew = _calculateNextSkew(_id, market, _ticker, _sizeDelta, _isLong);

        pool.fundingRateVelocity =
            getCurrentVelocity(market, nextSkew, pool.config.maxFundingVelocity, pool.config.skewScale).toInt64();

        console2.log("Old Funding Rate: ", pool.fundingRate);
        console2.log("Old Funding Accrued: ", pool.fundingAccruedUsd);
        (pool.fundingRate, pool.fundingAccruedUsd) = calculateNextFunding(_id, market, _ticker, _indexPrice);
        console2.log("New Funding Rate: ", pool.fundingRate);
        console2.log("New Funding Accrued: ", pool.fundingAccruedUsd);
    }

    function calculateNextFunding(MarketId _id, IMarket market, string calldata _ticker, uint256 _indexPrice)
        public
        view
        returns (int64, int256)
    {
        (int64 fundingRate, int256 unrecordedFunding) = _getUnrecordedFundingWithRate(_id, market, _ticker, _indexPrice);

        console2.log("FundingRate: ", fundingRate);
        console2.log("UnrecordedFunding: ", unrecordedFunding);

        return (fundingRate, market.getFundingAccrued(_id, _ticker) + unrecordedFunding);
    }

    /**
     * @dev Returns the current funding rate given current market conditions.
     */
    function getCurrentFundingRate(MarketId _id, IMarket market, string calldata _ticker) public view returns (int64) {
        // example:
        //  - fundingRate         = 0
        //  - velocity            = 0.0025
        //  - timeDelta           = 29,000s
        //  - maxFundingVelocity  = 0.025 (2.5%)
        //  - skew                = 300
        //  - skewScale           = 10,000
        //
        // currentFundingRate = fundingRate + velocity * (timeDelta / secondsInDay)
        // currentFundingRate = 0 + 0.0025 * (29,000 / 86,400)
        //                    = 0 + 0.0025 * 0.33564815
        //                    = 0.00083912
        (int64 fundingRate, int64 fundingRateVelocity) = market.getFundingRates(_id, _ticker);
        console2.log("FundingRate: ", fundingRate);
        console2.log("FundingRateVelocity: ", fundingRateVelocity);

        int256 currentFundingRate =
            fundingRate + fundingRateVelocity.sMulWad(_getProportionalFundingElapsed(_id, market, _ticker));

        // Clamp rate
        return currentFundingRate.clamp(-sMAX_FUNDING_RATE, sMAX_FUNDING_RATE).toInt64();
    }

    //  - proportionalSkew = skew / skewScale
    //  - velocity         = proportionalSkew * maxFundingVelocity
    function getCurrentVelocity(IMarket market, int256 _skew, int16 _maxVelocity, int48 _skewScale)
        public
        view
        returns (int256 velocity)
    {
        // As skewScale has 0 D.P, we can directly divide skew by skewScale to get a proportion to 30 D.P
        // e.g if skew = 300_000e30 ($300,000), and skewScale = 1_000_000 ($1,000,000)
        // proportionalSkew = 300_000e30 / 1_000_000 = 0.3e30 (0.3%)
        int256 proportionalSkew = _skew / _skewScale;

        if (proportionalSkew.abs() < market.FUNDING_VELOCITY_CLAMP()) {
            // If the proportional skew is less than the clamp, velocity is negligible.
            return 0;
        }

        // Bound skew between -1 and 1 (30 d.p)
        int256 pSkewBounded = proportionalSkew.clamp(-sPRICE_UNIT, sPRICE_UNIT);

        int256 maxVelocity = _maxVelocity.expandDecimals(4, 18);

        // Calculate the velocity to 18dp (proportionalSkew * maxFundingVelocity)
        velocity = pSkewBounded.mulDivSigned(maxVelocity, sPRICE_UNIT);
    }

    /**
     * =========================================== Private Functions ===========================================
     */

    /**
     * @dev Returns the proportional time elapsed since last funding (proportional by 1 day).
     * 18 D.P
     */
    function _getProportionalFundingElapsed(MarketId _id, IMarket market, string calldata _ticker)
        private
        view
        returns (int256 proportionalFundingElapsed)
    {
        uint48 timeElapsed = _blockTimestamp() - market.getLastUpdate(_id, _ticker);

        console2.log("Time Elapsed: ", timeElapsed);

        console2.log("Time Elapsed * Seconds in Day: ", timeElapsed * SECONDS_IN_DAY);

        proportionalFundingElapsed = timeElapsed.divWad(SECONDS_IN_DAY).toInt256();

        console2.log("Proportional Funding Elapsed: ", proportionalFundingElapsed);
    }

    /**
     * @dev Returns the next market funding accrued value.
     */
    function _getUnrecordedFundingWithRate(MarketId _id, IMarket market, string calldata _ticker, uint256 _indexPrice)
        private
        view
        returns (int64 fundingRate, int256 unrecordedFunding)
    {
        fundingRate = getCurrentFundingRate(_id, market, _ticker);

        console2.log("proportionalFundingElapsed", _getProportionalFundingElapsed(_id, market, _ticker));
        console2.log("indexPrice", _indexPrice.toInt256());

        (int256 storedFundingRate,) = market.getFundingRates(_id, _ticker);

        // Minus sign is needed as funding flows in the opposite direction of the skew
        // Take an average of the current / prev funding rates
        int256 avgFundingRate = -storedFundingRate.avg(fundingRate);

        console2.log("avgFundingRate", avgFundingRate);

        unrecordedFunding = avgFundingRate.mulDivSigned(_getProportionalFundingElapsed(_id, market, _ticker), sUNIT)
            .mulDivSigned(_indexPrice.toInt256(), sUNIT);
    }

    function _calculateNextSkew(MarketId _id, IMarket market, string calldata _ticker, int256 _sizeDelta, bool _isLong)
        private
        view
        returns (int256 nextSkew)
    {
        uint256 longOI = market.getOpenInterest(_id, _ticker, true);
        uint256 shortOI = market.getOpenInterest(_id, _ticker, false);

        if (_isLong) {
            _sizeDelta > 0 ? longOI += _sizeDelta.abs() : longOI -= _sizeDelta.abs();
        } else {
            _sizeDelta > 0 ? shortOI += _sizeDelta.abs() : shortOI -= _sizeDelta.abs();
        }

        nextSkew = longOI.diff(shortOI);
    }

    function _blockTimestamp() private view returns (uint48) {
        return uint48(block.timestamp);
    }
}
