// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {ILiquidityVault} from "../liquidity/interfaces/ILiquidityVault.sol";

library Fee {
    using SignedMath for int256;

    uint256 public constant SCALING_FACTOR = 1e18;

    // Functions to calculate fees for deposit and withdrawal.
    function calculateForMarketAction(ILiquidityVault _liquidityVault, uint256 _amountIn)
        external
        view
        returns (uint256 fee)
    {
        uint256 depositFee = _liquidityVault.depositFee();
        fee = Math.mulDiv(_amountIn, depositFee, SCALING_FACTOR);
    }
}
