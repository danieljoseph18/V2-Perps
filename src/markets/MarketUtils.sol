// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IMarket} from "./interfaces/IMarket.sol";
import {IMarketToken} from "./interfaces/IMarketToken.sol";
import {mulDiv, mulDivSigned} from "@prb/math/Common.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IPriceFeed} from "../oracle/interfaces/IPriceFeed.sol";
import {Oracle} from "../oracle/Oracle.sol";

library MarketUtils {
    using SignedMath for int256;
    using SafeCast for uint256;

    uint64 constant SCALAR = 1e18;
    uint64 constant BASE_FEE = 0.001e18; // 0.1%
    uint64 public constant FEE_SCALE = 0.01e18; // 1%
    uint64 constant LONG_BASE_UNIT = 1e18;

    uint16 public constant MAX_ALLOCATION = 10000;
    uint32 constant SHORT_BASE_UNIT = 1e6;
    uint64 constant SHORT_CONVERSION_FACTOR = 1e18;

    uint256 constant LONG_CONVERSION_FACTOR = 1e30;

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
        IPriceFeed.Price longPrices;
        IPriceFeed.Price shortPrices;
        bool isDeposit;
    }

    struct FeeState {
        uint256 baseFee;
        uint256 amountUsd;
        uint256 longTokenValue;
        uint256 shortTokenValue;
        bool initSkewLong;
        uint256 initSkew;
        bool updatedSkewLong;
        bool skewFlip;
        uint256 updatedSkew;
        uint256 skewDelta;
        uint256 feeAdditionUsd;
        uint256 indexFee;
    }

    function calculateDepositFee(
        IPriceFeed.Price memory _longPrices,
        IPriceFeed.Price memory _shortPrices,
        uint256 _longTokenBalance,
        uint256 _shortTokenBalance,
        uint256 _tokenAmount,
        bool _isLongToken
    ) public pure returns (uint256) {
        uint256 baseFee = mulDiv(_tokenAmount, BASE_FEE, SCALAR);
        // If long / short token balance = 0 return Base Fee
        if (_longTokenBalance == 0 || _shortTokenBalance == 0) return baseFee;
        // Maximize to increase the impact on the skew
        uint256 amountUsd = _isLongToken
            ? mulDiv(_tokenAmount, _longPrices.max, LONG_BASE_UNIT)
            : mulDiv(_tokenAmount, _shortPrices.max, SHORT_BASE_UNIT);
        if (amountUsd == 0) revert MarketUtils_AmountTooSmall();
        // Minimize value of pool to maximise the effect on the skew
        uint256 longValue = mulDiv(_longTokenBalance, _longPrices.min, LONG_BASE_UNIT);
        uint256 shortValue = mulDiv(_shortTokenBalance, _shortPrices.min, SHORT_BASE_UNIT);

        // Don't want to disincentivise deposits on empty pool
        if (longValue == 0 && _isLongToken) return baseFee;
        if (shortValue == 0 && !_isLongToken) return baseFee;

        int256 initSkew = longValue.toInt256() - shortValue.toInt256();
        _isLongToken ? longValue += amountUsd : shortValue += amountUsd;
        int256 updatedSkew = longValue.toInt256() - shortValue.toInt256();

        // Check for a Skew Flip
        bool skewFlip = initSkew ^ updatedSkew < 0;

        // Skew Improve Same Side - Charge the Base fee
        if (updatedSkew.abs() < initSkew.abs() && !skewFlip) return baseFee;
        // If Flip, charge full Skew After, else charge the delta
        uint256 negativeSkewAccrued = skewFlip ? updatedSkew.abs() : amountUsd;
        // Calculate the relative impact on Market Skew
        uint256 feeFactor = mulDiv(negativeSkewAccrued, FEE_SCALE, longValue + shortValue);
        // Calculate the additional fee
        uint256 feeAddition = mulDiv(feeFactor, _tokenAmount, SCALAR);
        // Return base fee + fee addition
        return baseFee + feeAddition;
    }

    /// @dev - Med price used, as in the case of a full withdrawal, a spread between max / min could cause amount to be > pool value
    function calculateWithdrawalFee(
        uint256 _longPrice,
        uint256 _shortPrice,
        uint256 _longTokenBalance,
        uint256 _shortTokenBalance,
        uint256 _tokenAmount,
        bool _isLongToken
    ) public pure returns (uint256) {
        uint256 baseFee = mulDiv(_tokenAmount, BASE_FEE, SCALAR);

        // Maximize to increase the impact on the skew
        uint256 amountUsd = _isLongToken
            ? mulDiv(_tokenAmount, _longPrice, LONG_BASE_UNIT)
            : mulDiv(_tokenAmount, _shortPrice, SHORT_BASE_UNIT);
        if (amountUsd == 0) revert MarketUtils_AmountTooSmall();
        // Minimize value of pool to maximise the effect on the skew
        uint256 longValue = mulDiv(_longTokenBalance, _longPrice, LONG_BASE_UNIT);
        uint256 shortValue = mulDiv(_shortTokenBalance, _shortPrice, SHORT_BASE_UNIT);

        int256 initSkew = longValue.toInt256() - shortValue.toInt256();
        _isLongToken ? longValue -= amountUsd : shortValue -= amountUsd;
        int256 updatedSkew = longValue.toInt256() - shortValue.toInt256();

        if (longValue + shortValue == 0) {
            // Charge the maximium possible fee for full withdrawals
            return baseFee + mulDiv(_tokenAmount, FEE_SCALE, SCALAR);
        }

        // Check for a Skew Flip
        bool skewFlip = initSkew ^ updatedSkew < 0;

        // Skew Improve Same Side - Charge the Base fee
        if (updatedSkew.abs() < initSkew.abs() && !skewFlip) return baseFee;
        // If Flip, charge full Skew After, else charge the delta
        uint256 negativeSkewAccrued = skewFlip ? updatedSkew.abs() : amountUsd;
        // Calculate the relative impact on Market Skew
        // Re-add amount to get the initial net pool value
        uint256 feeFactor = mulDiv(negativeSkewAccrued, FEE_SCALE, longValue + shortValue + amountUsd);
        // Calculate the additional fee
        uint256 feeAddition = mulDiv(feeFactor, _tokenAmount, SCALAR);
        // Return base fee + fee addition
        return baseFee + feeAddition;
    }

    function calculateDepositAmounts(IMarket.ExecuteDeposit calldata _params)
        external
        view
        returns (uint256 afterFeeAmount, uint256 fee, uint256 mintAmount)
    {
        // Calculate Fee (Internal Function to avoid STD)
        fee = calculateDepositFee(
            _params.longPrices,
            _params.shortPrices,
            _params.market.longTokenBalance(),
            _params.market.shortTokenBalance(),
            _params.deposit.amountIn,
            _params.deposit.isLongToken
        );

        // Calculate remaining after fee
        afterFeeAmount = _params.deposit.amountIn - fee;

        // Calculate Mint amount with the remaining amount
        // Minimize
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
        fee = calculateWithdrawalFee(
            _params.longPrices.med,
            _params.shortPrices.med,
            _params.market.longTokenBalance(),
            _params.market.shortTokenBalance(),
            _params.amountOut,
            _params.withdrawal.isLongToken
        );

        // Calculate the Token Amount Out
        tokenAmountOut = _params.amountOut - fee;
    }

    function validateDeposit(
        IMarket.State calldata _initialState,
        IMarket.State calldata _updatedState,
        uint256 _amountIn,
        bool _isLongToken
    ) external pure {
        if (_isLongToken) {
            // Market's WETH Balance should increase by AmountIn
            if (_updatedState.wethBalance != _initialState.wethBalance + _amountIn) {
                revert MarketUtils_DepositAmountIn();
            }
        } else {
            // Market's USDC Balance should increase by AmountIn
            if (_updatedState.usdcBalance != _initialState.usdcBalance + _amountIn) {
                revert MarketUtils_DepositAmountIn();
            }
        }
        if (_updatedState.totalSupply <= _initialState.totalSupply) {
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
        IMarket.State calldata _initialState,
        IMarket.State calldata _updatedState,
        uint256 _marketTokenAmountIn,
        uint256 _amountOut,
        bool _isLongToken
    ) external pure {
        uint256 minFee = mulDiv(_amountOut, BASE_FEE, SCALAR);
        uint256 maxFee = mulDiv(_amountOut, BASE_FEE + FEE_SCALE, SCALAR);
        if (_initialState.totalSupply != _updatedState.totalSupply + _marketTokenAmountIn) {
            revert MarketUtils_TokenBurnFailed();
        }
        if (_isLongToken) {
            // WETH Balance should decrease by (AmountOut - Fee)
            // WETH balance after is between (Before - AmountOut + MinFee) and (Before - AmountOut + MaxFee)
            if (
                _updatedState.wethBalance < _initialState.wethBalance - _amountOut + minFee
                    || _updatedState.wethBalance > _initialState.wethBalance - _amountOut + maxFee
            ) {
                revert MarketUtils_WithdrawalAmountOut();
            }
        } else {
            // USDC Balance should decrease by (AmountOut - Fee)
            // USDC balance after is between (Before - AmountOut + MinFee) and (Before - AmountOut + MaxFee)
            if (
                _updatedState.usdcBalance < _initialState.usdcBalance - _amountOut + minFee
                    || _updatedState.usdcBalance > _initialState.usdcBalance - _amountOut + maxFee
            ) {
                revert MarketUtils_WithdrawalAmountOut();
            }
        }
    }

    /// @dev - Calculate the Mint Amount to 18 decimal places
    function calculateMintAmount(
        IMarket market,
        IMarketToken marketToken,
        IPriceFeed.Price memory _longPrices,
        IPriceFeed.Price memory _shortPrices,
        uint256 _amountIn,
        uint256 _longBorrowFeesUsd,
        uint256 _shortBorrowFeesUsd,
        int256 _cumulativePnl,
        bool _isLongToken
    ) public view returns (uint256 marketTokenAmount) {
        // Maximize the AUM
        uint256 marketTokenPrice = getMarketTokenPrice(
            market,
            marketToken,
            _longPrices.max,
            _longBorrowFeesUsd,
            _shortPrices.max,
            _shortBorrowFeesUsd,
            _cumulativePnl
        );
        // Long divisor -> (18dp * 30dp / x dp) should = 18dp -> dp = 30
        // Short divisor -> (6dp * 30dp / x dp) should = 18dp -> dp = 18
        // Minimize the Value of the Amount In
        if (marketTokenPrice == 0) {
            marketTokenAmount = _isLongToken
                ? mulDiv(_amountIn, _longPrices.min, LONG_CONVERSION_FACTOR)
                : mulDiv(_amountIn, _shortPrices.min, SHORT_CONVERSION_FACTOR);
        } else {
            uint256 valueUsd = _isLongToken
                ? mulDiv(_amountIn, _longPrices.min, LONG_BASE_UNIT)
                : mulDiv(_amountIn, _shortPrices.min, SHORT_BASE_UNIT);
            // (30dp * 18dp / 30dp) = 18dp
            marketTokenAmount = mulDiv(valueUsd, SCALAR, marketTokenPrice);
        }
    }

    function calculateWithdrawalAmount(
        IMarket market,
        IMarketToken marketToken,
        IPriceFeed.Price memory _longPrices,
        IPriceFeed.Price memory _shortPrices,
        uint256 _marketTokenAmountIn,
        uint256 _longBorrowFeesUsd,
        uint256 _shortBorrowFeesUsd,
        int256 _cumulativePnl,
        bool _isLongToken
    ) public view returns (uint256 tokenAmount) {
        // Minimize the AUM
        uint256 marketTokenPrice = getMarketTokenPrice(
            market,
            marketToken,
            _longPrices.min,
            _longBorrowFeesUsd,
            _shortPrices.min,
            _shortBorrowFeesUsd,
            _cumulativePnl
        );
        uint256 valueUsd = mulDiv(_marketTokenAmountIn, marketTokenPrice, SCALAR);
        // Minimize the Value of the Amount Out
        tokenAmount = _isLongToken
            ? mulDiv(valueUsd, LONG_BASE_UNIT, _longPrices.max)
            : mulDiv(valueUsd, SHORT_BASE_UNIT, _shortPrices.max);
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
        aum += mulDiv(market.longTokenBalance() - market.longTokensReserved(), _longTokenPrice, LONG_BASE_UNIT);
        aum += mulDiv(market.shortTokenBalance() - market.shortTokensReserved(), _shortTokenPrice, SHORT_BASE_UNIT);

        // Add Borrow Fees
        aum += _longBorrowFeesUsd;
        aum += _shortBorrowFeesUsd;

        // Subtract any Negative Pnl -> Unrealized Positive Pnl not added to minimize AUM
        if (_cumulativePnl < 0) aum -= _cumulativePnl.abs();
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
    function getMarketPnl(
        IMarket market,
        string memory _ticker,
        uint256 _indexPrice,
        uint256 _indexBaseUnit,
        bool _isLong
    ) public view returns (int256 netPnl) {
        uint256 openInterest = getOpenInterest(market, _ticker, _isLong);
        uint256 averageEntryPrice = getAverageEntryPrice(market, _ticker, _isLong);
        if (openInterest == 0 || averageEntryPrice == 0) return 0;
        int256 priceDelta = _indexPrice.toInt256() - averageEntryPrice.toInt256();
        uint256 entryIndexAmount = mulDiv(openInterest, _indexBaseUnit, averageEntryPrice);
        if (_isLong) {
            netPnl = mulDivSigned(priceDelta, entryIndexAmount.toInt256(), _indexBaseUnit.toInt256());
        } else {
            netPnl = -mulDivSigned(priceDelta, entryIndexAmount.toInt256(), _indexBaseUnit.toInt256());
        }
    }

    // @audit - move to external computation
    function calculateCumulativeMarketPnl(
        IMarket market,
        IPriceFeed priceFeed,
        bytes32 _priceRequestId,
        bool _isLong,
        bool _maximise
    ) external view returns (int256 cumulativePnl) {
        /**
         * For each token in the market:
         * 1. Get the current price of the token
         * 2. Get the current open interest of the token
         * 3. Get the average entry price of the token
         * 4. Calculate the PNL of the token
         * 5. Add the PNL to the cumulative PNL
         */
        string[] memory tickers = market.getTickers();
        // Max 100 Loops, so uint8 sufficient
        for (uint8 i = 0; i < tickers.length;) {
            string memory ticker = tickers[i];
            uint256 indexPrice = _maximise
                ? Oracle.getMaxPrice(priceFeed, _priceRequestId, ticker)
                : Oracle.getMinPrice(priceFeed, _priceRequestId, ticker);
            uint256 indexBaseUnit = Oracle.getBaseUnit(priceFeed, ticker);
            int256 pnl = getMarketPnl(market, ticker, indexPrice, indexBaseUnit, _isLong);
            cumulativePnl += pnl;
            unchecked {
                ++i;
            }
        }
    }

    function getNetMarketPnl(IMarket market, string calldata _ticker, uint256 _indexPrice, uint256 _indexBaseUnit)
        external
        view
        returns (int256)
    {
        int256 longPnl = getMarketPnl(market, _ticker, _indexPrice, _indexBaseUnit, true);
        int256 shortPnl = getMarketPnl(market, _ticker, _indexPrice, _indexBaseUnit, false);
        return longPnl + shortPnl;
    }

    function getTotalOiForMarket(IMarket market, bool _isLong) external view returns (uint256) {
        // get all asset ids from the market
        string[] memory tickers = market.getTickers();
        uint256 len = tickers.length;
        // loop through all asset ids and sum the open interest
        uint256 totalOi;
        for (uint256 i = 0; i < len;) {
            totalOi += getOpenInterest(market, tickers[i], _isLong);
            unchecked {
                ++i;
            }
        }
        return totalOi;
    }

    function getTotalPoolBalanceUsd(
        IMarket market,
        string calldata _ticker,
        uint256 _longTokenPrice,
        uint256 _shortTokenPrice
    ) external view returns (uint256 poolBalanceUsd) {
        uint256 longPoolUsd = getPoolBalanceUsd(market, _ticker, _longTokenPrice, LONG_BASE_UNIT, true);
        uint256 shortPoolUsd = getPoolBalanceUsd(market, _ticker, _shortTokenPrice, SHORT_BASE_UNIT, false);
        poolBalanceUsd = longPoolUsd + shortPoolUsd;
    }

    // In Collateral Tokens
    function getPoolBalance(IMarket market, string calldata _ticker, bool _isLong)
        public
        view
        returns (uint256 poolAmount)
    {
        // get the allocation percentage
        uint256 allocationShare = getAllocation(market, _ticker);
        // get the total liquidity available for that side
        uint256 totalAvailableLiquidity = market.totalAvailableLiquidity(_isLong);
        // calculate liquidity allocated to the market for that side
        poolAmount = mulDiv(totalAvailableLiquidity, allocationShare, MAX_ALLOCATION);
    }

    function getPoolBalanceUsd(
        IMarket market,
        string calldata _ticker,
        uint256 _collateralTokenPrice,
        uint256 _collateralBaseUnit,
        bool _isLong
    ) public view returns (uint256 poolUsd) {
        // get the liquidity allocated to the market for that side
        uint256 allocationInTokens = getPoolBalance(market, _ticker, _isLong);
        // convert to usd
        poolUsd = mulDiv(allocationInTokens, _collateralTokenPrice, _collateralBaseUnit);
    }

    function validateAllocation(
        IMarket market,
        string calldata _ticker,
        uint256 _sizeDeltaUsd,
        uint256 _indexPrice,
        uint256 _collateralTokenPrice,
        uint256 _indexBaseUnit,
        uint256 _collateralBaseUnit,
        bool _isLong
    ) external view {
        // Get Max OI for side
        uint256 availableUsd = getAvailableOiUsd(
            market, _ticker, _indexPrice, _collateralTokenPrice, _indexBaseUnit, _collateralBaseUnit, _isLong
        );
        // Check SizeDelta USD won't push the OI over the max
        if (_sizeDeltaUsd > availableUsd) revert MarketUtils_MaxOiExceeded();
    }

    function getTotalAvailableOiUsd(
        IMarket market,
        string calldata _ticker,
        uint256 _indexPrice,
        uint256 _longTokenPrice,
        uint256 _shortTokenPrice,
        uint256 _indexBaseUnit
    ) external view returns (uint256 totalAvailableOiUsd) {
        uint256 longOiUsd =
            getAvailableOiUsd(market, _ticker, _indexPrice, _longTokenPrice, _indexBaseUnit, LONG_BASE_UNIT, true);
        uint256 shortOiUsd =
            getAvailableOiUsd(market, _ticker, _indexPrice, _shortTokenPrice, _indexBaseUnit, SHORT_BASE_UNIT, false);
        totalAvailableOiUsd = longOiUsd + shortOiUsd;
    }

    /// @notice returns the available remaining open interest for a side in USD
    // @audit - should use the relative values of all positions
    // need to get the market pnl. If it's positive (side is in profit) subtract the profit from the available oi
    // if it's in net loss, do nothing to the available oi.
    function getAvailableOiUsd(
        IMarket market,
        string calldata _ticker,
        uint256 _indexPrice,
        uint256 _collateralTokenPrice,
        uint256 _indexBaseUnit,
        uint256 _collateralBaseUnit,
        bool _isLong
    ) public view returns (uint256 availableOi) {
        // get the allocation and subtract by the markets reserveFactor
        uint256 remainingAllocationUsd =
            getPoolBalanceUsd(market, _ticker, _collateralTokenPrice, _collateralBaseUnit, _isLong);
        availableOi = remainingAllocationUsd - mulDiv(remainingAllocationUsd, getReserveFactor(market, _ticker), SCALAR);
        // get the pnl
        int256 pnl = getMarketPnl(market, _ticker, _indexPrice, _indexBaseUnit, _isLong);
        // if the pnl is positive, subtract it from the available oi
        if (pnl > 0) {
            availableOi -= pnl.abs();
        }
    }

    // The pnl factor is the ratio of the pnl to the pool usd
    function getPnlFactor(
        IMarket market,
        string calldata _ticker,
        uint256 _indexPrice,
        uint256 _indexBaseUnit,
        uint256 _collateralPrice,
        uint256 _collateralBaseUnit,
        bool _isLong
    ) external view returns (int256 pnlFactor) {
        // get pool usd (if 0 return 0)
        uint256 poolUsd = getPoolBalanceUsd(market, _ticker, _collateralPrice, _collateralBaseUnit, _isLong);
        if (poolUsd == 0) {
            return 0;
        }
        // get pnl
        int256 pnl = getMarketPnl(market, _ticker, _indexPrice, _indexBaseUnit, _isLong);

        uint256 factor = mulDiv(pnl.abs(), SCALAR, poolUsd);
        return pnl > 0 ? factor.toInt256() : factor.toInt256() * -1;
    }

    /**
     * ======================= Getter Functions =======================
     */
    function getCumulativeBorrowFees(IMarket market, string calldata _ticker)
        external
        view
        returns (uint256 longCumulativeBorrowFees, uint256 shortCumulativeBorrowFees)
    {
        IMarket.MarketStorage memory marketStorage = market.getStorage(_ticker);
        return (marketStorage.borrowing.longCumulativeBorrowFees, marketStorage.borrowing.shortCumulativeBorrowFees);
    }

    function getCumulativeBorrowFee(IMarket market, string calldata _ticker, bool _isLong)
        public
        view
        returns (uint256)
    {
        IMarket.MarketStorage memory marketStorage = market.getStorage(_ticker);
        return _isLong
            ? marketStorage.borrowing.longCumulativeBorrowFees
            : marketStorage.borrowing.shortCumulativeBorrowFees;
    }

    function getLastFundingUpdate(IMarket market, string calldata _ticker) external view returns (uint48) {
        IMarket.MarketStorage memory marketStorage = market.getStorage(_ticker);
        return marketStorage.funding.lastFundingUpdate;
    }

    function getFundingRates(IMarket market, string calldata _ticker)
        external
        view
        returns (int256 rate, int256 velocity)
    {
        IMarket.MarketStorage memory marketStorage = market.getStorage(_ticker);
        return (marketStorage.funding.fundingRate, marketStorage.funding.fundingRateVelocity);
    }

    function getFundingAccrued(IMarket market, string calldata _ticker) external view returns (int256) {
        IMarket.MarketStorage memory marketStorage = market.getStorage(_ticker);
        return marketStorage.funding.fundingAccruedUsd;
    }

    function getLastBorrowingUpdate(IMarket market, string calldata _ticker) external view returns (uint48) {
        IMarket.MarketStorage memory marketStorage = market.getStorage(_ticker);
        return marketStorage.borrowing.lastBorrowUpdate;
    }

    function getBorrowingRate(IMarket market, string calldata _ticker, bool _isLong) external view returns (uint256) {
        IMarket.MarketStorage memory marketStorage = market.getStorage(_ticker);
        return _isLong ? marketStorage.borrowing.longBorrowingRate : marketStorage.borrowing.shortBorrowingRate;
    }

    function getConfig(IMarket market, string calldata _ticker) external view returns (IMarket.Config memory) {
        IMarket.MarketStorage memory marketStorage = market.getStorage(_ticker);
        return marketStorage.config;
    }

    function getFundingConfig(IMarket market, string calldata _ticker)
        external
        view
        returns (IMarket.FundingConfig memory)
    {
        IMarket.MarketStorage memory marketStorage = market.getStorage(_ticker);
        return marketStorage.config.funding;
    }

    function getImpactConfig(IMarket market, string calldata _ticker)
        external
        view
        returns (IMarket.ImpactConfig memory)
    {
        IMarket.MarketStorage memory marketStorage = market.getStorage(_ticker);
        return marketStorage.config.impact;
    }

    function getReserveFactor(IMarket market, string calldata _ticker) public view returns (uint256) {
        IMarket.MarketStorage memory marketStorage = market.getStorage(_ticker);
        return marketStorage.config.reserveFactor;
    }

    function getMaxLeverage(IMarket market, string calldata _ticker) external view returns (uint32) {
        IMarket.MarketStorage memory marketStorage = market.getStorage(_ticker);
        return marketStorage.config.maxLeverage;
    }

    function getMaxPnlFactor(IMarket market) external view returns (uint256) {
        return market.MAX_PNL_FACTOR();
    }

    function getAllocation(IMarket market, string calldata _ticker) public view returns (uint256) {
        IMarket.MarketStorage memory marketStorage = market.getStorage(_ticker);
        return marketStorage.allocationPercentage;
    }

    function getOpenInterest(IMarket market, string memory _ticker, bool _isLong) public view returns (uint256) {
        IMarket.MarketStorage memory marketStorage = market.getStorage(_ticker);
        return _isLong ? marketStorage.openInterest.longOpenInterest : marketStorage.openInterest.shortOpenInterest;
    }

    function getAverageEntryPrice(IMarket market, string memory _ticker, bool _isLong) public view returns (uint256) {
        IMarket.MarketStorage memory marketStorage = market.getStorage(_ticker);
        return _isLong ? marketStorage.pnl.longAverageEntryPriceUsd : marketStorage.pnl.shortAverageEntryPriceUsd;
    }

    function getAverageCumulativeBorrowFee(IMarket market, string calldata _ticker, bool _isLong)
        external
        view
        returns (uint256)
    {
        IMarket.MarketStorage memory marketStorage = market.getStorage(_ticker);
        return _isLong
            ? marketStorage.borrowing.weightedAvgCumulativeLong
            : marketStorage.borrowing.weightedAvgCumulativeShort;
    }

    function getImpactPool(IMarket market, string calldata _ticker) external view returns (uint256) {
        IMarket.MarketStorage memory marketStorage = market.getStorage(_ticker);
        return marketStorage.impactPool;
    }

    function generateAssetId(string memory _ticker) external pure returns (bytes32) {
        return keccak256(abi.encode(_ticker));
    }
}
