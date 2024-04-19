// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IMarket} from "./interfaces/IMarket.sol";
import {IVault} from "./interfaces/IVault.sol";
import {mulDiv, mulDivSigned} from "@prb/math/Common.sol";
import {SignedMath} from "../libraries/SignedMath.sol";
import {SafeCast} from "../libraries/SafeCast.sol";
import {IPriceFeed} from "../oracle/interfaces/IPriceFeed.sol";
import {Oracle} from "../oracle/Oracle.sol";
import {Borrowing} from "../libraries/Borrowing.sol";
import {MathUtils} from "../libraries/MathUtils.sol";
import {ITradeStorage} from "../positions/interfaces/ITradeStorage.sol";
import {Position} from "../positions/Position.sol";
import {Pool} from "./Pool.sol";

library MarketUtils {
    using SignedMath for int256;
    using SafeCast for uint256;
    using MathUtils for uint256;
    using MathUtils for uint64;
    using MathUtils for uint16;

    uint64 private constant PRECISION = 1e18;
    uint64 private constant BASE_FEE = 0.001e18; // 0.1%
    uint64 public constant FEE_SCALE = 0.01e18; // 1%
    uint64 private constant SHORT_CONVERSION_FACTOR = 1e18;

    uint64 private constant MAX_PNL_FACTOR = 0.45e18;
    uint64 private constant LONG_BASE_UNIT = 1e18;
    uint32 private constant SHORT_BASE_UNIT = 1e6;
    uint8 public constant MAX_ALLOCATION = 100;

    uint256 constant LONG_CONVERSION_FACTOR = 1e30;

    error MarketUtils_MaxOiExceeded();
    error MarketUtils_TokenBurnFailed();
    error MarketUtils_DepositAmountIn();
    error MarketUtils_WithdrawalAmountOut();
    error MarketUtils_AmountTooSmall();
    error MarketUtils_InvalidAmountOut(uint256 amountOut, uint256 expectedOut);
    error MarketUtils_TokenMintFailed();
    error MarketUtils_InsufficientFreeLiquidity();
    error MarketUtils_AdlCantOccur();

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

    /**
     * ======================= Constructor Functions =======================
     */
    function constructDepositParams(IPriceFeed priceFeed, IMarket market, bytes32 _depositKey)
        external
        view
        returns (IVault.ExecuteDeposit memory params)
    {
        // Fetch the request
        params.market = market;
        params.deposit = market.getRequest(_depositKey);
        params.key = _depositKey;
        // Get the signed prices
        (params.longPrices, params.shortPrices) = Oracle.getVaultPrices(priceFeed, params.deposit.requestTimestamp);
        // Calculate cumulative borrow fees
        params.longBorrowFeesUsd = Borrowing.getTotalFeesOwedByMarket(market, true);
        params.shortBorrowFeesUsd = Borrowing.getTotalFeesOwedByMarket(market, false);
        // Calculate Cumulative PNL
        params.cumulativePnl = Oracle.getCumulativePnl(priceFeed, address(market), params.deposit.requestTimestamp);
        params.vault = market.VAULT();
    }

    function constructWithdrawalParams(IPriceFeed priceFeed, IMarket market, bytes32 _withdrawalKey)
        external
        view
        returns (IVault.ExecuteWithdrawal memory params)
    {
        // Fetch the request
        params.market = market;
        params.withdrawal = market.getRequest(_withdrawalKey);
        params.key = _withdrawalKey;
        params.cumulativePnl = Oracle.getCumulativePnl(priceFeed, address(market), params.withdrawal.requestTimestamp);
        params.shouldUnwrap = params.withdrawal.reverseWrap;
        // Get the signed prices
        (params.longPrices, params.shortPrices) = Oracle.getVaultPrices(priceFeed, params.withdrawal.requestTimestamp);
        // Calculate cumulative borrow fees
        params.longBorrowFeesUsd = Borrowing.getTotalFeesOwedByMarket(market, true);
        params.shortBorrowFeesUsd = Borrowing.getTotalFeesOwedByMarket(market, false);
        params.vault = market.VAULT();
    }

    /**
     * ======================= Core Functions =======================
     */
    function calculateDepositFee(
        Oracle.Prices memory _longPrices,
        Oracle.Prices memory _shortPrices,
        uint256 _longTokenBalance,
        uint256 _shortTokenBalance,
        uint256 _tokenAmount,
        bool _isLongToken
    ) public pure returns (uint256) {
        uint256 baseFee = _tokenAmount.percentage(BASE_FEE);
        // If long / short token balance = 0 return Base Fee
        if (_longTokenBalance == 0 || _shortTokenBalance == 0) return baseFee;
        // Maximize to increase the impact on the skew
        uint256 amountUsd = _isLongToken
            ? _tokenAmount.toUsd(_longPrices.max, LONG_BASE_UNIT)
            : _tokenAmount.toUsd(_shortPrices.max, SHORT_BASE_UNIT);
        if (amountUsd == 0) revert MarketUtils_AmountTooSmall();
        // Minimize value of pool to maximise the effect on the skew
        uint256 longValue = _longTokenBalance.toUsd(_longPrices.min, LONG_BASE_UNIT);
        uint256 shortValue = _shortTokenBalance.toUsd(_shortPrices.min, SHORT_BASE_UNIT);

        // Don't want to disincentivise deposits on empty pool
        if (longValue == 0 && _isLongToken) return baseFee;
        if (shortValue == 0 && !_isLongToken) return baseFee;

        int256 initSkew = longValue.diff(shortValue);
        _isLongToken ? longValue += amountUsd : shortValue += amountUsd;
        int256 updatedSkew = longValue.diff(shortValue);

        // Check for a Skew Flip
        bool skewFlip = initSkew ^ updatedSkew < 0;

        // Skew Improve Same Side - Charge the Base fee
        if (updatedSkew.abs() < initSkew.abs() && !skewFlip) return baseFee;
        // If Flip, charge full Skew After, else charge the delta
        uint256 negativeSkewAccrued = skewFlip ? updatedSkew.abs() : amountUsd;
        // Calculate the relative impact on Market Skew
        uint256 feeFactor = FEE_SCALE.percentage(negativeSkewAccrued, longValue + shortValue);
        // Calculate the additional fee
        uint256 feeAddition = _tokenAmount.percentage(feeFactor);
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
        uint256 baseFee = _tokenAmount.percentage(BASE_FEE);

        // Maximize to increase the impact on the skew
        uint256 amountUsd = _isLongToken
            ? _tokenAmount.toUsd(_longPrice, LONG_BASE_UNIT)
            : _tokenAmount.toUsd(_shortPrice, SHORT_BASE_UNIT);
        if (amountUsd == 0) revert MarketUtils_AmountTooSmall();
        // Minimize value of pool to maximise the effect on the skew
        uint256 longValue = _longTokenBalance.toUsd(_longPrice, LONG_BASE_UNIT);
        uint256 shortValue = _shortTokenBalance.toUsd(_shortPrice, SHORT_BASE_UNIT);

        int256 initSkew = longValue.diff(shortValue);
        _isLongToken ? longValue -= amountUsd : shortValue -= amountUsd;
        int256 updatedSkew = longValue.diff(shortValue);

        if (longValue + shortValue == 0) {
            // Charge the maximium possible fee for full withdrawals
            return baseFee + _tokenAmount.percentage(FEE_SCALE);
        }

        // Check for a Skew Flip
        bool skewFlip = initSkew ^ updatedSkew < 0;

        // Skew Improve Same Side - Charge the Base fee
        if (updatedSkew.abs() < initSkew.abs() && !skewFlip) return baseFee;
        // If Flip, charge full Skew After, else charge the delta
        uint256 negativeSkewAccrued = skewFlip ? updatedSkew.abs() : amountUsd;
        // Calculate the relative impact on Market Skew
        // Re-add amount to get the initial net pool value
        uint256 feeFactor = FEE_SCALE.percentage(negativeSkewAccrued, longValue + shortValue + amountUsd);
        // Calculate the additional fee

        uint256 feeAddition = _tokenAmount.percentage(feeFactor);
        // Return base fee + fee addition
        return baseFee + feeAddition;
    }

    function calculateDepositAmounts(IVault.ExecuteDeposit calldata _params)
        external
        view
        returns (uint256 afterFeeAmount, uint256 fee, uint256 mintAmount)
    {
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
            _params.vault,
            _params.longPrices,
            _params.shortPrices,
            afterFeeAmount,
            _params.longBorrowFeesUsd,
            _params.shortBorrowFeesUsd,
            _params.cumulativePnl,
            _params.deposit.isLongToken
        );
    }

    function calculateWithdrawalAmounts(IVault.ExecuteWithdrawal memory _params)
        external
        view
        returns (uint256 tokenAmountOut)
    {
        // Validate the Amount Out vs Expected Amount out
        uint256 amountOut = calculateWithdrawalAmount(
            _params.market,
            _params.vault,
            _params.longPrices,
            _params.shortPrices,
            _params.withdrawal.amountIn,
            _params.longBorrowFeesUsd,
            _params.shortBorrowFeesUsd,
            _params.cumulativePnl,
            _params.withdrawal.isLongToken
        );

        if (_params.amountOut != amountOut) revert MarketUtils_InvalidAmountOut(_params.amountOut, amountOut);

        // Calculate Fee on the Amount Out
        uint256 fee = calculateWithdrawalFee(
            _params.longPrices.med,
            _params.shortPrices.med,
            _params.market.longTokenBalance(),
            _params.market.shortTokenBalance(),
            amountOut,
            _params.withdrawal.isLongToken
        );

        // Calculate the Token Amount Out
        tokenAmountOut = amountOut - fee;
    }

    function validateDeposit(
        IVault.State memory _initialState,
        IVault.State memory _updatedState,
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
        IVault.State memory _initialState,
        IVault.State memory _updatedState,
        uint256 _marketTokenAmountIn,
        uint256 _amountOut,
        bool _isLongToken
    ) external pure {
        uint256 minFee = _amountOut.percentage(BASE_FEE);
        uint256 maxFee = _amountOut.percentage(BASE_FEE + FEE_SCALE);
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
        IVault vault,
        Oracle.Prices memory _longPrices,
        Oracle.Prices memory _shortPrices,
        uint256 _amountIn,
        uint256 _longBorrowFeesUsd,
        uint256 _shortBorrowFeesUsd,
        int256 _cumulativePnl,
        bool _isLongToken
    ) public view returns (uint256 marketTokenAmount) {
        // Maximize the AUM
        uint256 marketTokenPrice = getMarketTokenPrice(
            market, vault, _longPrices.max, _longBorrowFeesUsd, _shortPrices.max, _shortBorrowFeesUsd, _cumulativePnl
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
                ? _amountIn.toUsd(_longPrices.min, LONG_BASE_UNIT)
                : _amountIn.toUsd(_shortPrices.min, SHORT_BASE_UNIT);
            // (30dp * 18dp / 30dp) = 18dp
            marketTokenAmount = mulDiv(valueUsd, PRECISION, marketTokenPrice);
        }
    }

    function calculateWithdrawalAmount(
        IMarket market,
        IVault vault,
        Oracle.Prices memory _longPrices,
        Oracle.Prices memory _shortPrices,
        uint256 _marketTokenAmountIn,
        uint256 _longBorrowFeesUsd,
        uint256 _shortBorrowFeesUsd,
        int256 _cumulativePnl,
        bool _isLongToken
    ) public view returns (uint256 tokenAmount) {
        // Minimize the AUM
        uint256 marketTokenPrice = getMarketTokenPrice(
            market, vault, _longPrices.min, _longBorrowFeesUsd, _shortPrices.min, _shortBorrowFeesUsd, _cumulativePnl
        );
        uint256 valueUsd = _marketTokenAmountIn.toUsd(marketTokenPrice, PRECISION);
        // Minimize the Value of the Amount Out
        if (_isLongToken) {
            tokenAmount = valueUsd.fromUsd(_longPrices.max, LONG_BASE_UNIT);
            uint256 poolBalance = market.longTokenBalance();
            if (tokenAmount > poolBalance) tokenAmount = poolBalance;
        } else {
            tokenAmount = valueUsd.fromUsd(_shortPrices.max, SHORT_BASE_UNIT);
            uint256 poolBalance = market.shortTokenBalance();
            if (tokenAmount > poolBalance) tokenAmount = poolBalance;
        }
    }

    /**
     * ======================= Utility Functions =======================
     */
    function getMarketTokenPrice(
        IMarket market,
        IVault vault,
        uint256 _longTokenPrice,
        uint256 _longBorrowFeesUsd,
        uint256 _shortTokenPrice,
        uint256 _shortBorrowFeesUsd,
        int256 _cumulativePnl
    ) public view returns (uint256 lpTokenPrice) {
        uint256 totalSupply = vault.totalSupply();
        if (totalSupply == 0) {
            lpTokenPrice = 0;
        } else {
            uint256 aum = getAum(
                market, _longTokenPrice, _longBorrowFeesUsd, _shortTokenPrice, _shortBorrowFeesUsd, _cumulativePnl
            );
            lpTokenPrice = aum.div(totalSupply);
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
        aum += (market.longTokenBalance() - market.longTokensReserved()).toUsd(_longTokenPrice, LONG_BASE_UNIT);
        aum += (market.shortTokenBalance() - market.shortTokensReserved()).toUsd(_shortTokenPrice, SHORT_BASE_UNIT);

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
        uint256 averageEntryPrice = _getAverageEntryPrice(market, _ticker, _isLong);
        if (openInterest == 0 || averageEntryPrice == 0) return 0;
        int256 priceDelta = _indexPrice.diff(averageEntryPrice);
        uint256 entryIndexAmount = openInterest.fromUsd(averageEntryPrice, _indexBaseUnit);
        if (_isLong) {
            netPnl = mulDivSigned(priceDelta, entryIndexAmount.toInt256(), _indexBaseUnit.toInt256());
        } else {
            netPnl = -mulDivSigned(priceDelta, entryIndexAmount.toInt256(), _indexBaseUnit.toInt256());
        }
    }

    /**
     * Only to be called externally. Very gas inefficient, as it loops through all positions.
     */
    function calculateCumulativeMarketPnl(
        IMarket market,
        IPriceFeed priceFeed,
        uint48 _requestTimestamp,
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
                ? Oracle.getMaxPrice(priceFeed, ticker, _requestTimestamp)
                : Oracle.getMinPrice(priceFeed, ticker, _requestTimestamp);
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
        poolAmount = totalAvailableLiquidity.percentage(allocationShare, MAX_ALLOCATION);
    }

    function getPoolBalanceUsd(
        IMarket market,
        string calldata _ticker,
        uint256 _collateralTokenPrice,
        uint256 _collateralBaseUnit,
        bool _isLong
    ) public view returns (uint256 poolUsd) {
        poolUsd = getPoolBalance(market, _ticker, _isLong).toUsd(_collateralTokenPrice, _collateralBaseUnit);
    }

    function validateAllocation(
        IMarket market,
        string calldata _ticker,
        uint256 _sizeDeltaUsd,
        uint256 _indexPrice,
        uint256 _collateralTokenPrice,
        uint256 _indexBaseUnit,
        bool _isLong
    ) external view {
        // Get Max OI for side
        uint256 availableUsd =
            getAvailableOiUsd(market, _ticker, _indexPrice, _collateralTokenPrice, _indexBaseUnit, _isLong);
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
        uint256 longOiUsd = getAvailableOiUsd(market, _ticker, _indexPrice, _longTokenPrice, _indexBaseUnit, true);
        uint256 shortOiUsd = getAvailableOiUsd(market, _ticker, _indexPrice, _shortTokenPrice, _indexBaseUnit, false);
        totalAvailableOiUsd = longOiUsd + shortOiUsd;
    }

    /// @notice returns the available remaining open interest for a side in USD
    function getAvailableOiUsd(
        IMarket market,
        string calldata _ticker,
        uint256 _indexPrice,
        uint256 _collateralTokenPrice,
        uint256 _indexBaseUnit,
        bool _isLong
    ) public view returns (uint256 availableOi) {
        uint256 collateralBaseUnit = _isLong ? LONG_BASE_UNIT : SHORT_BASE_UNIT;
        // get the allocation and subtract by the markets reserveFactor
        uint256 remainingAllocationUsd =
            getPoolBalanceUsd(market, _ticker, _collateralTokenPrice, collateralBaseUnit, _isLong);
        availableOi = remainingAllocationUsd - remainingAllocationUsd.percentage(_getReserveFactor(market, _ticker));

        // get the pnl
        int256 pnl = getMarketPnl(market, _ticker, _indexPrice, _indexBaseUnit, _isLong);

        // if the pnl is positive, subtract it from the available oi
        if (pnl > 0) {
            uint256 absPnl = pnl.abs();
            // If PNL > Available OI, set OI to 0
            if (absPnl > availableOi) availableOi = 0;
            else availableOi -= absPnl;
        }
        // no negative case, as OI hasn't been freed / realised
    }

    function getMaxOpenInterest(
        IMarket market,
        string calldata _ticker,
        uint256 _collateralPrice,
        uint256 _collateralBaseUnit,
        bool _isLong
    ) external view returns (uint256 maxOpenInterest) {
        // get the total liquidity available for that side
        uint256 totalAvailableLiquidity = market.totalAvailableLiquidity(_isLong);
        // calculate liquidity allocated to the market for that side
        uint256 poolAmount = totalAvailableLiquidity.percentage(getAllocation(market, _ticker), MAX_ALLOCATION);
        // subtract the reserve factor from the pool amount and convert to USD
        maxOpenInterest = (poolAmount - poolAmount.percentage(_getReserveFactor(market, _ticker))).toUsd(
            _collateralPrice, _collateralBaseUnit
        );
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

        // (PNL / Pool USD)
        uint256 factor = pnl.abs().ceilDiv(poolUsd);

        return pnl > 0 ? factor.toInt256() : factor.toInt256() * -1;
    }

    /**
     * Calculates the price at which the Pnl Factor is > 0.45 (or MAX_PNL_FACTOR).
     * Note that once this price is reached, the pnl factor may not be exceeded,
     * as the price of the collateral changes dynamically also.
     * It wouldn't be possible to account for this predictably.
     */
    function getAdlThreshold(
        IMarket market,
        string calldata _ticker,
        uint256 _collateralPrice,
        uint256 _collateralBaseUnit,
        bool _isLong
    ) external view returns (uint256 adlPrice) {
        // Get the current average entry price and open interest
        uint256 averageEntryPrice = _getAverageEntryPrice(market, _ticker, _isLong);
        uint256 openInterest = getOpenInterest(market, _ticker, _isLong);

        // Get the pool balance in USD
        uint256 poolUsd = getPoolBalanceUsd(market, _ticker, _collateralPrice, _collateralBaseUnit, _isLong);

        // Calculate the maximum PNL allowed based on the pool balance and max PNL factor
        uint256 maxProfit = poolUsd.percentage(MAX_PNL_FACTOR);

        uint256 priceDelta = averageEntryPrice.mulDivCeil(maxProfit, openInterest);

        if (_isLong) {
            // For long positions, ADL price is:
            // averageEntryPrice + (maxProfit * averageEntryPrice) / openInterest
            adlPrice = averageEntryPrice + priceDelta;
        } else {
            // For short positions, ADL price is:
            // averageEntryPrice - (maxProfit * averageEntryPrice) / openInterest
            // if price delta > average entry price, it's impossible, as price can't be 0.
            if (priceDelta > averageEntryPrice) revert MarketUtils_AdlCantOccur();
            adlPrice = averageEntryPrice - priceDelta;
        }
    }

    /**
     * Loop through all open positions on the market, calculate the pnl for the position.
     * Then calculate the ADL Target score for each position, returning the position key
     * with the highest ADL Target Score, which is essentially the position that is next
     * in priority for ADL.
     *
     * The formula is adapted from Bybit's as:
     *
     * ADL Target Score = ( Position Size / Total Pool Size) * (Position PnL / Position Size)
     *
     * This function requires loops, so should *never* be used onchain. It is simply a queryable
     * function from frontends to determine the next optimal position to be adl'd. Also,
     * optimistically assumes accurate pricing data.
     *
     * Users are incentivized to target these positions as they'll generate them the
     * most profit in the event of ADL.
     */
    function getNextAdlTarget(
        ITradeStorage tradeStorage,
        string memory _ticker,
        uint256 _indexPrice,
        uint256 _indexBaseUnit,
        uint256 _totalPoolSizeUsd,
        bool _isLong
    ) external view returns (bytes32 positionKey) {
        // Get all Position Keys
        bytes32[] memory positionKeys = tradeStorage.getOpenPositionKeys(_isLong);
        uint256 len = positionKeys.length;
        uint256 highestAdlScore;
        for (uint256 i = 0; i < len;) {
            Position.Data memory position = tradeStorage.getPosition(positionKeys[i]);
            if (keccak256(abi.encode(position.ticker)) != keccak256(abi.encode(_ticker))) continue;
            // Get the PNL for the position
            int256 pnl = Position.getPositionPnl(
                position.size, position.weightedAvgEntryPrice, _indexPrice, _indexBaseUnit, _isLong
            );
            if (pnl < 0) continue;
            // Calculate the ADL Target Score
            uint256 adlTargetScore = (position.size / _totalPoolSizeUsd) * (pnl.abs() / position.size);
            if (adlTargetScore > highestAdlScore) {
                highestAdlScore = adlTargetScore;
                positionKey = positionKeys[i];
            }
            unchecked {
                ++i;
            }
        }
    }

    /**
     * ======================= Getter Functions =======================
     */
    function getCumulativeBorrowFees(IMarket market, string calldata _ticker)
        external
        view
        returns (uint256 longCumulativeBorrowFees, uint256 shortCumulativeBorrowFees)
    {
        Pool.Cumulatives memory cumulatives = market.getCumulatives(_ticker);
        return (cumulatives.longCumulativeBorrowFees, cumulatives.shortCumulativeBorrowFees);
    }

    function getCumulativeBorrowFee(IMarket market, string calldata _ticker, bool _isLong)
        public
        view
        returns (uint256)
    {
        return _isLong
            ? market.getCumulatives(_ticker).longCumulativeBorrowFees
            : market.getCumulatives(_ticker).shortCumulativeBorrowFees;
    }

    function getLastUpdate(IMarket market, string calldata _ticker) external view returns (uint48) {
        return market.getStorage(_ticker).lastUpdate;
    }

    function getFundingRates(IMarket market, string calldata _ticker)
        external
        view
        returns (int64 rate, int64 velocity)
    {
        Pool.Storage memory pool = market.getStorage(_ticker);
        return (pool.fundingRate, pool.fundingRateVelocity);
    }

    function getFundingAccrued(IMarket market, string calldata _ticker) external view returns (int256) {
        return market.getStorage(_ticker).fundingAccruedUsd;
    }

    function getBorrowingRate(IMarket market, string calldata _ticker, bool _isLong) external view returns (uint256) {
        return _isLong ? market.getStorage(_ticker).longBorrowingRate : market.getStorage(_ticker).shortBorrowingRate;
    }

    function getMaintenanceMargin(IMarket market, string calldata _ticker) external view returns (uint256) {
        return market.getConfig(_ticker).maintenanceMargin;
    }

    function getMaxLeverage(IMarket market, string calldata _ticker) external view returns (uint8) {
        return market.getConfig(_ticker).maxLeverage;
    }

    function getAllocation(IMarket market, string calldata _ticker) public view returns (uint8) {
        return market.getStorage(_ticker).allocationShare;
    }

    function getOpenInterest(IMarket market, string memory _ticker, bool _isLong) public view returns (uint256) {
        return _isLong ? market.getStorage(_ticker).longOpenInterest : market.getStorage(_ticker).shortOpenInterest;
    }

    function getAverageCumulativeBorrowFee(IMarket market, string calldata _ticker, bool _isLong)
        external
        view
        returns (uint256)
    {
        return _isLong
            ? market.getCumulatives(_ticker).weightedAvgCumulativeLong
            : market.getCumulatives(_ticker).weightedAvgCumulativeShort;
    }

    function generateAssetId(string memory _ticker) external pure returns (bytes32) {
        return keccak256(abi.encode(_ticker));
    }

    function hasSufficientLiquidity(IMarket market, uint256 _amount, bool _isLong) external view {
        if (market.totalAvailableLiquidity(_isLong) < _amount) {
            revert MarketUtils_InsufficientFreeLiquidity();
        }
    }

    /// @dev - Allocations are in the same order as the tickers in the market array.
    /// Only used to externally encode desired allocations to input into a function call.
    function encodeAllocations(uint8[] calldata _allocs) public pure returns (bytes memory allocations) {
        allocations = new bytes(_allocs.length);
        for (uint256 i = 0; i < _allocs.length;) {
            allocations[i] = bytes1(_allocs[i]);
            unchecked {
                ++i;
            }
        }
    }

    /**
     * ======================= Private Functions =======================
     */
    function _getAverageEntryPrice(IMarket market, string memory _ticker, bool _isLong)
        private
        view
        returns (uint256)
    {
        return _isLong
            ? market.getCumulatives(_ticker).longAverageEntryPriceUsd
            : market.getCumulatives(_ticker).shortAverageEntryPriceUsd;
    }

    function _getReserveFactor(IMarket market, string calldata _ticker) private view returns (uint256) {
        return market.getConfig(_ticker).reserveFactor.expandDecimals(2, 18);
    }
}
