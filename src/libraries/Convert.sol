// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {mulDiv} from "@prb/math/Common.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";

// Don't like these names so we'll clean this up later.
library Convert {
    using SignedMath for int256;

    uint64 private constant PRECISION = 1e18;

    // Converts an uint256 amount to a USD amount
    function toUsd(uint256 _amount, uint256 _price, uint256 _baseUnit) external pure returns (uint256) {
        return mulDiv(_amount, _price, _baseUnit);
    }

    // Converts an uint256 amount to a base unit amount
    function toBase(uint256 _amount, uint256 _price, uint256 _baseUnit) external pure returns (uint256) {
        return mulDiv(_amount, _baseUnit, _price);
    }

    // Converts an int256 amount to a base unit amount
    function toBase(int256 _amount, uint256 _price, uint256 _baseUnit) external pure returns (uint256) {
        return mulDiv(_amount.abs(), _baseUnit, _price);
    }

    // Takes in a Percentage with 18 decimals of precision and returns that percentage of _amount
    function percentage(uint256 _amount, uint256 _percentage) external pure returns (uint256) {
        return mulDiv(_amount, _percentage, PRECISION);
    }

    function percentage(uint256 _amount, uint256 _numerator, uint256 _denominator) external pure returns (uint256) {
        return mulDiv(_amount, _numerator, _denominator);
    }
}
