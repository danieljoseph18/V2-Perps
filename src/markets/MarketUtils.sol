// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {IMarket} from "./interfaces/IMarket.sol";
import {mulDiv} from "@prb/math/Common.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {Pricing} from "../libraries/Pricing.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ILiquidityVault} from "../liquidity/interfaces/ILiquidityVault.sol";

library MarketUtils {
    using SignedMath for int256;
    using SafeCast for uint256;

    uint256 public constant SCALAR = 1e18;
    uint256 public constant MAX_ALLOCATION = 10000;

    function getOpenInterestUsd(IMarket market, uint256 _indexPrice, uint256 _indexBaseUnit, bool _isLong)
        public
        view
        returns (uint256 longOIUSD)
    {
        return _isLong
            ? mulDiv(market.longOpenInterest(), _indexPrice, _indexBaseUnit)
            : mulDiv(market.shortOpenInterest(), _indexPrice, _indexBaseUnit);
    }

    function getTotalOpenInterestUsd(IMarket market, uint256 _indexPrice, uint256 _indexBaseUnit)
        external
        view
        returns (uint256 totalOIUSD)
    {
        uint256 longOIUSD = mulDiv(market.longOpenInterest(), _indexPrice, _indexBaseUnit);
        uint256 shortOIUSD = mulDiv(market.shortOpenInterest(), _indexPrice, _indexBaseUnit);
        return longOIUSD + shortOIUSD;
    }

    function getTotalEntryValueUsd(IMarket market, uint256 _indexBaseUnit, bool _isLong)
        external
        view
        returns (uint256 entryValueUsd)
    {
        uint256 averageEntryPrice;
        uint256 indexOI;
        if (_isLong) {
            averageEntryPrice = market.longAverageEntryPrice();
            indexOI = market.longOpenInterest();
        } else {
            averageEntryPrice = market.shortAverageEntryPrice();
            indexOI = market.shortOpenInterest();
        }

        entryValueUsd = mulDiv(averageEntryPrice, indexOI, _indexBaseUnit);
    }

    function getTotalPoolBalanceUSD(
        IMarket market,
        ILiquidityVault liquidityVault,
        uint256 _longTokenPrice,
        uint256 _shortTokenPrice,
        uint256 _longBaseUnit,
        uint256 _shortBaseUnit
    ) external view returns (uint256 poolBalanceUsd) {
        uint256 longPoolUsd = getPoolBalanceUsd(market, liquidityVault, _longTokenPrice, _longBaseUnit, true);
        uint256 shortPoolUsd = getPoolBalanceUsd(market, liquidityVault, _shortTokenPrice, _shortBaseUnit, false);
        poolBalanceUsd = longPoolUsd + shortPoolUsd;
    }

    function getPoolBalance(IMarket market, ILiquidityVault liquidityVault, bool _isLong)
        public
        view
        returns (uint256 poolAmount)
    {
        // get the allocation percentage
        uint256 allocationPercentage = market.percentageAllocation();
        // get the total liquidity available for that side
        uint256 totalAvailableLiquidity = liquidityVault.totalAvailableLiquidity(_isLong);
        // calculate liquidity allocated to the market for that side
        poolAmount = mulDiv(totalAvailableLiquidity, allocationPercentage, MAX_ALLOCATION);
    }

    function getPoolBalanceUsd(
        IMarket market,
        ILiquidityVault liquidityVault,
        uint256 _collateralTokenPrice,
        uint256 _collateralBaseUnits,
        bool _isLong
    ) public view returns (uint256 poolUsd) {
        // get the liquidity allocated to the market for that side
        uint256 allocationInTokens = getPoolBalance(market, liquidityVault, _isLong);
        // convert to usd
        poolUsd = mulDiv(allocationInTokens, _collateralTokenPrice, _collateralBaseUnits);
    }

    function validateAllocation(
        IMarket market,
        ILiquidityVault liquidityVault,
        uint256 _sizeDeltaUsd,
        uint256 _collateralTokenPrice,
        uint256 _indexTokenPrice,
        uint256 _collateralBaseUnit,
        uint256 _indexBaseUnit,
        bool _isLong
    ) external view {
        // Get Max OI for side
        uint256 maxOiUsd =
            getMaxOpenInterestUsd(market, liquidityVault, _collateralTokenPrice, _collateralBaseUnit, _isLong);
        // Get Current OI for side
        uint256 currentOiUsd = getOpenInterestUsd(market, _indexTokenPrice, _indexBaseUnit, _isLong);
        // Check SizeDelta USD won't push the OI over the max
        require(currentOiUsd + _sizeDeltaUsd <= maxOiUsd, "MarketUtils: Max OI exceeded");
    }

    function getMaxOpenInterestUsd(
        IMarket market,
        ILiquidityVault liquidityVault,
        uint256 _collateralTokenPrice,
        uint256 _collateralBaseUnit,
        bool _isLong
    ) public view returns (uint256 maxOI) {
        // get the allocation and subtract by the markets reserveFactor
        uint256 allocationUsd =
            getPoolBalanceUsd(market, liquidityVault, _collateralTokenPrice, _collateralBaseUnit, _isLong);
        uint256 reserveFactor = market.getReserveFactor();
        maxOI = allocationUsd - mulDiv(allocationUsd, reserveFactor, SCALAR);
    }

    // The pnl factor is the ratio of the pnl to the pool usd
    function getPnlFactor(
        IMarket market,
        ILiquidityVault liquidityVault,
        uint256 _collateralPrice,
        uint256 _collateralBaseUnit,
        uint256 _indexPrice,
        uint256 _indexBaseUnit,
        bool _isLong
    ) external view returns (int256 pnlFactor) {
        // get pool usd ( if 0 return 0)
        uint256 poolUsd = getPoolBalanceUsd(market, liquidityVault, _collateralPrice, _collateralBaseUnit, _isLong);
        if (poolUsd == 0) {
            return 0;
        }
        // get pnl
        int256 pnl = Pricing.getPnl(market, _indexPrice, _indexBaseUnit, _isLong);

        uint256 factor = mulDiv(pnl.abs(), SCALAR, poolUsd);
        return pnl > 0 ? factor.toInt256() : factor.toInt256() * -1;
    }
}
