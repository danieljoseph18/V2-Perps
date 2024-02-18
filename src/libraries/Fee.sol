// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {mulDiv} from "@prb/math/Common.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {ILiquidityVault} from "../liquidity/interfaces/ILiquidityVault.sol";
import {ITradeStorage} from "../positions/interfaces/ITradeStorage.sol";
import {Position} from "../positions/Position.sol";
import {Oracle} from "../oracle/Oracle.sol";
import {Pool} from "../liquidity/Pool.sol";

library Fee {
    using SignedMath for int256;

    uint256 public constant SCALING_FACTOR = 1e18;

    struct Params {
        ILiquidityVault liquidityVault;
        uint256 sizeDelta;
        bool isLongToken;
        Pool.Values values;
        Oracle.Price longPrices;
        Oracle.Price shortPrices;
        bool isDeposit;
    }

    struct Cache {
        uint256 baseFee;
        uint256 sizeDeltaUsd;
        uint256 longTokenValue;
        uint256 shortTokenValue;
        bool longSkewBefore;
        uint256 skewBefore;
        bool longSkewAfter;
        bool skewFlip;
        uint256 skewAfter;
        uint256 skewDelta;
        uint256 feeAdditionUsd;
        uint256 indexFee;
    }

    function constructFeeParams(
        ILiquidityVault _liquidityVault,
        uint256 _sizeDelta,
        bool _isLongToken,
        Pool.Values memory _values,
        Oracle.Price memory _longPrices,
        Oracle.Price memory _shortPrices,
        bool _isDeposit
    ) external pure returns (Params memory) {
        return Params({
            liquidityVault: _liquidityVault,
            sizeDelta: _sizeDelta,
            isLongToken: _isLongToken,
            values: _values,
            longPrices: _longPrices,
            shortPrices: _shortPrices,
            isDeposit: _isDeposit
        });
    }

    function calculateForMarketAction(Params memory _params) external view returns (uint256) {
        Cache memory cache;
        // get the base fee
        cache.baseFee = mulDiv(_params.sizeDelta, _params.liquidityVault.BASE_FEE(), SCALING_FACTOR);

        // Convert skew to USD values and calculate sizeDeltaUsd once
        cache.sizeDeltaUsd = _params.isLongToken
            ? mulDiv(_params.sizeDelta, _params.longPrices.max, _params.values.longBaseUnit)
            : mulDiv(_params.sizeDelta, _params.shortPrices.max, _params.values.shortBaseUnit);

        // If Size Delta * Price < Base Unit -> Action has no effect on skew
        if (cache.sizeDeltaUsd == 0) {
            revert("Fee: Size Delta Too Small");
        }

        // Calculate pool balances before and minimise value of pool to maximise the effect on the skew
        cache.longTokenValue =
            mulDiv(_params.values.longTokenBalance, _params.longPrices.min, _params.values.longBaseUnit);
        cache.shortTokenValue =
            mulDiv(_params.values.shortTokenBalance, _params.shortPrices.min, _params.values.shortBaseUnit);

        // Don't want to disincentivise deposits on empty pool
        if (cache.longTokenValue == 0 && cache.shortTokenValue == 0) {
            return cache.baseFee;
        }

        // get the skew of the market
        if (cache.longTokenValue > cache.shortTokenValue) {
            cache.longSkewBefore = true;
            cache.skewBefore = cache.longTokenValue - cache.shortTokenValue;
        } else {
            cache.longSkewBefore = false;
            cache.skewBefore = cache.shortTokenValue - cache.longTokenValue;
        }

        // Adjust long or short token value based on the operation
        if (_params.isLongToken) {
            cache.longTokenValue = _params.isDeposit
                ? cache.longTokenValue += cache.sizeDeltaUsd
                : cache.longTokenValue -= cache.sizeDeltaUsd;
        } else {
            cache.shortTokenValue = _params.isDeposit
                ? cache.shortTokenValue += cache.sizeDeltaUsd
                : cache.shortTokenValue -= cache.sizeDeltaUsd;
        }

        if (cache.longTokenValue > cache.shortTokenValue) {
            cache.longSkewAfter = true;
            cache.skewAfter = cache.longTokenValue - cache.shortTokenValue;
        } else {
            cache.longSkewAfter = false;
            cache.skewAfter = cache.shortTokenValue - cache.longTokenValue;
        }
        cache.skewFlip = cache.longSkewAfter != cache.longSkewBefore;

        // Calculate the additional fee if necessary
        if (cache.skewFlip || cache.skewAfter > cache.skewBefore) {
            // Get the Delta to Charge the Fee on
            // For Skew Flips, the delta is the skew after the flip -> skew before improved market balance
            cache.skewDelta = cache.skewFlip ? cache.skewAfter : cache.sizeDeltaUsd;
            // Calculate the additional fee
            // Uses the original value for LTV + STV so SkewDelta is never > LTV + STV
            cache.feeAdditionUsd = mulDiv(
                cache.skewDelta,
                _params.liquidityVault.feeScale(),
                cache.longTokenValue + cache.shortTokenValue + cache.sizeDeltaUsd
            );

            // Convert the additional fee to index tokens
            cache.indexFee = _params.isLongToken
                ? mulDiv(cache.feeAdditionUsd, _params.values.longBaseUnit, _params.longPrices.max)
                : mulDiv(cache.feeAdditionUsd, _params.values.shortBaseUnit, _params.shortPrices.max);

            // Return base fee + additional fee
            return cache.baseFee + cache.indexFee;
        }

        // If no skew flip and skew improved, return base fee
        return cache.baseFee;
    }

    function calculateForPosition(
        ITradeStorage tradeStorage,
        uint256 _sizeDelta,
        uint256 _indexPrice,
        uint256 _indexBaseUnit,
        uint256 _collateralPrice
    ) external view returns (uint256 fee) {
        uint256 feePercentage = tradeStorage.tradingFee();
        // convert index amount to collateral amount
        uint256 sizeInCollateral =
            Position.convertIndexAmountToCollateral(_sizeDelta, _indexPrice, _indexBaseUnit, _collateralPrice);
        // calculate fee
        fee = mulDiv(sizeInCollateral, feePercentage, SCALING_FACTOR);
    }
}
