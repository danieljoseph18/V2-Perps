// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {MarketUtils} from "../markets/MarketUtils.sol";
import {Position} from "../positions/Position.sol";
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

    function calculateSkewUsd(IMarket market, bytes32 _assetId) external view returns (int256 skewUsd) {
        uint256 longOI = MarketUtils.getOpenInterestUsd(market, _assetId, true);
        uint256 shortOI = MarketUtils.getOpenInterestUsd(market, _assetId, false);

        skewUsd = longOI.toInt256() - shortOI.toInt256();
    }

    function getFeeForPositionChange(
        IMarket market,
        bytes32 _assetId,
        uint256 _indexPrice,
        uint256 _sizeDelta,
        int256 _entryFundingAccrued
    ) external view returns (int256 fundingFeeUsd, int256 nextFundingAccrued) {
        (, nextFundingAccrued) = _calculateNextFunding(market, _assetId, _indexPrice);
        // Both Values in USD -> 30 D.P: Divide by Price precision to get 30 D.P value
        fundingFeeUsd = mulDivSigned(_sizeDelta.toInt256(), nextFundingAccrued - _entryFundingAccrued, PRICE_PRECISION);
    }

    function getTotalFeesOwedUsd(IMarket market, Position.Data memory _position, uint256 _indexPrice)
        external
        view
        returns (int256 totalFeesOwedUsd)
    {
        (, int256 nextFundingAccrued) = _calculateNextFunding(market, _position.assetId, _indexPrice);
        totalFeesOwedUsd = mulDivSigned(
            _position.positionSize.toInt256(),
            nextFundingAccrued - _position.fundingParams.lastFundingAccrued,
            PRICE_PRECISION
        );
    }

    //  - proportionalSkew = skew / skewScale
    //  - velocity         = proportionalSkew * maxFundingVelocity
    function getCurrentVelocity(IMarket market, bytes32 _assetId, int256 _skew)
        external
        view
        returns (int256 velocity)
    {
        IMarket.FundingConfig memory funding = market.getFundingConfig(_assetId);
        // Get the proportionalSkew
        int256 proportionalSkew = mulDivSigned(_skew, SIGNED_PRECISION, funding.skewScale);
        // Check if the absolute value of proportionalSkew is less than the fundingVelocityClamp
        if (proportionalSkew.abs() < funding.fundingVelocityClamp) {
            return 0;
        }
        // Bound between -1e18 and 1e18
        int256 pSkewBounded = SignedMath.min(SignedMath.max(proportionalSkew, -SIGNED_PRECISION), SIGNED_PRECISION);
        // Calculate the velocity
        velocity = mulDivSigned(pSkewBounded, funding.maxVelocity, SIGNED_PRECISION);
    }

    function recompute(IMarket market, bytes32 _assetId, uint256 _indexPrice)
        external
        view
        returns (int256 nextFundingRate, int256 nextFundingAccruedUsd)
    {
        (nextFundingRate, nextFundingAccruedUsd) = _calculateNextFunding(market, _assetId, _indexPrice);
    }

    function _calculateNextFunding(IMarket market, bytes32 _assetId, uint256 _indexPrice)
        internal
        view
        returns (int256 nextRate, int256 nextFundingAccrued)
    {
        (int256 fundingRate, int256 unrecordedFunding) = _getUnrecordedFundingWithRate(market, _assetId, _indexPrice);
        nextRate = fundingRate;
        nextFundingAccrued = market.getFundingAccrued(_assetId) + unrecordedFunding;
    }

    /**
     * @dev Returns the current funding rate given current market conditions.
     */
    function getCurrentFundingRate(IMarket market, bytes32 _assetId) public view returns (int256) {
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
        (int256 fundingRate, int256 fundingRateVelocity) = market.getFundingRates(_assetId);
        return fundingRate
            + mulDivSigned(fundingRateVelocity, _getProportionalFundingElapsed(market, _assetId), SIGNED_PRECISION);
    }

    /**
     * @dev Returns the proportional time elapsed since last funding (proportional by 1 day).
     * 18 D.P
     */
    function _getProportionalFundingElapsed(IMarket market, bytes32 _assetId) internal view returns (int256) {
        return mulDivSigned(
            (block.timestamp - market.getLastFundingUpdate(_assetId)).toInt256(), SIGNED_PRECISION, SECONDS_IN_DAY
        );
    }

    /**
     * @dev Returns the next market funding accrued value.
     */
    function _getUnrecordedFundingWithRate(IMarket market, bytes32 _assetId, uint256 _indexPrice)
        internal
        view
        returns (int256 fundingRate, int256 unrecordedFunding)
    {
        fundingRate = getCurrentFundingRate(market, _assetId);
        (int256 storedFundingRate,) = market.getFundingRates(_assetId);
        // Minus sign is needed as funding flows in the opposite direction of the skew
        // Essentially taking an average, where Signed Precision == units
        int256 avgFundingRate = -mulDivSigned(storedFundingRate, fundingRate, 2 * SIGNED_PRECISION);

        unrecordedFunding = mulDivSigned(
            mulDivSigned(avgFundingRate, _getProportionalFundingElapsed(market, _assetId), SIGNED_PRECISION),
            _indexPrice.toInt256(),
            SIGNED_PRECISION
        );
    }
}
