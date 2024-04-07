// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {MarketUtils} from "../markets/MarketUtils.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {mulDiv, mulDivSigned} from "@prb/math/Common.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";

/// @dev Library for Funding Related Calculations
library Funding {
    using SafeCast for uint256;
    using SafeCast for int256;
    using SignedMath for int256;

    int256 constant SIGNED_PRECISION = 1e18;
    int256 constant PRICE_PRECISION = 1e30;
    int256 constant SECONDS_IN_DAY = 86400;

    function updateState(
        IMarket market,
        IMarket.FundingValues memory funding,
        string calldata _ticker,
        uint256 _indexPrice
    ) external view returns (IMarket.FundingValues memory) {
        // Calculate the skew in USD
        int256 skewUsd = calculateSkewUsd(market, _ticker);

        // Calculate the current funding velocity
        funding.fundingRateVelocity = getCurrentVelocity(market, _ticker, skewUsd);

        // Calculate the current funding rate
        (funding.fundingRate, funding.fundingAccruedUsd) = recompute(market, _ticker, _indexPrice);

        // Update storage
        funding.lastFundingUpdate = block.timestamp.toUint48();

        return funding;
    }

    function calculateSkewUsd(IMarket market, string calldata _ticker) public view returns (int256 skewUsd) {
        uint256 longOI = MarketUtils.getOpenInterest(market, _ticker, true);
        uint256 shortOI = MarketUtils.getOpenInterest(market, _ticker, false);

        skewUsd = longOI.toInt256() - shortOI.toInt256();
    }

    //  - proportionalSkew = skew / skewScale
    //  - velocity         = proportionalSkew * maxFundingVelocity
    function getCurrentVelocity(IMarket market, string calldata _ticker, int256 _skew)
        public
        view
        returns (int256 velocity)
    {
        IMarket.FundingConfig memory funding = MarketUtils.getFundingConfig(market, _ticker);
        // Get the proportionalSkew
        int256 proportionalSkew = mulDivSigned(_skew, SIGNED_PRECISION, funding.skewScale);
        // Check if the absolute value of proportionalSkew is less than the fundingVelocityClamp
        if (proportionalSkew.abs() < market.FUNDING_VELOCITY_CLAMP()) {
            return 0;
        }
        // Bound between -1e18 and 1e18
        int256 pSkewBounded = SignedMath.min(SignedMath.max(proportionalSkew, -SIGNED_PRECISION), SIGNED_PRECISION);
        // Calculate the velocity
        velocity = mulDivSigned(pSkewBounded, funding.maxVelocity, SIGNED_PRECISION);
    }

    function recompute(IMarket market, string calldata _ticker, uint256 _indexPrice)
        public
        view
        returns (int256 nextFundingRate, int256 nextFundingAccruedUsd)
    {
        (nextFundingRate, nextFundingAccruedUsd) = calculateNextFunding(market, _ticker, _indexPrice);
    }

    function calculateNextFunding(IMarket market, string calldata _ticker, uint256 _indexPrice)
        public
        view
        returns (int256 nextRate, int256 nextFundingAccrued)
    {
        (int256 fundingRate, int256 unrecordedFunding) = _getUnrecordedFundingWithRate(market, _ticker, _indexPrice);
        nextRate = fundingRate;
        nextFundingAccrued = MarketUtils.getFundingAccrued(market, _ticker) + unrecordedFunding;
    }

    /**
     * @dev Returns the current funding rate given current market conditions.
     */
    function getCurrentFundingRate(IMarket market, string calldata _ticker) public view returns (int256) {
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
        (int256 fundingRate, int256 fundingRateVelocity) = MarketUtils.getFundingRates(market, _ticker);
        return fundingRate
            + mulDivSigned(fundingRateVelocity, _getProportionalFundingElapsed(market, _ticker), SIGNED_PRECISION);
    }

    /**
     * @dev Returns the proportional time elapsed since last funding (proportional by 1 day).
     * 18 D.P
     */
    function _getProportionalFundingElapsed(IMarket market, string calldata _ticker) private view returns (int256) {
        return mulDivSigned(
            (block.timestamp - MarketUtils.getLastFundingUpdate(market, _ticker)).toInt256(),
            SIGNED_PRECISION,
            SECONDS_IN_DAY
        );
    }

    /**
     * @dev Returns the next market funding accrued value.
     */
    function _getUnrecordedFundingWithRate(IMarket market, string calldata _ticker, uint256 _indexPrice)
        private
        view
        returns (int256 fundingRate, int256 unrecordedFunding)
    {
        fundingRate = getCurrentFundingRate(market, _ticker);
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
}
