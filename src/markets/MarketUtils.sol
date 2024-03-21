// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IMarket} from "./interfaces/IMarket.sol";
import {mulDiv} from "@prb/math/Common.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {Pricing} from "../libraries/Pricing.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {console} from "forge-std/Test.sol";

library MarketUtils {
    using SignedMath for int256;
    using SafeCast for uint256;

    uint256 public constant SCALAR = 1e18;
    uint256 public constant MAX_ALLOCATION = 10000;

    error MarketUtils_MaxOiExceeded();

    function getTotalOiForMarket(IMarket market, bool _isLong) external view returns (uint256) {
        // get all asset ids from the market
        bytes32[] memory assetIds = market.getAssetIds();
        uint256 len = assetIds.length;
        // loop through all asset ids and sum the open interest
        uint256 totalOi;
        for (uint256 i = 0; i < len;) {
            totalOi += market.getOpenInterest(assetIds[i], _isLong);
            unchecked {
                ++i;
            }
        }
        return totalOi;
    }

    function getOpenInterestUsd(IMarket market, bytes32 _assetId, bool _isLong) external view returns (uint256) {
        return market.getOpenInterest(_assetId, _isLong);
    }

    function getTotalPoolBalanceUsd(
        IMarket market,
        bytes32 _assetId,
        uint256 _longTokenPrice,
        uint256 _shortTokenPrice,
        uint256 _longBaseUnit,
        uint256 _shortBaseUnit
    ) external view returns (uint256 poolBalanceUsd) {
        uint256 longPoolUsd = getPoolBalanceUsd(market, _assetId, _longTokenPrice, _longBaseUnit, true);
        uint256 shortPoolUsd = getPoolBalanceUsd(market, _assetId, _shortTokenPrice, _shortBaseUnit, false);
        poolBalanceUsd = longPoolUsd + shortPoolUsd;
    }

    // In Index Tokens
    function getPoolBalance(IMarket market, bytes32 _assetId, bool _isLong) public view returns (uint256 poolAmount) {
        // get the allocation percentage
        uint256 allocationPercentage = market.getAllocation(_assetId);
        // get the total liquidity available for that side
        uint256 totalAvailableLiquidity = market.totalAvailableLiquidity(_isLong);
        // calculate liquidity allocated to the market for that side
        poolAmount = mulDiv(totalAvailableLiquidity, allocationPercentage, MAX_ALLOCATION);
    }

    function getPoolBalanceUsd(
        IMarket market,
        bytes32 _assetId,
        uint256 _collateralTokenPrice,
        uint256 _collateralBaseUnits,
        bool _isLong
    ) public view returns (uint256 poolUsd) {
        // get the liquidity allocated to the market for that side
        uint256 allocationInTokens = getPoolBalance(market, _assetId, _isLong);
        // convert to usd
        poolUsd = mulDiv(allocationInTokens, _collateralTokenPrice, _collateralBaseUnits);
    }

    function validateAllocation(
        IMarket market,
        bytes32 _assetId,
        uint256 _sizeDeltaUsd,
        uint256 _collateralTokenPrice,
        uint256 _collateralBaseUnit,
        bool _isLong
    ) external view {
        // Get Max OI for side
        uint256 availableUsd = getAvailableOiUsd(market, _assetId, _collateralTokenPrice, _collateralBaseUnit, _isLong);
        // Check SizeDelta USD won't push the OI over the max
        if (_sizeDeltaUsd > availableUsd) revert MarketUtils_MaxOiExceeded();
    }

    function getTotalAvailableOiUsd(
        IMarket market,
        bytes32 _assetId,
        uint256 _longTokenPrice,
        uint256 _shortTokenPrice,
        uint256 _longBaseUnit,
        uint256 _shortBaseUnit
    ) external view returns (uint256 totalAvailableOiUsd) {
        uint256 longOiUsd = getAvailableOiUsd(market, _assetId, _longTokenPrice, _longBaseUnit, true);
        uint256 shortOiUsd = getAvailableOiUsd(market, _assetId, _shortTokenPrice, _shortBaseUnit, false);
        totalAvailableOiUsd = longOiUsd + shortOiUsd;
    }

    /// @notice returns the available remaining open interest for a side in USD
    function getAvailableOiUsd(
        IMarket market,
        bytes32 _assetId,
        uint256 _collateralTokenPrice,
        uint256 _collateralBaseUnit,
        bool _isLong
    ) public view returns (uint256 availableOi) {
        // get the allocation and subtract by the markets reserveFactor
        uint256 remainingAllocationUsd =
            getPoolBalanceUsd(market, _assetId, _collateralTokenPrice, _collateralBaseUnit, _isLong);
        uint256 reserveFactor = market.getReserveFactor(_assetId);
        availableOi = remainingAllocationUsd - mulDiv(remainingAllocationUsd, reserveFactor, SCALAR);
    }

    // The pnl factor is the ratio of the pnl to the pool usd
    function getPnlFactor(
        IMarket market,
        bytes32 _assetId,
        uint256 _indexPrice,
        uint256 _indexBaseUnit,
        uint256 _collateralPrice,
        uint256 _collateralBaseUnit,
        bool _isLong
    ) external view returns (int256 pnlFactor) {
        // get pool usd (if 0 return 0)
        uint256 poolUsd = getPoolBalanceUsd(market, _assetId, _collateralPrice, _collateralBaseUnit, _isLong);
        if (poolUsd == 0) {
            return 0;
        }
        // get pnl
        int256 pnl = Pricing.getMarketPnl(market, _assetId, _indexPrice, _indexBaseUnit, _isLong);

        uint256 factor = mulDiv(pnl.abs(), SCALAR, poolUsd);
        return pnl > 0 ? factor.toInt256() : factor.toInt256() * -1;
    }
}
