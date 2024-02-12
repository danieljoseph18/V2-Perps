// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {mulDiv} from "@prb/math/Common.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {LiquidityVault} from "../liquidity/LiquidityVault.sol";
import {TradeStorage} from "../positions/TradeStorage.sol";
import {Position} from "../positions/Position.sol";

library Fee {
    using SignedMath for int256;

    uint256 public constant SCALING_FACTOR = 1e18;

    // Functions to calculate fees for deposit and withdrawal.
    function calculateForMarket(LiquidityVault _liquidityVault, uint256 _amountIn)
        external
        view
        returns (uint256 fee)
    {
        uint256 depositFee = _liquidityVault.depositFee();
        fee = mulDiv(_amountIn, depositFee, SCALING_FACTOR);
    }

    function calculateForPosition(
        TradeStorage _tradeStorage,
        uint256 _sizeDelta,
        uint256 _indexPrice,
        uint256 _indexBaseUnit,
        uint256 _collateralPrice
    ) external view returns (uint256 fee) {
        uint256 feePercentage = _tradeStorage.tradingFee();
        // convert index amount to collateral amount
        uint256 sizeInCollateral =
            Position.convertIndexAmountToCollateral(_sizeDelta, _indexPrice, _indexBaseUnit, _collateralPrice);
        // calculate fee
        fee = mulDiv(sizeInCollateral, feePercentage, SCALING_FACTOR);
    }
}
