// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IMarket} from "./interfaces/IMarket.sol";
import {IMarketToken} from "./interfaces/IMarketToken.sol";
import {mulDiv, mulDivSigned} from "@prb/math/Common.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IPriceFeed} from "../oracle/interfaces/IPriceFeed.sol";
import {Oracle} from "../oracle/Oracle.sol";
import {console, console2} from "forge-std/Test.sol";

library MarketUtils {
    using SignedMath for int256;
    using SafeCast for uint256;

    uint256 constant SCALAR = 1e18;
    uint256 constant BASE_FEE = 0.001e18; // 0.1%
    uint256 public constant MAX_ALLOCATION = 10000;
    uint256 constant LONG_BASE_UNIT = 1e18;
    uint256 constant SHORT_BASE_UNIT = 1e6;
    uint256 constant LONG_CONVERSION_FACTOR = 1e30;
    uint256 constant SHORT_CONVERSION_FACTOR = 1e18;

    error MarketUtils_MaxOiExceeded();
    error MarketUtils_TokenBurnFailed();
    error MarketUtils_DepositAmountIn();
    error MarketUtils_WithdrawalAmountOut();
    error MarketUtils_AmountTooSmall();
    error MarketUtils_InvalidAmountOut(uint256 amountOut, uint256 expectedOut);
    error MarketUtils_TokenMintFailed();

    struct FeeParams {
        IMarket market;
        uint256 tokenAmount;
        bool isLongToken;
        Oracle.Price longPrices;
        Oracle.Price shortPrices;
        bool isDeposit;
    }

    struct FeeState {
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

    // @gas
    function calculateFee(
        IMarket market,
        uint256 _tokenAmount,
        bool _isLongToken,
        Oracle.Price memory _longPrices,
        Oracle.Price memory _shortPrices,
        bool _isDeposit,
        uint256 _longTokenBalance,
        uint256 _shortTokenBalance
    ) public view returns (uint256) {
        FeeState memory state;
        // get the base fee
        state.baseFee = mulDiv(_tokenAmount, market.BASE_FEE(), SCALAR);

        // Convert skew to USD values and calculate amountUsd once
        state.amountUsd = _isLongToken
            ? mulDiv(_tokenAmount, _longPrices.price + _longPrices.confidence, LONG_BASE_UNIT)
            : mulDiv(_tokenAmount, _shortPrices.price + _shortPrices.confidence, SHORT_BASE_UNIT);

        // If Size Delta * Price < Base Unit -> Action has no effect on skew
        if (state.amountUsd == 0) {
            revert MarketUtils_AmountTooSmall();
        }

        // Calculate pool balances before and minimise value of pool to maximise the effect on the skew
        state.longTokenValue = mulDiv(_longTokenBalance, _longPrices.price - _longPrices.confidence, LONG_BASE_UNIT);
        state.shortTokenValue =
            mulDiv(_shortTokenBalance, _shortPrices.price - _shortPrices.confidence, SHORT_BASE_UNIT);

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
        if (_isLongToken) {
            state.longTokenValue =
                _isDeposit ? state.longTokenValue += state.amountUsd : state.longTokenValue -= state.amountUsd;
        } else {
            state.shortTokenValue =
                _isDeposit ? state.shortTokenValue += state.amountUsd : state.shortTokenValue -= state.amountUsd;
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
                state.skewDelta, market.FEE_SCALE(), state.longTokenValue + state.shortTokenValue + state.amountUsd
            );

            // Convert the additional fee to index tokens
            state.indexFee = _isLongToken
                ? mulDiv(state.feeAdditionUsd, LONG_BASE_UNIT, _longPrices.price + _longPrices.confidence)
                : mulDiv(state.feeAdditionUsd, SHORT_BASE_UNIT, _shortPrices.price + _shortPrices.confidence);

            // Return base fee + additional fee
            return state.baseFee + state.indexFee;
        }

        // If no skew flip and skew improved, return base fee
        return state.baseFee;
    }

    function calculateDepositAmounts(IMarket.ExecuteDeposit calldata _params)
        external
        view
        returns (uint256 afterFeeAmount, uint256 fee, uint256 mintAmount)
    {
        // Calculate Fee (Internal Function to avoid STD)
        fee = calculateFee(
            _params.market,
            _params.deposit.amountIn,
            _params.deposit.isLongToken,
            _params.longPrices,
            _params.shortPrices,
            true,
            _params.market.longTokenBalance(),
            _params.market.shortTokenBalance()
        );

        // Calculate remaining after fee
        afterFeeAmount = _params.deposit.amountIn - fee;

        // Calculate Mint amount with the remaining amount
        mintAmount = calculateMintAmount(
            _params.market,
            _params.marketToken,
            _params.longPrices,
            _params.shortPrices,
            afterFeeAmount,
            _params.longBorrowFeesUsd,
            _params.shortBorrowFeesUsd,
            _params.cumulativePnl,
            _params.deposit.isLongToken
        );
    }

    function calculateWithdrawalAmounts(IMarket.ExecuteWithdrawal calldata _params)
        external
        view
        returns (uint256 tokenAmountOut, uint256 fee)
    {
        // Validate the Amount Out vs Expected Amount out
        uint256 expectedOut = calculateWithdrawalAmount(
            _params.market,
            _params.marketToken,
            _params.longPrices,
            _params.shortPrices,
            _params.withdrawal.amountIn,
            _params.longBorrowFeesUsd,
            _params.shortBorrowFeesUsd,
            _params.cumulativePnl,
            _params.withdrawal.isLongToken
        );

        if (_params.amountOut != expectedOut) revert MarketUtils_InvalidAmountOut(_params.amountOut, expectedOut);

        // Calculate Fee on the Amount Out
        fee = calculateFee(
            _params.market,
            _params.amountOut,
            _params.withdrawal.isLongToken,
            _params.longPrices,
            _params.shortPrices,
            false,
            _params.market.longTokenBalance(),
            _params.market.shortTokenBalance()
        );

        // Calculate the Token Amount Out
        tokenAmountOut = _params.amountOut - fee;
    }

    function validateDeposit(
        IMarket.State calldata _stateBefore,
        IMarket.State calldata _stateAfter,
        uint256 _amountIn,
        bool _isLongToken
    ) external pure {
        if (_isLongToken) {
            // Market's WETH Balance should increase by AmountIn
            if (_stateAfter.wethBalance != _stateBefore.wethBalance + _amountIn) {
                revert MarketUtils_DepositAmountIn();
            }
        } else {
            // Market's USDC Balance should increase by AmountIn
            if (_stateAfter.usdcBalance != _stateBefore.usdcBalance + _amountIn) {
                revert MarketUtils_DepositAmountIn();
            }
        }
        if (_stateAfter.totalSupply <= _stateBefore.totalSupply) {
            revert MarketUtils_TokenMintFailed();
        }
    }

    /**
     * - Total Supply should decrease by the market token amount in
     * - The Fee should increase within S.D of the max fee
     * - The pool balance should decrease by the amount out
     * - The vault balance should decrease by the amount out
     */
    function validateWithdrawal(
        IMarket.State calldata _stateBefore,
        IMarket.State calldata _stateAfter,
        uint256 _marketTokenAmountIn,
        uint256 _amountOut,
        uint256 _feeScale,
        bool _isLongToken
    ) external pure {
        uint256 minFee = mulDiv(_amountOut, BASE_FEE, SCALAR);
        uint256 maxFee = mulDiv(_amountOut, BASE_FEE + _feeScale, SCALAR);
        if (_stateBefore.totalSupply != _stateAfter.totalSupply + _marketTokenAmountIn) {
            revert MarketUtils_TokenBurnFailed();
        }
        if (_isLongToken) {
            // WETH Balance should decrease by (AmountOut - Fee)
            // WETH balance after is between (Before - AmountOut + MinFee) and (Before - AmountOut + MaxFee)
            if (
                _stateAfter.wethBalance < _stateBefore.wethBalance - _amountOut + minFee
                    || _stateAfter.wethBalance > _stateBefore.wethBalance - _amountOut + maxFee
            ) {
                revert MarketUtils_WithdrawalAmountOut();
            }
        } else {
            // USDC Balance should decrease by (AmountOut - Fee)
            // USDC balance after is between (Before - AmountOut + MinFee) and (Before - AmountOut + MaxFee)
            if (
                _stateAfter.usdcBalance < _stateBefore.usdcBalance - _amountOut + minFee
                    || _stateAfter.usdcBalance > _stateBefore.usdcBalance - _amountOut + maxFee
            ) {
                revert MarketUtils_WithdrawalAmountOut();
            }
        }
    }

    // @audit - why do we only minmize?
    function calculateMintAmount(
        IMarket market,
        IMarketToken marketToken,
        Oracle.Price memory _longPrices,
        Oracle.Price memory _shortPrices,
        uint256 _amountIn,
        uint256 _longBorrowFeesUsd,
        uint256 _shortBorrowFeesUsd,
        int256 _cumulativePnl,
        bool _isLongToken
    ) public view returns (uint256 marketTokenAmount) {
        uint256 marketTokenPrice = getMarketTokenPrice(
            market,
            marketToken,
            _longPrices.price + _longPrices.confidence,
            _longBorrowFeesUsd,
            _shortPrices.price + _shortPrices.confidence,
            _shortBorrowFeesUsd,
            _cumulativePnl
        );
        // $50M should be 50_000_000e18. Currently has 30 Decimal Places due to Price
        // Need a divisor for long and short
        // Long divisor -> (18dp * 30dp / x dp) should = 18dp -> dp = 30
        // Short divisor -> (6dp * 30dp / x dp) should = 18dp -> dp = 18
        if (marketTokenPrice == 0) {
            marketTokenAmount = _isLongToken
                ? mulDiv(_amountIn, _longPrices.price - _longPrices.confidence, LONG_CONVERSION_FACTOR)
                : mulDiv(_amountIn, _shortPrices.price - _shortPrices.confidence, SHORT_CONVERSION_FACTOR);
        } else {
            uint256 valueUsd = _isLongToken
                ? mulDiv(_amountIn, _longPrices.price - _longPrices.confidence, LONG_BASE_UNIT)
                : mulDiv(_amountIn, _shortPrices.price - _shortPrices.confidence, SHORT_BASE_UNIT);
            // (30dp * 18dp / 30dp) = 18dp
            marketTokenAmount = mulDiv(valueUsd, SCALAR, marketTokenPrice);
        }
    }

    function calculateWithdrawalAmount(
        IMarket market,
        IMarketToken marketToken,
        Oracle.Price memory _longPrices,
        Oracle.Price memory _shortPrices,
        uint256 _marketTokenAmountIn,
        uint256 _longBorrowFeesUsd,
        uint256 _shortBorrowFeesUsd,
        int256 _cumulativePnl,
        bool _isLongToken
    ) public view returns (uint256 tokenAmount) {
        uint256 marketTokenPrice = getMarketTokenPrice(
            market,
            marketToken,
            _longPrices.price - _longPrices.confidence,
            _longBorrowFeesUsd,
            _shortPrices.price - _shortPrices.confidence,
            _shortBorrowFeesUsd,
            _cumulativePnl
        );
        uint256 valueUsd = mulDiv(_marketTokenAmountIn, marketTokenPrice, SCALAR);
        tokenAmount = _isLongToken
            ? mulDiv(valueUsd, LONG_BASE_UNIT, _longPrices.price + _longPrices.confidence)
            : mulDiv(valueUsd, SHORT_BASE_UNIT, _shortPrices.price + _shortPrices.confidence);
    }

    function getMarketTokenPrice(
        IMarket market,
        IMarketToken marketToken,
        uint256 _longTokenPrice,
        uint256 _longBorrowFeesUsd,
        uint256 _shortTokenPrice,
        uint256 _shortBorrowFeesUsd,
        int256 _cumulativePnl
    ) public view returns (uint256 lpTokenPrice) {
        uint256 totalSupply = marketToken.totalSupply();
        if (totalSupply == 0) {
            lpTokenPrice = 0;
        } else {
            uint256 aum = getAum(
                market, _longTokenPrice, _longBorrowFeesUsd, _shortTokenPrice, _shortBorrowFeesUsd, _cumulativePnl
            );
            lpTokenPrice = mulDiv(aum, SCALAR, totalSupply);
        }
    }

    // Funding Fees should be balanced between the longs and shorts, so don't need to be accounted for.
    // They are however settled through the pool, so maybe they should be accounted for?
    // If not, we must reduce the pool balance for each funding claim, which will account for them.
    function getAum(
        IMarket market,
        uint256 _longTokenPrice,
        uint256 _longBorrowFeesUsd,
        uint256 _shortTokenPrice,
        uint256 _shortBorrowFeesUsd,
        int256 _cumulativePnl
    ) public view returns (uint256 aum) {
        // Get Values in USD -> Subtract reserved amounts from AUM
        uint256 longTokenValue =
            mulDiv(market.longTokenBalance() - market.longTokensReserved(), _longTokenPrice, LONG_BASE_UNIT);
        uint256 shortTokenValue =
            mulDiv(market.shortTokenBalance() - market.shortTokensReserved(), _shortTokenPrice, SHORT_BASE_UNIT);

        // Add Borrow Fees
        longTokenValue += _longBorrowFeesUsd;
        shortTokenValue += _shortBorrowFeesUsd;

        // Calculate AUM
        aum = _cumulativePnl >= 0
            ? longTokenValue + shortTokenValue + _cumulativePnl.abs()
            : longTokenValue + shortTokenValue - _cumulativePnl.abs();
    }

    /**
     * WAEP = ∑(Position Size in USD) / ∑(Entry Price in USD * Position Size in USD)
     */
    function calculateWeightedAverageEntryPrice(
        uint256 _prevAverageEntryPrice,
        uint256 _prevPositionSize,
        int256 _sizeDelta,
        uint256 _indexPrice
    ) external pure returns (uint256) {
        if (_sizeDelta <= 0) {
            // If full close, Avg Entry Price is reset to 0
            if (_sizeDelta == -_prevPositionSize.toInt256()) return 0;
            // Else, Avg Entry Price doesn't change for decrease
            else return _prevAverageEntryPrice;
        }

        // Increasing position size
        uint256 newPositionSize = _prevPositionSize + _sizeDelta.abs();

        uint256 numerator = (_prevAverageEntryPrice * _prevPositionSize) + (_indexPrice * _sizeDelta.abs());

        uint256 newAverageEntryPrice = numerator / newPositionSize;

        return newAverageEntryPrice;
    }

    /// @dev Positive for profit, negative for loss. Returns PNL in USD
    function getMarketPnl(IMarket market, bytes32 _assetId, uint256 _indexPrice, uint256 _indexBaseUnit, bool _isLong)
        public
        view
        returns (int256 netPnl)
    {
        uint256 openInterest = getOpenInterest(market, _assetId, _isLong);
        uint256 averageEntryPrice = getAverageEntryPrice(market, _assetId, _isLong);
        if (openInterest == 0 || averageEntryPrice == 0) return 0;
        int256 priceDelta = _indexPrice.toInt256() - averageEntryPrice.toInt256();
        uint256 entryIndexAmount = mulDiv(openInterest, _indexBaseUnit, averageEntryPrice);
        if (_isLong) {
            netPnl = mulDivSigned(priceDelta, entryIndexAmount.toInt256(), _indexBaseUnit.toInt256());
        } else {
            netPnl = -mulDivSigned(priceDelta, entryIndexAmount.toInt256(), _indexBaseUnit.toInt256());
        }
    }

    function calculateCumulativeMarketPnl(IMarket market, IPriceFeed priceFeed, bool _isLong, bool _maximise)
        external
        view
        returns (int256 cumulativePnl)
    {
        // Get an array of Asset Ids within the market
        /**
         * For each token:
         * 1. Get the current price of the token
         * 2. Get the current open interest of the token
         * 3. Get the average entry price of the token
         * 4. Calculate the PNL of the token
         * 5. Add the PNL to the cumulative PNL
         */
        bytes32[] memory assetIds = market.getAssetIds();
        // Max 10,000 Loops, so uint16 sufficient
        for (uint16 i = 0; i < assetIds.length;) {
            bytes32 assetId = assetIds[i];
            uint256 indexPrice =
                _maximise ? Oracle.getMaxPrice(priceFeed, assetId) : Oracle.getMinPrice(priceFeed, assetId);
            uint256 indexBaseUnit = Oracle.getBaseUnit(priceFeed, assetId);
            int256 pnl = getMarketPnl(market, assetId, indexPrice, indexBaseUnit, _isLong);
            cumulativePnl += pnl;
            unchecked {
                ++i;
            }
        }
    }

    function getNetMarketPnl(IMarket market, bytes32 _assetId, uint256 _indexPrice, uint256 _indexBaseUnit)
        external
        view
        returns (int256)
    {
        int256 longPnl = getMarketPnl(market, _assetId, _indexPrice, _indexBaseUnit, true);
        int256 shortPnl = getMarketPnl(market, _assetId, _indexPrice, _indexBaseUnit, false);
        return longPnl + shortPnl;
    }

    function getTotalOiForMarket(IMarket market, bool _isLong) external view returns (uint256) {
        // get all asset ids from the market
        bytes32[] memory assetIds = market.getAssetIds();
        uint256 len = assetIds.length;
        // loop through all asset ids and sum the open interest
        uint256 totalOi;
        for (uint256 i = 0; i < len;) {
            totalOi += getOpenInterest(market, assetIds[i], _isLong);
            unchecked {
                ++i;
            }
        }
        return totalOi;
    }

    function getOpenInterestUsd(IMarket market, bytes32 _assetId, bool _isLong) external view returns (uint256) {
        return getOpenInterest(market, _assetId, _isLong);
    }

    function getTotalPoolBalanceUsd(IMarket market, bytes32 _assetId, uint256 _longTokenPrice, uint256 _shortTokenPrice)
        external
        view
        returns (uint256 poolBalanceUsd)
    {
        uint256 longPoolUsd = getPoolBalanceUsd(market, _assetId, _longTokenPrice, LONG_BASE_UNIT, true);
        uint256 shortPoolUsd = getPoolBalanceUsd(market, _assetId, _shortTokenPrice, SHORT_BASE_UNIT, false);
        poolBalanceUsd = longPoolUsd + shortPoolUsd;
    }

    // In Collateral Tokens
    function getPoolBalance(IMarket market, bytes32 _assetId, bool _isLong) public view returns (uint256 poolAmount) {
        // get the allocation percentage
        uint256 allocationShare = getAllocation(market, _assetId);
        // get the total liquidity available for that side
        uint256 totalAvailableLiquidity = market.totalAvailableLiquidity(_isLong);
        // calculate liquidity allocated to the market for that side
        poolAmount = mulDiv(totalAvailableLiquidity, allocationShare, MAX_ALLOCATION);
    }

    function getPoolBalanceUsd(
        IMarket market,
        bytes32 _assetId,
        uint256 _collateralTokenPrice,
        uint256 _collateralBaseUnit,
        bool _isLong
    ) public view returns (uint256 poolUsd) {
        // get the liquidity allocated to the market for that side
        uint256 allocationInTokens = getPoolBalance(market, _assetId, _isLong);
        // convert to usd
        poolUsd = mulDiv(allocationInTokens, _collateralTokenPrice, _collateralBaseUnit);
    }

    function validateAllocation(
        IMarket market,
        bytes32 _assetId,
        uint256 _sizeDeltaUsd,
        uint256 _collateralTokenPrice,
        uint256 _collateralBaseUnit,
        bool _isLong
    ) external view {
        // Get Max OI for side
        uint256 availableUsd = getAvailableOiUsd(market, _assetId, _collateralTokenPrice, _collateralBaseUnit, _isLong);
        // Check SizeDelta USD won't push the OI over the max
        if (_sizeDeltaUsd > availableUsd) revert MarketUtils_MaxOiExceeded();
    }

    function getTotalAvailableOiUsd(IMarket market, bytes32 _assetId, uint256 _longTokenPrice, uint256 _shortTokenPrice)
        external
        view
        returns (uint256 totalAvailableOiUsd)
    {
        uint256 longOiUsd = getAvailableOiUsd(market, _assetId, _longTokenPrice, LONG_BASE_UNIT, true);
        uint256 shortOiUsd = getAvailableOiUsd(market, _assetId, _shortTokenPrice, SHORT_BASE_UNIT, false);
        totalAvailableOiUsd = longOiUsd + shortOiUsd;
    }

    /// @notice returns the available remaining open interest for a side in USD
    function getAvailableOiUsd(
        IMarket market,
        bytes32 _assetId,
        uint256 _collateralTokenPrice,
        uint256 _collateralBaseUnit,
        bool _isLong
    ) public view returns (uint256 availableOi) {
        // get the allocation and subtract by the markets reserveFactor
        uint256 remainingAllocationUsd =
            getPoolBalanceUsd(market, _assetId, _collateralTokenPrice, _collateralBaseUnit, _isLong);
        uint256 reserveFactor = getReserveFactor(market, _assetId);
        availableOi = remainingAllocationUsd - mulDiv(remainingAllocationUsd, reserveFactor, SCALAR);
    }

    // The pnl factor is the ratio of the pnl to the pool usd
    function getPnlFactor(
        IMarket market,
        bytes32 _assetId,
        uint256 _indexPrice,
        uint256 _indexBaseUnit,
        uint256 _collateralPrice,
        uint256 _collateralBaseUnit,
        bool _isLong
    ) external view returns (int256 pnlFactor) {
        // get pool usd (if 0 return 0)
        uint256 poolUsd = getPoolBalanceUsd(market, _assetId, _collateralPrice, _collateralBaseUnit, _isLong);
        if (poolUsd == 0) {
            return 0;
        }
        // get pnl
        int256 pnl = getMarketPnl(market, _assetId, _indexPrice, _indexBaseUnit, _isLong);

        console.log("Pool USD: ", poolUsd);
        console2.log("PNL: ", pnl);

        uint256 factor = mulDiv(pnl.abs(), SCALAR, poolUsd);
        console.log("Factor: ", factor);
        return pnl > 0 ? factor.toInt256() : factor.toInt256() * -1;
    }

    /**
     * ======================= Getter Functions =======================
     */
    function getCumulativeBorrowFees(IMarket market, bytes32 _assetId)
        external
        view
        returns (uint256 longCumulativeBorrowFees, uint256 shortCumulativeBorrowFees)
    {
        IMarket.MarketStorage memory marketStorage = market.getStorage(_assetId);
        return (marketStorage.borrowing.longCumulativeBorrowFees, marketStorage.borrowing.shortCumulativeBorrowFees);
    }

    function getCumulativeBorrowFee(IMarket market, bytes32 _assetId, bool _isLong) public view returns (uint256) {
        IMarket.MarketStorage memory marketStorage = market.getStorage(_assetId);
        return _isLong
            ? marketStorage.borrowing.longCumulativeBorrowFees
            : marketStorage.borrowing.shortCumulativeBorrowFees;
    }

    function getLastFundingUpdate(IMarket market, bytes32 _assetId) external view returns (uint48) {
        IMarket.MarketStorage memory marketStorage = market.getStorage(_assetId);
        return marketStorage.funding.lastFundingUpdate;
    }

    function getFundingRates(IMarket market, bytes32 _assetId) external view returns (int256 rate, int256 velocity) {
        IMarket.MarketStorage memory marketStorage = market.getStorage(_assetId);
        return (marketStorage.funding.fundingRate, marketStorage.funding.fundingRateVelocity);
    }

    function getFundingAccrued(IMarket market, bytes32 _assetId) external view returns (int256) {
        IMarket.MarketStorage memory marketStorage = market.getStorage(_assetId);
        return marketStorage.funding.fundingAccruedUsd;
    }

    function getLastBorrowingUpdate(IMarket market, bytes32 _assetId) external view returns (uint48) {
        IMarket.MarketStorage memory marketStorage = market.getStorage(_assetId);
        return marketStorage.borrowing.lastBorrowUpdate;
    }

    function getBorrowingRate(IMarket market, bytes32 _assetId, bool _isLong) external view returns (uint256) {
        IMarket.MarketStorage memory marketStorage = market.getStorage(_assetId);
        return _isLong ? marketStorage.borrowing.longBorrowingRate : marketStorage.borrowing.shortBorrowingRate;
    }

    function getConfig(IMarket market, bytes32 _assetId) external view returns (IMarket.Config memory) {
        IMarket.MarketStorage memory marketStorage = market.getStorage(_assetId);
        return marketStorage.config;
    }

    function getBorrowingConfig(IMarket market, bytes32 _assetId)
        external
        view
        returns (IMarket.BorrowingConfig memory)
    {
        IMarket.MarketStorage memory marketStorage = market.getStorage(_assetId);
        return marketStorage.config.borrowing;
    }

    function getFundingConfig(IMarket market, bytes32 _assetId) external view returns (IMarket.FundingConfig memory) {
        IMarket.MarketStorage memory marketStorage = market.getStorage(_assetId);
        return marketStorage.config.funding;
    }

    function getImpactConfig(IMarket market, bytes32 _assetId) external view returns (IMarket.ImpactConfig memory) {
        IMarket.MarketStorage memory marketStorage = market.getStorage(_assetId);
        return marketStorage.config.impact;
    }

    function getAdlConfig(IMarket market, bytes32 _assetId) external view returns (IMarket.AdlConfig memory) {
        IMarket.MarketStorage memory marketStorage = market.getStorage(_assetId);
        return marketStorage.config.adl;
    }

    function getReserveFactor(IMarket market, bytes32 _assetId) public view returns (uint256) {
        IMarket.MarketStorage memory marketStorage = market.getStorage(_assetId);
        return marketStorage.config.reserveFactor;
    }

    function getMaxLeverage(IMarket market, bytes32 _assetId) external view returns (uint32) {
        IMarket.MarketStorage memory marketStorage = market.getStorage(_assetId);
        return marketStorage.config.maxLeverage;
    }

    function getMaxPnlFactor(IMarket market, bytes32 _assetId) external view returns (uint256) {
        IMarket.MarketStorage memory marketStorage = market.getStorage(_assetId);
        return marketStorage.config.adl.maxPnlFactor;
    }

    function getAllocation(IMarket market, bytes32 _assetId) public view returns (uint256) {
        IMarket.MarketStorage memory marketStorage = market.getStorage(_assetId);
        return marketStorage.allocationPercentage;
    }

    function getOpenInterest(IMarket market, bytes32 _assetId, bool _isLong) public view returns (uint256) {
        IMarket.MarketStorage memory marketStorage = market.getStorage(_assetId);
        return _isLong ? marketStorage.openInterest.longOpenInterest : marketStorage.openInterest.shortOpenInterest;
    }

    function getAverageEntryPrice(IMarket market, bytes32 _assetId, bool _isLong) public view returns (uint256) {
        IMarket.MarketStorage memory marketStorage = market.getStorage(_assetId);
        return _isLong ? marketStorage.pnl.longAverageEntryPriceUsd : marketStorage.pnl.shortAverageEntryPriceUsd;
    }

    function getAverageCumulativeBorrowFee(IMarket market, bytes32 _assetId, bool _isLong)
        external
        view
        returns (uint256)
    {
        IMarket.MarketStorage memory marketStorage = market.getStorage(_assetId);
        return _isLong
            ? marketStorage.borrowing.weightedAvgCumulativeLong
            : marketStorage.borrowing.weightedAvgCumulativeShort;
    }

    function getImpactPool(IMarket market, bytes32 _assetId) external view returns (uint256) {
        IMarket.MarketStorage memory marketStorage = market.getStorage(_assetId);
        return marketStorage.impactPool;
    }
}
