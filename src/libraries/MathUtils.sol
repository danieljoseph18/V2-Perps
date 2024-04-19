// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {mulDiv, mulDivSigned} from "@prb/math/Common.sol";
import {SignedMath} from "./SignedMath.sol";
import {SafeCast} from "./SafeCast.sol";

library MathUtils {
    using SignedMath for int256;
    using SafeCast for uint256;

    uint64 private constant PRECISION = 1e18;
    int64 private constant SIGNED_PRECISION = 1e18;
    int128 private constant PRICE_PRECISION = 1e30;

    /// @dev Converts an Amount in Tokens to a USD amount
    function toUsd(uint256 _amount, uint256 _price, uint256 _baseUnit) external pure returns (uint256) {
        return mulDiv(_amount, _price, _baseUnit);
    }

    /// @dev Converts an Amount in USD (uint) to an amount in Tokens
    function fromUsd(uint256 _usdAmount, uint256 _price, uint256 _baseUnit) external pure returns (uint256) {
        return mulDiv(_usdAmount, _baseUnit, _price);
    }

    /// @dev Converts an Amount in USD (int) to an amount in Tokens
    function fromUsdSigned(int256 _usdAmount, uint256 _price, uint256 _baseUnit) external pure returns (uint256) {
        return mulDiv(_usdAmount.abs(), _baseUnit, _price);
    }

    /// @dev Converts an Amount in USD (int) to an amount in Tokens (int)
    function fromUsdToSigned(int256 _usdAmount, uint256 _price, uint256 _baseUnit) external pure returns (int256) {
        return mulDivSigned(_usdAmount, _baseUnit.toInt256(), _price.toInt256());
    }

    /// @dev Returns the percentage of an Amount to 18 D.P
    function percentage(uint256 _amount, uint256 _percentage) external pure returns (uint256) {
        return mulDiv(_amount, _percentage, PRECISION);
    }

    /// @dev Returns the percentage of an Amount with a custom denominator
    function percentage(uint256 _amount, uint256 _numerator, uint256 _denominator) external pure returns (uint256) {
        return mulDiv(_amount, _numerator, _denominator);
    }

    /// @dev Returns the percentage of an Amount (int) with a custom denominator
    function percentageSigned(int256 _amount, uint256 _numerator, uint256 _denominator)
        external
        pure
        returns (int256)
    {
        return mulDivSigned(_amount, _numerator.toInt256(), _denominator.toInt256());
    }

    /// @dev Returns the percentage of an Amount (int) with a custom denominator as an integer
    function percentageInt(int256 _amount, int256 _numerator) external pure returns (int256) {
        return mulDivSigned(_amount, _numerator, SIGNED_PRECISION);
    }

    /// @dev Returns the percentage of a USD Amount (int) with a custom denominator as an integer
    function percentageUsd(int256 _usdAmount, int256 _numerator) external pure returns (int256) {
        return mulDivSigned(_usdAmount, _numerator, PRICE_PRECISION);
    }

    /// @dev Returns X / Y to 18 D.P
    function div(uint256 _amount, uint256 _divisor) external pure returns (uint256) {
        return mulDiv(_amount, PRECISION, _divisor);
    }

    function ceilDiv(uint256 _amount, uint256 _divisor) external pure returns (uint256) {
        return mulDivCeil(_amount, PRECISION, _divisor);
    }

    function mulDivCeil(uint256 a, uint256 b, uint256 denominator) public pure returns (uint256 result) {
        result = mulDiv(a, b, denominator);
        if (a * b % denominator > 0) {
            result += 1;
        }
    }

    /// @dev Returns X * Y to 18 D.P
    function mul(uint256 _amount, uint256 _multiplier) external pure returns (uint256) {
        return mulDiv(_amount, _multiplier, PRECISION);
    }

    /// @dev Returns the delta between x and y in integer form, so the final result can be negative.
    function diff(uint256 x, uint256 y) external pure returns (int256) {
        return x.toInt256() - y.toInt256();
    }

    /// @dev Returns the absolute delta between x and y
    function delta(uint256 x, uint256 y) external pure returns (uint256) {
        return x > y ? x - y : y - x;
    }

    function squared(uint256 x) external pure returns (uint256 xSquared) {
        xSquared = mulDiv(x, x, PRECISION);
    }

    function expandDecimals(uint256 x, uint256 decimalsFrom, uint256 decimalsTo) external pure returns (uint256) {
        return x * (10 ** (decimalsTo - decimalsFrom));
    }

    function expandDecimals(int256 x, uint256 decimalsFrom, uint256 decimalsTo) external pure returns (int256) {
        return x * int256(10 ** (decimalsTo - decimalsFrom));
    }
}
