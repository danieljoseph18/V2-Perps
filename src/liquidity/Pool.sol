// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {mulDiv} from "@prb/math/Common.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {Oracle} from "../oracle/Oracle.sol";
import {ILiquidityVault} from "./interfaces/ILiquidityVault.sol";

library Pool {
    using SignedMath for int256;

    uint256 public constant SCALING_FACTOR = 1e18;

    struct Values {
        uint256 longTokenBalance;
        uint256 shortTokenBalance;
        uint256 marketTokenSupply;
        uint256 longBaseUnit;
        uint256 shortBaseUnit;
    }

    function calculateUsdValue(
        bool _isLongToken,
        uint256 _longBaseUnit,
        uint256 _shortBaseUnit,
        uint256 _price,
        uint256 _amount
    ) external pure returns (uint256 valueUsd) {
        if (_isLongToken) {
            valueUsd = mulDiv(_amount, _price, _longBaseUnit);
        } else {
            valueUsd = mulDiv(_amount, _price, _shortBaseUnit);
        }
    }

    function depositTokensToMarketTokens(
        Values memory _values,
        Oracle.Price memory _longPrices,
        Oracle.Price memory _shortPrices,
        uint256 _amountIn,
        int256 _cumulativePnl,
        bool _isLongToken
    ) external pure returns (uint256 marketTokenAmount) {
        // Minimise
        uint256 valueUsd = _isLongToken
            ? mulDiv(_amountIn, _longPrices.price - _longPrices.confidence, _values.longBaseUnit)
            : mulDiv(_amountIn, _shortPrices.price - _shortPrices.confidence, _values.shortBaseUnit);
        // Maximise
        uint256 marketTokenPrice = getMarketTokenPrice(
            _values,
            _longPrices.price + _longPrices.confidence,
            _shortPrices.price + _shortPrices.confidence,
            _cumulativePnl
        );
        return marketTokenPrice == 0 ? valueUsd : mulDiv(valueUsd, SCALING_FACTOR, marketTokenPrice);
    }

    function withdrawMarketTokensToTokens(
        Values memory _values,
        Oracle.Price memory _longPrices,
        Oracle.Price memory _shortPrices,
        uint256 _marketTokenAmountIn,
        int256 _cumulativePnl,
        bool _isLongToken
    ) external pure returns (uint256 tokenAmount) {
        uint256 marketTokenPrice = getMarketTokenPrice(
            _values,
            _longPrices.price - _longPrices.confidence,
            _shortPrices.price - _shortPrices.confidence,
            _cumulativePnl
        );
        uint256 valueUsd = mulDiv(_marketTokenAmountIn, marketTokenPrice, SCALING_FACTOR);
        if (_isLongToken) {
            tokenAmount = mulDiv(valueUsd, _values.longBaseUnit, _longPrices.price + _longPrices.confidence);
        } else {
            tokenAmount = mulDiv(valueUsd, _values.shortBaseUnit, _shortPrices.price + _shortPrices.confidence);
        }
    }

    function getMarketTokenPrice(
        Values memory _values,
        uint256 _longTokenPrice,
        uint256 _shortTokenPrice,
        int256 _cumulativePnl
    ) public pure returns (uint256 lpTokenPrice) {
        // market token price = (worth of market pool in USD) / total supply
        uint256 aum = getAum(_values, _longTokenPrice, _shortTokenPrice, _cumulativePnl);
        if (aum == 0 || _values.marketTokenSupply == 0) {
            lpTokenPrice = 0;
        } else {
            lpTokenPrice = mulDiv(aum, SCALING_FACTOR, _values.marketTokenSupply);
        }
    }

    // @audit - probably need to account for some fees
    function getAum(Values memory _values, uint256 _longTokenPrice, uint256 _shortTokenPrice, int256 _cumulativePnl)
        public
        pure
        returns (uint256 aum)
    {
        // Get Values in USD
        uint256 longTokenValue = mulDiv(_values.longTokenBalance, _longTokenPrice, _values.longBaseUnit);
        uint256 shortTokenValue = mulDiv(_values.shortTokenBalance, _shortTokenPrice, _values.shortBaseUnit);

        // Calculate AUM
        aum = _cumulativePnl >= 0
            ? longTokenValue + shortTokenValue + _cumulativePnl.abs()
            : longTokenValue + shortTokenValue - _cumulativePnl.abs();
    }

    function getValues(ILiquidityVault liquidityVault) external view returns (Values memory values) {
        (
            values.longTokenBalance,
            values.shortTokenBalance,
            values.marketTokenSupply,
            values.longBaseUnit,
            values.shortBaseUnit
        ) = liquidityVault.getPoolValues();
    }
}
