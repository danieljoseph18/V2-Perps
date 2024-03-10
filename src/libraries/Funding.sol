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

// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {MarketUtils} from "../markets/MarketUtils.sol";
import {Position} from "../positions/Position.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {mulDiv, mulDivSigned} from "@prb/math/Common.sol";
import {sd} from "@prb/math/SD59x18.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Order} from "../positions/Order.sol";

/// @dev Library for Funding Related Calculations
library Funding {
    using SafeCast for uint256;
    using SafeCast for int256;
    using SignedMath for int256;

    uint256 constant PRECISION = 1e18;
    int256 constant SIGNED_PRECISION = 1e18;
    int256 constant PRICE_PRECISION = 1e30;
    int256 constant SECONDS_IN_DAY = 86400;

    function calculateSkewUsd(IMarket market, address _indexToken, uint256 _indexPrice)
        external
        view
        returns (int256 skewUsd)
    {
        uint256 longOI = MarketUtils.getOpenInterestUsd(market, _indexToken, _indexPrice, true);
        uint256 shortOI = MarketUtils.getOpenInterestUsd(market, _indexToken, _indexPrice, false);

        skewUsd = longOI.toInt256() - shortOI.toInt256();
    }

    function getFeeForPositionChange(
        IMarket market,
        address _indexToken,
        uint256 _indexPrice,
        uint256 _sizeDelta,
        int256 _entryFundingAccrued
    ) external view returns (int256 fundingFeeUsd, int256 nextFundingAccrued) {
        // Ensure the sizeDeltaUsd is positive
        (, nextFundingAccrued) = _calculateNextFunding(market, _indexToken, _indexPrice);
        // Both Values in USD -> 30 D.P: Divide by Price precision to get 30 D.P value
        fundingFeeUsd = mulDivSigned(_sizeDelta.toInt256(), nextFundingAccrued - _entryFundingAccrued, PRICE_PRECISION);
    }

    /// @dev Calculate the funding rate velocity
    /// @dev velocity units = % per second (18 dp)
    function getCurrentVelocity(IMarket market, address _indexToken, int256 _skew)
        external
        view
        returns (int256 velocity)
    {
        IMarket.FundingConfig memory funding = market.getFundingConfig(_indexToken);
        // Get the proportionalSkew
        int256 proportionalSkew = mulDivSigned(_skew, SIGNED_PRECISION, funding.skewScale);
        // Bound between -1e18 and 1e18
        int256 boundedSkew = SignedMath.min(SignedMath.max(proportionalSkew, -SIGNED_PRECISION), SIGNED_PRECISION);
        // Calculate the velocity
        velocity = mulDivSigned(boundedSkew, SIGNED_PRECISION, funding.maxVelocity);
    }

    function recompute(IMarket market, address _indexToken, uint256 _indexPrice)
        external
        view
        returns (int256 nextFundingRate, int256 nextFundingAccruedUsd)
    {
        (nextFundingRate, nextFundingAccruedUsd) = _calculateNextFunding(market, _indexToken, _indexPrice);
    }

    function _calculateNextFunding(IMarket market, address _indexToken, uint256 _indexPrice)
        internal
        view
        returns (int256 nextRate, int256 nextFundingAccrued)
    {
        (int256 fundingRate, int256 unrecordedFunding) = _getUnrecordedFundingWithRate(market, _indexToken, _indexPrice);
        nextRate = fundingRate;
        nextFundingAccrued = market.getFundingAccrued(_indexToken) + unrecordedFunding;
    }

    // Rate to 18 D.P
    function getCurrentFundingRate(IMarket market, address _indexToken) public view returns (int256) {
        (int256 fundingRate, int256 fundingRateVelocity) = market.getFundingRates(_indexToken);
        return fundingRate
            + mulDivSigned(fundingRateVelocity, _getProportionalFundingElapsed(market, _indexToken), SIGNED_PRECISION);
    }

    /**
     * @dev Returns the proportional time elapsed since last funding (proportional by 1 day).
     * 18 D.P
     */
    function _getProportionalFundingElapsed(IMarket market, address _indexToken) internal view returns (int256) {
        return mulDivSigned(
            (block.timestamp - market.getLastFundingUpdate(_indexToken)).toInt256(), SIGNED_PRECISION, SECONDS_IN_DAY
        );
    }

    /**
     * @dev Returns the next market funding accrued value.
     */
    function _getUnrecordedFundingWithRate(IMarket market, address _indexToken, uint256 _indexPrice)
        internal
        view
        returns (int256 fundingRate, int256 unrecordedFunding)
    {
        fundingRate = getCurrentFundingRate(market, _indexToken);
        (int256 storedFundingRate,) = market.getFundingRates(_indexToken);
        // Minus sign is needed as funding flows in the opposite direction of the skew
        // Essentially taking an average, where Signed Precision == units
        int256 avgFundingRate = -mulDivSigned(storedFundingRate, fundingRate, 2 * SIGNED_PRECISION);

        unrecordedFunding = mulDivSigned(
            mulDivSigned(avgFundingRate, _getProportionalFundingElapsed(market, _indexToken), SIGNED_PRECISION),
            _indexPrice.toInt256(),
            SIGNED_PRECISION
        );
    }
}
