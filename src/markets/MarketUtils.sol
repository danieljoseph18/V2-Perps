// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {MarketMaker} from "./MarketMaker.sol";
import {Market} from "./Market.sol";
import {mulDiv} from "@prb/math/Common.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {Pricing} from "../libraries/Pricing.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

library MarketUtils {
    using SignedMath for int256;
    using SafeCast for uint256;

    uint256 public constant SCALAR = 1e18;

    struct Config {
        uint256 maxFundingVelocity;
        uint256 skewScale;
        uint256 maxFundingRate;
        uint256 minFundingRate;
        uint256 borrowingFactor;
        uint256 borrowingExponent;
        uint256 priceImpactFactor;
        uint256 priceImpactExponent;
        uint256 maxPnlFactor;
        uint256 targetPnlFactor;
        bool feeForSmallerSide;
        bool adlFlaggedLong;
        bool adlFlaggedShort;
    }

    function getLongOpenInterestUSD(Market _market, uint256 _price, uint256 _baseUnit)
        external
        view
        returns (uint256 longOIUSD)
    {
        return mulDiv(_market.longOpenInterest(), _price, _baseUnit);
    }

    function getShortOpenInterestUSD(Market _market, uint256 _price, uint256 _baseUnit)
        external
        view
        returns (uint256 shortOIUSD)
    {
        return mulDiv(_market.shortOpenInterest(), _price, _baseUnit);
    }

    function getTotalOpenInterestUSD(Market _market, uint256 _price, uint256 _baseUnit)
        public
        view
        returns (uint256 totalOIUSD)
    {
        uint256 longOIUSD = mulDiv(_market.longOpenInterest(), _price, _baseUnit);
        uint256 shortOIUSD = mulDiv(_market.shortOpenInterest(), _price, _baseUnit);
        return longOIUSD + shortOIUSD;
    }

    function getTotalEntryValueUSD(Market _market, uint256 _indexBaseUnit, bool _isLong)
        external
        view
        returns (uint256 entryValueUsd)
    {
        uint256 totalWAEP;
        uint256 indexOI;
        if (_isLong) {
            totalWAEP = _market.longTotalWAEP();
            indexOI = _market.longOpenInterest();
        } else {
            totalWAEP = _market.shortTotalWAEP();
            indexOI = _market.shortOpenInterest();
        }

        entryValueUsd = mulDiv(totalWAEP, indexOI, _indexBaseUnit);
    }

    function getPoolBalanceUSD(
        Market _market,
        uint256 _longTokenPrice,
        uint256 _shortTokenPrice,
        uint256 _longBaseUnit,
        uint256 _shortBaseUnit
    ) public view returns (uint256 poolBalanceUSD) {
        uint256 longBalanceUSD = mulDiv(_market.longTokenAllocation(), _longTokenPrice, _longBaseUnit);
        uint256 shortBalance = mulDiv(_market.shortTokenAllocation(), _shortTokenPrice, _shortBaseUnit);
        poolBalanceUSD = longBalanceUSD + shortBalance;
    }

    function getPoolAmount(Market _market, bool _isLong) public view returns (uint256 poolAmount) {
        if (_isLong) {
            poolAmount = _market.longTokenAllocation();
        } else {
            poolAmount = _market.shortTokenAllocation();
        }
    }

    function getPoolUsd(Market _market, uint256 _price, uint256 _baseUnit, bool _isLong)
        public
        view
        returns (uint256 poolUsd)
    {
        uint256 poolAmount = getPoolAmount(_market, _isLong);
        poolUsd = mulDiv(poolAmount, _price, _baseUnit);
    }

    // The pnl factor is the ratio of the pnl to the pool usd
    function getPnlFactor(Market _market, uint256 _price, uint256 _baseUnit, bool _isLong)
        external
        view
        returns (int256 pnlFactor)
    {
        // get pool usd ( if 0 return 0)
        uint256 poolUsd = getPoolUsd(_market, _price, _baseUnit, _isLong);
        if (poolUsd == 0) {
            return 0;
        }
        // get pnl
        int256 pnl = Pricing.getPnl(_market, _price, _baseUnit, _isLong);

        uint256 factor = mulDiv(pnl.abs(), SCALAR, poolUsd);
        return pnl > 0 ? factor.toInt256() : factor.toInt256() * -1;
    }
}
