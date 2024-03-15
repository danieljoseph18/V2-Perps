// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {mulDiv} from "@prb/math/Common.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {ITradeStorage} from "../positions/interfaces/ITradeStorage.sol";
import {Position} from "../positions/Position.sol";
import {Oracle} from "../oracle/Oracle.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {IVault} from "../markets/interfaces/IVault.sol";

library Fee {
    using SignedMath for int256;

    uint256 public constant SCALING_FACTOR = 1e18;

    error Fee_TokenAmountTooSmall();

    struct Params {
        IMarket market;
        uint256 tokenAmount;
        bool isLongToken;
        Oracle.Price longPrices;
        Oracle.Price shortPrices;
        bool isDeposit;
    }

    struct State {
        uint256 baseFee;
        uint256 amountUsd;
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
        IMarket market,
        uint256 _tokenAmount,
        bool _isLongToken,
        Oracle.Price memory _longPrices,
        Oracle.Price memory _shortPrices,
        bool _isDeposit
    ) external pure returns (Params memory) {
        return Params({
            market: market,
            tokenAmount: _tokenAmount,
            isLongToken: _isLongToken,
            longPrices: _longPrices,
            shortPrices: _shortPrices,
            isDeposit: _isDeposit
        });
    }

    // @gas
    function calculateForMarketAction(
        Params memory _params,
        uint256 _longTokenBalance,
        uint256 _longBaseUnit,
        uint256 _shortTokenBalance,
        uint256 _shortBaseUnit
    ) external view returns (uint256) {
        State memory state;
        // get the base fee
        state.baseFee = mulDiv(_params.tokenAmount, _params.market.BASE_FEE(), SCALING_FACTOR);

        // Convert skew to USD values and calculate amountUsd once
        state.amountUsd = _params.isLongToken
            ? mulDiv(_params.tokenAmount, _params.longPrices.price + _params.longPrices.confidence, _longBaseUnit)
            : mulDiv(_params.tokenAmount, _params.shortPrices.price + _params.shortPrices.confidence, _shortBaseUnit);

        // If Size Delta * Price < Base Unit -> Action has no effect on skew
        if (state.amountUsd == 0) {
            revert Fee_TokenAmountTooSmall();
        }

        // Calculate pool balances before and minimise value of pool to maximise the effect on the skew
        state.longTokenValue =
            mulDiv(_longTokenBalance, _params.longPrices.price - _params.longPrices.confidence, _longBaseUnit);
        state.shortTokenValue =
            mulDiv(_shortTokenBalance, _params.shortPrices.price - _params.shortPrices.confidence, _shortBaseUnit);

        // Don't want to disincentivise deposits on empty pool
        if (state.longTokenValue == 0 && state.shortTokenValue == 0) {
            return state.baseFee;
        }

        // get the skew of the market
        if (state.longTokenValue > state.shortTokenValue) {
            state.longSkewBefore = true;
            state.skewBefore = state.longTokenValue - state.shortTokenValue;
        } else {
            state.longSkewBefore = false;
            state.skewBefore = state.shortTokenValue - state.longTokenValue;
        }

        // Adjust long or short token value based on the operation
        if (_params.isLongToken) {
            state.longTokenValue =
                _params.isDeposit ? state.longTokenValue += state.amountUsd : state.longTokenValue -= state.amountUsd;
        } else {
            state.shortTokenValue =
                _params.isDeposit ? state.shortTokenValue += state.amountUsd : state.shortTokenValue -= state.amountUsd;
        }

        if (state.longTokenValue > state.shortTokenValue) {
            state.longSkewAfter = true;
            state.skewAfter = state.longTokenValue - state.shortTokenValue;
        } else {
            state.longSkewAfter = false;
            state.skewAfter = state.shortTokenValue - state.longTokenValue;
        }
        state.skewFlip = state.longSkewAfter != state.longSkewBefore;

        // Calculate the additional fee if necessary
        if (state.skewFlip || state.skewAfter > state.skewBefore) {
            // Get the Delta to Charge the Fee on
            // For Skew Flips, the delta is the skew after the flip -> skew before improved market balance
            state.skewDelta = state.skewFlip ? state.skewAfter : state.amountUsd;
            // Calculate the additional fee
            // Uses the original value for LTV + STV so SkewDelta is never > LTV + STV
            state.feeAdditionUsd = mulDiv(
                state.skewDelta,
                _params.market.feeScale(),
                state.longTokenValue + state.shortTokenValue + state.amountUsd
            );

            // Convert the additional fee to index tokens
            state.indexFee = _params.isLongToken
                ? mulDiv(state.feeAdditionUsd, _longBaseUnit, _params.longPrices.price + _params.longPrices.confidence)
                : mulDiv(state.feeAdditionUsd, _shortBaseUnit, _params.shortPrices.price + _params.shortPrices.confidence);

            // Return base fee + additional fee
            return state.baseFee + state.indexFee;
        }

        // If no skew flip and skew improved, return base fee
        return state.baseFee;
    }

    function calculateForPosition(
        ITradeStorage tradeStorage,
        uint256 _tokenAmount,
        uint256 _collateralDelta,
        uint256 _collateralPrice,
        uint256 _collateralBaseUnit
    ) external view returns (uint256 fee) {
        uint256 feePercentage = tradeStorage.tradingFee();
        // convert index amount to collateral amount
        if (_tokenAmount != 0) {
            uint256 sizeInCollateral =
                Position.convertUsdToCollateral(_tokenAmount, _collateralPrice, _collateralBaseUnit);
            // calculate fee
            fee = mulDiv(sizeInCollateral, feePercentage, SCALING_FACTOR);
        } else {
            fee = mulDiv(_collateralDelta, feePercentage, SCALING_FACTOR);
        }
    }
}
