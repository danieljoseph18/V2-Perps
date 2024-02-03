// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";

library Fee {
    using SignedMath for int256;

    uint256 public constant SCALING_FACTOR = 1e18;
    uint256 public constant MIN_FEE = 0.0001e18; // 0.01%
    uint256 public constant MAX_FEE = 0.003e18; // 0.3%

    // Functions to calculate fees for deposit and withdrawal.
    function calculateForMarketAction(
        uint256 _indexAmount,
        uint256 _longTokenAmount,
        uint256 _longTokenPrice,
        uint256 _longBaseUnit,
        uint256 _shortTokenAmount,
        uint256 _shortTokenPrice,
        uint256 _shortBaseUnit,
        bool _isLongToken
    ) external pure returns (uint256 fee) {
        (int256 skew, uint256 totalValue) = _calculateMarketSkew(
            _indexAmount,
            _longTokenAmount,
            _longTokenPrice,
            _longBaseUnit,
            _shortTokenAmount,
            _shortTokenPrice,
            _shortBaseUnit,
            _isLongToken
        );
        uint256 dynamicFee = _adjustedFee(skew, totalValue);
        fee = Math.mulDiv(_indexAmount, dynamicFee, SCALING_FACTOR);
        require(fee < MAX_FEE && fee > MIN_FEE, "Fee: fee out of range");
    }

    // Function to calculate the USD value skew between long and short tokens of the market.
    function _calculateMarketSkew(
        uint256 _indexAmount,
        uint256 _longTokenAmount,
        uint256 _longTokenPrice,
        uint256 _longBaseUnit,
        uint256 _shortTokenAmount,
        uint256 _shortTokenPrice,
        uint256 _shortBaseUnit,
        bool _isLongToken
    ) internal pure returns (int256 skew, uint256 totalValue) {
        int256 longValueUSD = int256(_longTokenAmount * _longTokenPrice / _longBaseUnit);
        int256 shortValueUSD = int256(_shortTokenAmount * _shortTokenPrice / _shortBaseUnit);
        if (_isLongToken) {
            longValueUSD += int256(_indexAmount);
        } else {
            shortValueUSD += int256(_indexAmount);
        }
        skew = longValueUSD - shortValueUSD;
        totalValue = longValueUSD.abs() + shortValueUSD.abs();
    }

    // Updated function to adjust the fee based on the skew value.
    function _adjustedFee(int256 _skew, uint256 _totalValue) internal pure returns (uint256 fee) {
        if (_totalValue == 0 || _skew == 0) {
            return MIN_FEE; // Default fee for zero total value or balanced skew
        }
        uint256 feeRange = MAX_FEE - MIN_FEE;
        uint256 feeAdjustment = Math.mulDiv(_skew.abs(), feeRange, _totalValue);
        fee = MIN_FEE + feeAdjustment;
        // Ensuring the fee stays within bounds
        if (fee > MAX_FEE) {
            fee = MAX_FEE;
        } else if (fee < MIN_FEE) {
            fee = MIN_FEE;
        }
    }
}
