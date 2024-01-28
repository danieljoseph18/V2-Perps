// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;
// Library for calculation fees associated with actions

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

library Fee {
    uint256 public constant SCALING_FACTOR = 1e18;
    // Complete

    function calculateForDeposit(uint256 _indexAmount, uint256 _depositFee) external pure returns (uint256 fee) {
        fee = Math.mulDiv(_indexAmount, _depositFee, SCALING_FACTOR);
    }

    function calculateForWithdrawal(uint256 _indexAmountOut, uint256 _withdrawalFee)
        external
        pure
        returns (uint256 fee)
    {
        fee = Math.mulDiv(_indexAmountOut, _withdrawalFee, SCALING_FACTOR);
    }
}
