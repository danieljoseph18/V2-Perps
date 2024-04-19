// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {MarketUtils} from "../markets/MarketUtils.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {mulDiv, mulDivSigned} from "@prb/math/Common.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {MathUtils} from "./MathUtils.sol";
import {Pool} from "../markets/Pool.sol";

/// @dev Library for Funding Related Calculations
library Funding {
    using SafeCast for *;
    using SignedMath for int256;
    using MathUtils for uint256;
    using MathUtils for int16;

    int256 constant SIGNED_PRECISION = 1e18;
    int256 constant PRICE_PRECISION = 1e30;
    int64 constant SECONDS_IN_DAY = 86400;

    function updateState(IMarket market, Pool.Storage storage pool, string calldata _ticker, uint256 _indexPrice)
        internal
    {
        // Calculate the skew in USD
        int256 skewUsd = _calculateSkewUsd(market, _ticker);

        // Calculate the current funding velocity
        pool.fundingRateVelocity =
            _getCurrentVelocity(market, skewUsd, pool.config.maxFundingVelocity, pool.config.skewScale).toInt64();

        // Calculate the current funding rate
        (pool.fundingRate, pool.fundingAccruedUsd) = _recompute(market, _ticker, _indexPrice);
    }

    function calculateNextFunding(IMarket market, string calldata _ticker, uint256 _indexPrice)
        public
        view
        returns (int64 nextRate, int256 nextFundingAccrued)
    {
        (int64 fundingRate, int256 unrecordedFunding) = _getUnrecordedFundingWithRate(market, _ticker, _indexPrice);
        nextRate = fundingRate;
        nextFundingAccrued = MarketUtils.getFundingAccrued(market, _ticker) + unrecordedFunding;
    }

    /**
     * ============================== Private Functions ==============================
     */
    function _recompute(IMarket market, string calldata _ticker, uint256 _indexPrice)
        private
        view
        returns (int64 nextFundingRate, int256 nextFundingAccruedUsd)
    {
        (nextFundingRate, nextFundingAccruedUsd) = calculateNextFunding(market, _ticker, _indexPrice);
    }

    //  - proportionalSkew = skew / skewScale
    //  - velocity         = proportionalSkew * maxFundingVelocity
    // @audit - make sure its always < max int16 (1e18)
    function _getCurrentVelocity(IMarket market, int256 _skew, int16 _maxVelocity, int48 _skewScale)
        private
        view
        returns (int256 velocity)
    {
        // Get the proportionalSkew
        // As skewScale has 0 D.P, we can directly divide skew by skewScale to get a proportion to 30 D.P
        // e.g if skew = 300_000e30 ($300,000), and skewScale = 1_000_000 ($1,000,000)
        // proportionalSkew = 300_000e30 / 1_000_000 = 0.3e30 (0.3%)
        int256 proportionalSkew = _skew / _skewScale;
        // Check if the absolute value of proportionalSkew is less than the fundingVelocityClamp
        if (proportionalSkew.abs() < market.FUNDING_VELOCITY_CLAMP()) {
            return 0;
        }
        // Bound between -1e18 and 1e18
        int256 pSkewBounded = SignedMath.min(SignedMath.max(proportionalSkew, -SIGNED_PRECISION), SIGNED_PRECISION);
        // Convert maxVelocity from a 2.Dp percentage to 30 Dp
        int256 maxVelocity = _maxVelocity.expandDecimals(2, 30);
        // Calculate the velocity
        velocity = mulDivSigned(pSkewBounded, maxVelocity, SIGNED_PRECISION);
    }

    /**
     * @dev Returns the proportional time elapsed since last funding (proportional by 1 day).
     * 18 D.P
     */
    function _getProportionalFundingElapsed(IMarket market, string calldata _ticker) private view returns (int64) {
        uint48 timeElapsed = _blockTimestamp() - MarketUtils.getLastUpdate(market, _ticker);
        return int64(int48(timeElapsed)) * int64(SIGNED_PRECISION) / SECONDS_IN_DAY;
    }

    /**
     * @dev Returns the next market funding accrued value.
     */
    function _getUnrecordedFundingWithRate(IMarket market, string calldata _ticker, uint256 _indexPrice)
        private
        view
        returns (int64 fundingRate, int256 unrecordedFunding)
    {
        fundingRate = _getCurrentFundingRate(market, _ticker);
        (int256 storedFundingRate,) = MarketUtils.getFundingRates(market, _ticker);
        // Minus sign is needed as funding flows in the opposite direction of the skew
        // Essentially taking an average, where Signed Precision == units
        int256 avgFundingRate = -mulDivSigned(storedFundingRate, fundingRate, 2 * SIGNED_PRECISION);

        unrecordedFunding = mulDivSigned(
            mulDivSigned(avgFundingRate, _getProportionalFundingElapsed(market, _ticker), SIGNED_PRECISION),
            _indexPrice.toInt256(),
            SIGNED_PRECISION
        );
    }

    /**
     * @dev Returns the current funding rate given current market conditions.
     */
    function _getCurrentFundingRate(IMarket market, string calldata _ticker) private view returns (int64) {
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
        (int64 fundingRate, int64 fundingRateVelocity) = MarketUtils.getFundingRates(market, _ticker);
        return fundingRate
            + (fundingRateVelocity * _getProportionalFundingElapsed(market, _ticker) / int64(SIGNED_PRECISION));
    }

    function _calculateSkewUsd(IMarket market, string calldata _ticker) private view returns (int256 skewUsd) {
        uint256 longOI = MarketUtils.getOpenInterest(market, _ticker, true);
        uint256 shortOI = MarketUtils.getOpenInterest(market, _ticker, false);

        skewUsd = longOI.diff(shortOI);
    }

    function _blockTimestamp() private view returns (uint48) {
        return uint48(block.timestamp);
    }
}
