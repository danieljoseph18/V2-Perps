// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Casting} from "./Casting.sol";
import {MathUtils} from "./MathUtils.sol";

library Units {
    using Casting for uint256;
    using Casting for int256;
    using MathUtils for uint256;
    using MathUtils for int256;

    uint64 private constant UNIT = 1e18;
    int64 private constant sUNIT = 1e18;
    int128 private constant PRICE_UNIT = 1e30;

    /// @dev Converts an Amount in Tokens to a USD amount
    function toUsd(uint256 _amount, uint256 _price, uint256 _baseUnit) internal pure returns (uint256) {
        return _amount.mulDiv(_price, _baseUnit);
    }

    /// @dev Converts an Amount in USD (uint) to an amount in Tokens
    function fromUsd(uint256 _usdAmount, uint256 _price, uint256 _baseUnit) internal pure returns (uint256) {
        return _usdAmount.mulDiv(_baseUnit, _price);
    }

    /// @dev Converts an Amount in USD (int) to an amount in Tokens
    function fromUsdSigned(int256 _usdAmount, uint256 _price, uint256 _baseUnit) internal pure returns (uint256) {
        return _usdAmount.abs().mulDiv(_baseUnit, _price);
    }

    /// @dev Converts an Amount in USD (int) to an amount in Tokens (int)
    function fromUsdToSigned(int256 _usdAmount, uint256 _price, uint256 _baseUnit) internal pure returns (int256) {
        return _usdAmount.mulDivSigned(_baseUnit.toInt256(), _price.toInt256());
    }

    /// @dev Returns the percentage of an Amount to 18 D.P
    function percentage(uint256 _amount, uint256 _percentage) internal pure returns (uint256) {
        return _amount.mulDiv(_percentage, UNIT);
    }

    /// @dev Returns the percentage of an Amount with a custom denominator
    function percentage(uint256 _amount, uint256 _numerator, uint256 _denominator) internal pure returns (uint256) {
        return _amount.mulDiv(_numerator, _denominator);
    }

    /// @dev Returns the percentage of an Amount (int) with a custom denominator
    function percentageSigned(int256 _amount, uint256 _numerator, uint256 _denominator)
        internal
        pure
        returns (int256)
    {
        return _amount.mulDivSigned(_numerator.toInt256(), _denominator.toInt256());
    }

    /// @dev Returns the percentage of an Amount (int) with a custom denominator as an integer
    function percentageInt(int256 _amount, int256 _numerator) internal pure returns (int256) {
        return _amount.mulDivSigned(_numerator, sUNIT);
    }

    /// @dev Returns the percentage of a USD Amount (int) with a custom denominator as an integer
    function percentageUsd(int256 _usdAmount, int256 _numerator) internal pure returns (int256) {
        return _usdAmount.mulDivSigned(_numerator, PRICE_UNIT);
    }
}
