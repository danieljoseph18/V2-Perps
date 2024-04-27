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
    uint256 internal constant MAX_UINT256 = 2 ** 256 - 1;
    uint256 internal constant WAD = 1e18; // The scalar of ETH and most ERC20s.

    /// @dev Converts an Amount in Tokens to a USD amount
    function toUsd(uint256 _amount, uint256 _price, uint256 _baseUnit) internal pure returns (uint256) {
        return mulDiv(_amount, _price, _baseUnit);
    }

    /// @dev Converts an Amount in USD (uint) to an amount in Tokens
    function fromUsd(uint256 _usdAmount, uint256 _price, uint256 _baseUnit) internal pure returns (uint256) {
        return mulDiv(_usdAmount, _baseUnit, _price);
    }

    /// @dev Converts an Amount in USD (int) to an amount in Tokens
    function fromUsdSigned(int256 _usdAmount, uint256 _price, uint256 _baseUnit) internal pure returns (uint256) {
        return mulDiv(_usdAmount.abs(), _baseUnit, _price);
    }

    /// @dev Converts an Amount in USD (int) to an amount in Tokens (int)
    function fromUsdToSigned(int256 _usdAmount, uint256 _price, uint256 _baseUnit) internal pure returns (int256) {
        return mulDivSigned(_usdAmount, _baseUnit.toInt256(), _price.toInt256());
    }

    /// @dev Returns the percentage of an Amount to 18 D.P
    function percentage(uint256 _amount, uint256 _percentage) internal pure returns (uint256) {
        return mulDiv(_amount, _percentage, PRECISION);
    }

    /// @dev Returns the percentage of an Amount with a custom denominator
    function percentage(uint256 _amount, uint256 _numerator, uint256 _denominator) internal pure returns (uint256) {
        return mulDiv(_amount, _numerator, _denominator);
    }

    /// @dev Returns the percentage of an Amount (int) with a custom denominator
    function percentageSigned(int256 _amount, uint256 _numerator, uint256 _denominator)
        internal
        pure
        returns (int256)
    {
        return mulDivSigned(_amount, _numerator.toInt256(), _denominator.toInt256());
    }

    /// @dev Returns the percentage of an Amount (int) with a custom denominator as an integer
    function percentageInt(int256 _amount, int256 _numerator) internal pure returns (int256) {
        return mulDivSigned(_amount, _numerator, SIGNED_PRECISION);
    }

    /// @dev Returns the percentage of a USD Amount (int) with a custom denominator as an integer
    function percentageUsd(int256 _usdAmount, int256 _numerator) internal pure returns (int256) {
        return mulDivSigned(_usdAmount, _numerator, PRICE_PRECISION);
    }

    /// @dev Returns X / Y to 18 D.P
    function div(uint256 _amount, uint256 _divisor) internal pure returns (uint256) {
        return mulDiv(_amount, PRECISION, _divisor);
    }

    function ceilDiv(uint256 _amount, uint256 _divisor) internal pure returns (uint256) {
        return mulDivCeil(_amount, PRECISION, _divisor);
    }

    function mulDivCeil(uint256 a, uint256 b, uint256 denominator) public pure returns (uint256 result) {
        result = mulDiv(a, b, denominator);
        if (a * b % denominator > 0) {
            result += 1;
        }
    }

    /// @dev Returns X * Y to 18 D.P
    function mul(uint256 _amount, uint256 _multiplier) internal pure returns (uint256) {
        return mulDiv(_amount, _multiplier, PRECISION);
    }

    /// @dev Returns the delta between x and y in integer form, so the final result can be negative.
    function diff(uint256 x, uint256 y) internal pure returns (int256) {
        return x.toInt256() - y.toInt256();
    }

    /// @dev Returns the absolute delta between x and y
    function delta(uint256 x, uint256 y) internal pure returns (uint256) {
        return x > y ? x - y : y - x;
    }

    function squared(uint256 x) internal pure returns (uint256 xSquared) {
        xSquared = mulDiv(x, x, PRECISION);
    }

    function expandDecimals(uint256 x, uint256 decimalsFrom, uint256 decimalsTo) internal pure returns (uint256) {
        return x * (10 ** (decimalsTo - decimalsFrom));
    }

    function expandDecimals(int256 x, uint256 decimalsFrom, uint256 decimalsTo) internal pure returns (int256) {
        return x * int256(10 ** (decimalsTo - decimalsFrom));
    }

    function wadExp(int256 x) internal pure returns (int256 r) {
        unchecked {
            // When the result is < 0.5 we return zero. This happens when
            // x <= floor(log(0.5e18) * 1e18) ~ -42e18
            if (x <= -42139678854452767551) return 0;

            // When the result is > (2**255 - 1) / 1e18 we can not represent it as an
            // int. This happens when x >= floor(log((2**255 - 1) / 1e18) * 1e18) ~ 135.
            if (x >= 135305999368893231589) revert("EXP_OVERFLOW");

            // x is now in the range (-42, 136) * 1e18. Convert to (-42, 136) * 2**96
            // for more intermediate precision and a binary basis. This base conversion
            // is a multiplication by 1e18 / 2**96 = 5**18 / 2**78.
            x = (x << 78) / 5 ** 18;

            // Reduce range of x to (-½ ln 2, ½ ln 2) * 2**96 by factoring out powers
            // of two such that exp(x) = exp(x') * 2**k, where k is an integer.
            // Solving this gives k = round(x / log(2)) and x' = x - k * log(2).
            int256 k = ((x << 96) / 54916777467707473351141471128 + 2 ** 95) >> 96;
            x = x - k * 54916777467707473351141471128;

            // k is in the range [-61, 195].

            // Evaluate using a (6, 7)-term rational approximation.
            // p is made monic, we'll multiply by a scale factor later.
            int256 y = x + 1346386616545796478920950773328;
            y = ((y * x) >> 96) + 57155421227552351082224309758442;
            int256 p = y + x - 94201549194550492254356042504812;
            p = ((p * y) >> 96) + 28719021644029726153956944680412240;
            p = p * x + (4385272521454847904659076985693276 << 96);

            // We leave p in 2**192 basis so we don't need to scale it back up for the division.
            int256 q = x - 2855989394907223263936484059900;
            q = ((q * x) >> 96) + 50020603652535783019961831881945;
            q = ((q * x) >> 96) - 533845033583426703283633433725380;
            q = ((q * x) >> 96) + 3604857256930695427073651918091429;
            q = ((q * x) >> 96) - 14423608567350463180887372962807573;
            q = ((q * x) >> 96) + 26449188498355588339934803723976023;

            /// @solidity memory-safe-assembly
            assembly {
                // Div in assembly because solidity adds a zero check despite the unchecked.
                // The q polynomial won't have zeros in the domain as all its roots are complex.
                // No scaling is necessary because p is already 2**96 too large.
                r := sdiv(p, q)
            }

            // r should be in the range (0.09, 0.25) * 2**96.

            // We now need to multiply r by:
            // * the scale factor s = ~6.031367120.
            // * the 2**k factor from the range reduction.
            // * the 1e18 / 2**96 factor for base conversion.
            // We do this all at once, with an intermediate result in 2**213
            // basis, so the final right shift is always by a positive amount.
            r = int256((uint256(r) * 3822833074963236453042738258902158003155416615667) >> uint256(195 - k));
        }
    }

    function divWadUp(uint256 x, uint256 y) internal pure returns (uint256) {
        return mulDivUp(x, WAD, y); // Equivalent to (x * WAD) / y rounded up.
    }

    function mulDivUp(uint256 x, uint256 y, uint256 denominator) internal pure returns (uint256 z) {
        /// @solidity memory-safe-assembly
        assembly {
            // Equivalent to require(denominator != 0 && (y == 0 || x <= type(uint256).max / y))
            if iszero(mul(denominator, iszero(mul(y, gt(x, div(MAX_UINT256, y)))))) { revert(0, 0) }

            // If x * y modulo the denominator is strictly greater than 0,
            // 1 is added to round up the division of x * y by the denominator.
            z := add(gt(mod(mul(x, y), denominator), 0), div(mul(x, y), denominator))
        }
    }
}
