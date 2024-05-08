// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IMarket} from "./interfaces/IMarket.sol";
import {IVault} from "./interfaces/IVault.sol";
import {Casting} from "../libraries/Casting.sol";
import {IPriceFeed} from "../oracle/interfaces/IPriceFeed.sol";
import {Oracle} from "../oracle/Oracle.sol";
import {Borrowing} from "../libraries/Borrowing.sol";
import {MathUtils} from "../libraries/MathUtils.sol";
import {ITradeStorage} from "../positions/interfaces/ITradeStorage.sol";
import {Pool} from "./Pool.sol";
import {Units} from "../libraries/Units.sol";
import {MarketId} from "../types/MarketId.sol";

library MarketUtils {
    using Casting for uint256;
    using Casting for int256;
    using MathUtils for uint256;
    using MathUtils for int256;
    using MathUtils for uint16;
    using Units for uint256;
    using Units for uint64;

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
    error MarketUtils_AmountTooSmall();
    error MarketUtils_InvalidAmountOut(uint256 amountOut, uint256 expectedOut);
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
     * =========================================== Constructor Functions ===========================================
     */
    function constructDepositParams(MarketId _id, IPriceFeed priceFeed, IMarket market, bytes32 _depositKey)
        external
        view
        returns (IVault.ExecuteDeposit memory params)
    {
        params.market = market;
        params.deposit = market.getRequest(_id, _depositKey);
        params.key = _depositKey;

        (params.longPrices, params.shortPrices) = Oracle.getVaultPrices(priceFeed, params.deposit.requestTimestamp);

        params.longBorrowFeesUsd = Borrowing.getTotalFeesOwedByMarket(_id, market, true);
        params.shortBorrowFeesUsd = Borrowing.getTotalFeesOwedByMarket(_id, market, false);

        params.cumulativePnl = Oracle.getCumulativePnl(priceFeed, address(market), params.deposit.requestTimestamp);

        params.vault = market.getVault(_id);
    }

    function constructWithdrawalParams(MarketId _id, IPriceFeed priceFeed, IMarket market, bytes32 _withdrawalKey)
        external
        view
        returns (IVault.ExecuteWithdrawal memory params)
    {
        params.market = market;
        params.withdrawal = market.getRequest(_id, _withdrawalKey);
        params.key = _withdrawalKey;
        params.shouldUnwrap = params.withdrawal.reverseWrap;

        (params.longPrices, params.shortPrices) = Oracle.getVaultPrices(priceFeed, params.withdrawal.requestTimestamp);

        params.longBorrowFeesUsd = Borrowing.getTotalFeesOwedByMarket(_id, market, true);
        params.shortBorrowFeesUsd = Borrowing.getTotalFeesOwedByMarket(_id, market, false);

        params.cumulativePnl = Oracle.getCumulativePnl(priceFeed, address(market), params.withdrawal.requestTimestamp);

        params.vault = market.getVault(_id);
    }

    /**
     * =========================================== Core Functions ===========================================
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

        // If long or short token balance = 0 return Base Fee
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

        // If No Flip + Skew Improved - Charge the Base fee
        if (updatedSkew.abs() < initSkew.abs() && !skewFlip) return baseFee;

        // If Flip, charge full Skew After, else charge the delta
        uint256 negativeSkewAccrued = skewFlip ? updatedSkew.abs() : amountUsd;

        // Calculate the relative impact on Market Skew
        uint256 feeFactor = FEE_SCALE.percentage(negativeSkewAccrued, longValue + shortValue);

        // Calculate the additional fee
        uint256 feeAddition = _tokenAmount.percentage(feeFactor);

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

        // If No Flip + Skew Improved - Charge the Base fee
        if (updatedSkew.abs() < initSkew.abs() && !skewFlip) return baseFee;

        // If Flip, charge full Skew After, else charge the delta
        uint256 negativeSkewAccrued = skewFlip ? updatedSkew.abs() : amountUsd;

        // Calculate the relative impact on Market Skew
        // Re-add amount to get the initial net pool value
        uint256 feeFactor = FEE_SCALE.percentage(negativeSkewAccrued, longValue + shortValue + amountUsd);

        // Calculate the additional fee
        uint256 feeAddition = _tokenAmount.percentage(feeFactor);

        return baseFee + feeAddition;
    }

    function calculateDepositAmounts(IVault.ExecuteDeposit memory _params)
        internal
        view
        returns (uint256 afterFeeAmount, uint256 fee, uint256 mintAmount)
    {
        fee = calculateDepositFee(
            _params.longPrices,
            _params.shortPrices,
            _params.vault.longTokenBalance(),
            _params.vault.shortTokenBalance(),
            _params.deposit.amountIn,
            _params.deposit.isLongToken
        );

        afterFeeAmount = _params.deposit.amountIn - fee;

        mintAmount = calculateMintAmount(
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
        uint256 amountOut = calculateWithdrawalAmount(
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

        uint256 fee = calculateWithdrawalFee(
            _params.longPrices.med,
            _params.shortPrices.med,
            _params.vault.longTokenBalance(),
            _params.vault.shortTokenBalance(),
            amountOut,
            _params.withdrawal.isLongToken
        );

        tokenAmountOut = amountOut - fee;
    }

    /// @dev - Calculate the Mint Amount to 18 decimal places
    function calculateMintAmount(
        IVault vault,
        Oracle.Prices memory _longPrices,
        Oracle.Prices memory _shortPrices,
        uint256 _amountIn,
        uint256 _longBorrowFeesUsd,
        uint256 _shortBorrowFeesUsd,
        int256 _cumulativePnl,
        bool _isLongToken
    ) public view returns (uint256 marketTokenAmount) {
        uint256 marketTokenPrice = getMarketTokenPrice(
            vault, _longPrices.max, _longBorrowFeesUsd, _shortPrices.max, _shortBorrowFeesUsd, _cumulativePnl
        );

        // Long divisor -> (18dp * 30dp / x dp) should = 18dp -> dp = 30
        // Short divisor -> (6dp * 30dp / x dp) should = 18dp -> dp = 18
        // Minimize the Value of the Amount In
        if (marketTokenPrice == 0) {
            marketTokenAmount = _isLongToken
                ? _amountIn.mulDiv(_longPrices.min, LONG_CONVERSION_FACTOR)
                : _amountIn.mulDiv(_shortPrices.min, SHORT_CONVERSION_FACTOR);
        } else {
            uint256 valueUsd = _isLongToken
                ? _amountIn.toUsd(_longPrices.min, LONG_BASE_UNIT)
                : _amountIn.toUsd(_shortPrices.min, SHORT_BASE_UNIT);

            // (30dp * 18dp / 30dp) = 18dp
            marketTokenAmount = valueUsd.mulDiv(PRECISION, marketTokenPrice);
        }
    }

    function calculateWithdrawalAmount(
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
            vault, _longPrices.min, _longBorrowFeesUsd, _shortPrices.min, _shortBorrowFeesUsd, _cumulativePnl
        );

        uint256 valueUsd = _marketTokenAmountIn.toUsd(marketTokenPrice, PRECISION);

        // Minimize the Value of the Amount Out
        if (_isLongToken) {
            tokenAmount = valueUsd.fromUsd(_longPrices.max, LONG_BASE_UNIT);

            uint256 poolBalance = vault.longTokenBalance();

            if (tokenAmount > poolBalance) tokenAmount = poolBalance;
        } else {
            tokenAmount = valueUsd.fromUsd(_shortPrices.max, SHORT_BASE_UNIT);

            uint256 poolBalance = vault.shortTokenBalance();

            if (tokenAmount > poolBalance) tokenAmount = poolBalance;
        }
    }

    /**
     * =========================================== Utility Functions ===========================================
     */
    function getMarketTokenPrice(
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
                vault, _longTokenPrice, _longBorrowFeesUsd, _shortTokenPrice, _shortBorrowFeesUsd, _cumulativePnl
            );

            lpTokenPrice = aum.divWad(totalSupply);
        }
    }

    // Funding Fees should be balanced between the longs and shorts, so don't need to be accounted for.
    // They are however settled through the pool, so maybe they should be accounted for?
    // If not, we must reduce the pool balance for each funding claim, which will account for them.
    function getAum(
        IVault vault,
        uint256 _longTokenPrice,
        uint256 _longBorrowFeesUsd,
        uint256 _shortTokenPrice,
        uint256 _shortBorrowFeesUsd,
        int256 _cumulativePnl
    ) public view returns (uint256 aum) {
        aum += (vault.longTokenBalance() - vault.longTokensReserved()).toUsd(_longTokenPrice, LONG_BASE_UNIT);

        aum += (vault.shortTokenBalance() - vault.shortTokensReserved()).toUsd(_shortTokenPrice, SHORT_BASE_UNIT);

        aum += _longBorrowFeesUsd;

        aum += _shortBorrowFeesUsd;

        // Subtract any Negative Pnl
        // Unrealized Positive Pnl not added to minimize AUM
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
    ) internal pure returns (uint256) {
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

    function getMarketPnl(
        MarketId _id,
        IMarket market,
        string memory _ticker,
        uint256 _indexPrice,
        uint256 _indexBaseUnit,
        bool _isLong
    ) public view returns (int256 netPnl) {
        uint256 openInterest = market.getOpenInterest(_id, _ticker, _isLong);

        uint256 averageEntryPrice = _getAverageEntryPrice(_id, market, _ticker, _isLong);

        if (openInterest == 0 || averageEntryPrice == 0) return 0;

        int256 priceDelta = _indexPrice.diff(averageEntryPrice);

        uint256 entryIndexAmount = openInterest.fromUsd(averageEntryPrice, _indexBaseUnit);

        if (_isLong) {
            netPnl = priceDelta.mulDivSigned(entryIndexAmount.toInt256(), _indexBaseUnit.toInt256());
        } else {
            netPnl = -priceDelta.mulDivSigned(entryIndexAmount.toInt256(), _indexBaseUnit.toInt256());
        }
    }

    function getPoolBalance(MarketId _id, IMarket market, IVault vault, string memory _ticker, bool _isLong)
        public
        view
        returns (uint256 poolAmount)
    {
        uint256 allocationShare = market.getAllocation(_id, _ticker);

        uint256 totalAvailableLiquidity = vault.totalAvailableLiquidity(_isLong);

        poolAmount = totalAvailableLiquidity.percentage(allocationShare, MAX_ALLOCATION);
    }

    function getPoolBalanceUsd(
        MarketId _id,
        IMarket market,
        IVault vault,
        string memory _ticker,
        uint256 _collateralTokenPrice,
        uint256 _collateralBaseUnit,
        bool _isLong
    ) public view returns (uint256 poolUsd) {
        poolUsd = getPoolBalance(_id, market, vault, _ticker, _isLong).toUsd(_collateralTokenPrice, _collateralBaseUnit);
    }

    function validateAllocation(
        MarketId _id,
        IMarket market,
        IVault vault,
        string memory _ticker,
        uint256 _sizeDeltaUsd,
        uint256 _indexPrice,
        uint256 _collateralTokenPrice,
        uint256 _indexBaseUnit,
        bool _isLong
    ) internal view {
        uint256 availableUsd =
            getAvailableOiUsd(_id, market, vault, _ticker, _indexPrice, _collateralTokenPrice, _indexBaseUnit, _isLong);

        if (_sizeDeltaUsd > availableUsd) revert MarketUtils_MaxOiExceeded();
    }

    function getAvailableOiUsd(
        MarketId _id,
        IMarket market,
        IVault vault,
        string memory _ticker,
        uint256 _indexPrice,
        uint256 _collateralTokenPrice,
        uint256 _indexBaseUnit,
        bool _isLong
    ) internal view returns (uint256 availableOi) {
        uint256 collateralBaseUnit = _isLong ? LONG_BASE_UNIT : SHORT_BASE_UNIT;

        uint256 remainingAllocationUsd =
            getPoolBalanceUsd(_id, market, vault, _ticker, _collateralTokenPrice, collateralBaseUnit, _isLong);

        availableOi =
            remainingAllocationUsd - remainingAllocationUsd.percentage(_getReserveFactor(_id, market, _ticker));

        int256 pnl = getMarketPnl(_id, market, _ticker, _indexPrice, _indexBaseUnit, _isLong);

        // if the pnl is positive, subtract it from the available oi
        if (pnl > 0) {
            uint256 absPnl = pnl.abs();

            // If PNL > Available OI, set OI to 0
            if (absPnl > availableOi) availableOi = 0;
            else availableOi -= absPnl;
        }
        // no negative case, as OI hasn't been freed / realised
    }

    /// @dev Doesn't take into account current open interest, or Pnl.
    function getMaxOpenInterest(
        MarketId _id,
        IMarket market,
        IVault vault,
        string memory _ticker,
        uint256 _collateralPrice,
        uint256 _collateralBaseUnit,
        bool _isLong
    ) external view returns (uint256 maxOpenInterest) {
        uint256 totalAvailableLiquidity = vault.totalAvailableLiquidity(_isLong);

        uint256 poolAmount = totalAvailableLiquidity.percentage(market.getAllocation(_id, _ticker), MAX_ALLOCATION);

        maxOpenInterest = (poolAmount - poolAmount.percentage(_getReserveFactor(_id, market, _ticker))).toUsd(
            _collateralPrice, _collateralBaseUnit
        );
    }

    /// @dev Pnl to Pool Ratio - e.g 0.45 = $45 profit to $100 pool.
    function getPnlFactor(
        MarketId _id,
        IMarket market,
        IVault vault,
        string memory _ticker,
        uint256 _indexPrice,
        uint256 _indexBaseUnit,
        uint256 _collateralPrice,
        uint256 _collateralBaseUnit,
        bool _isLong
    ) internal view returns (int256 pnlFactor) {
        uint256 poolUsd = getPoolBalanceUsd(_id, market, vault, _ticker, _collateralPrice, _collateralBaseUnit, _isLong);

        if (poolUsd == 0) {
            return 0;
        }

        int256 pnl = getMarketPnl(_id, market, _ticker, _indexPrice, _indexBaseUnit, _isLong);

        uint256 factor = pnl.abs().divWadUp(poolUsd);

        return pnl > 0 ? factor.toInt256() : factor.toInt256() * -1;
    }

    /**
     * Calculates the price at which the Pnl Factor is > 0.45 (or MAX_PNL_FACTOR).
     * Note that once this price is reached, the pnl factor may not be exceeded,
     * as the price of the collateral changes dynamically also.
     * It wouldn't be possible to account for this predictably.
     */
    function getAdlThreshold(
        MarketId _id,
        IMarket market,
        IVault vault,
        string memory _ticker,
        uint256 _collateralPrice,
        uint256 _collateralBaseUnit,
        bool _isLong
    ) internal view returns (uint256 adlPrice) {
        uint256 averageEntryPrice = _getAverageEntryPrice(_id, market, _ticker, _isLong);

        uint256 openInterest = market.getOpenInterest(_id, _ticker, _isLong);

        uint256 poolUsd = getPoolBalanceUsd(_id, market, vault, _ticker, _collateralPrice, _collateralBaseUnit, _isLong);

        uint256 maxProfit = poolUsd.percentage(MAX_PNL_FACTOR);

        uint256 priceDelta = averageEntryPrice.mulDivUp(maxProfit, openInterest);

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
     * =========================================== External-Only Functions ===========================================
     */

    /// @dev For external queries - very gas inefficient.
    function calculateCumulativeMarketPnl(
        MarketId _id,
        IMarket market,
        IPriceFeed priceFeed,
        uint48 _requestTimestamp,
        bool _isLong,
        bool _maximise
    ) external view returns (int256 cumulativePnl) {
        string[] memory tickers = market.getTickers(_id);

        // Max 100 Loops, so uint8 sufficient
        for (uint8 i = 0; i < tickers.length;) {
            string memory ticker = tickers[i];

            uint256 indexPrice = _maximise
                ? Oracle.getMaxPrice(priceFeed, ticker, _requestTimestamp)
                : Oracle.getMinPrice(priceFeed, ticker, _requestTimestamp);

            uint256 indexBaseUnit = Oracle.getBaseUnit(priceFeed, ticker);

            int256 pnl = getMarketPnl(_id, market, ticker, indexPrice, indexBaseUnit, _isLong);

            cumulativePnl += pnl;

            unchecked {
                ++i;
            }
        }
    }

    /**
     * =========================================== Getter Functions ===========================================
     */
    function generateAssetId(string memory _ticker) internal pure returns (bytes32) {
        return keccak256(abi.encode(_ticker));
    }

    function hasSufficientLiquidity(IVault vault, uint256 _amount, bool _isLong) internal view {
        if (vault.totalAvailableLiquidity(_isLong) < _amount) {
            revert MarketUtils_InsufficientFreeLiquidity();
        }
    }

    /// @dev - Allocations are in the same order as the tickers in the market array.
    /// Allocations are a % to 0 d.p. e.g 1 = 1%
    function encodeAllocations(uint8[] memory _allocs) public pure returns (bytes memory allocations) {
        allocations = new bytes(_allocs.length);

        for (uint256 i = 0; i < _allocs.length;) {
            allocations[i] = bytes1(_allocs[i]);

            unchecked {
                ++i;
            }
        }
    }

    /**
     * =========================================== Private Functions ===========================================
     */
    function _getAverageEntryPrice(MarketId _id, IMarket market, string memory _ticker, bool _isLong)
        private
        view
        returns (uint256)
    {
        return _isLong
            ? market.getCumulatives(_id, _ticker).longAverageEntryPriceUsd
            : market.getCumulatives(_id, _ticker).shortAverageEntryPriceUsd;
    }

    function _getReserveFactor(MarketId _id, IMarket market, string memory _ticker) private view returns (uint256) {
        return market.getConfig(_id, _ticker).reserveFactor.expandDecimals(4, 18);
    }
}
