// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IMarket} from "./interfaces/IMarket.sol";
import {IVault} from "./interfaces/IVault.sol";
import {Funding} from "../libraries/Funding.sol";
import {Borrowing} from "../libraries/Borrowing.sol";
import {MarketUtils} from "./MarketUtils.sol";

library Pool {
    event MarketStateUpdated(string ticker, bool isLong);

    error Pool_InvalidTicker();
    error Pool_InvalidLeverage();
    error Pool_InvalidReserveFactor();
    error Pool_InvalidMaxVelocity();
    error Pool_InvalidSkewScale();
    error Pool_InvalidSkewScalar();
    error Pool_InvalidLiquidityScalar();
    error Pool_InvalidUpdate();

    uint8 private constant MAX_ASSETS = 100;
    uint32 private constant MAX_LEVERAGE = 1000; // Max 1000x leverage
    uint64 private constant MIN_MAINTENANCE_MARGIN = 50; // 0.5%
    uint64 private constant MAX_MAINTENANCE_MARGIN = 1000; // 10%
    uint64 private constant MIN_RESERVE_FACTOR = 1000; // 10% reserve factor
    uint64 private constant MAX_RESERVE_FACTOR = 5000; // 50% reserve factor
    int64 private constant MIN_VELOCITY = 10; // 0.1% per day
    int64 private constant MAX_VELOCITY = 2000; // 20% per day
    int256 private constant MIN_SKEW_SCALE = 1000; // $1000
    int256 private constant MAX_SKEW_SCALE = 10_000_000_000; // $10 Bn
    int16 private constant MAX_SCALAR = 10000;

    struct Input {
        uint256 amountIn;
        uint256 executionFee;
        address owner;
        uint48 requestTimestamp;
        bool isLongToken;
        bool reverseWrap;
        bool isDeposit;
        bytes32 key;
        bytes32 priceRequestKey; // Key of the price update request
        bytes32 pnlRequestKey; // Id of the cumulative pnl request
    }

    struct Storage {
        Config config;
        Cumulatives cumulatives;
        uint256 longOpenInterest;
        uint256 shortOpenInterest;
        /**
         * The rate at which funding is accumulated.
         */
        int64 fundingRate;
        /**
         * The rate at which the funding rate is changing.
         */
        int64 fundingRateVelocity;
        /**
         * The rate at which borrowing fees are accruing for longs.
         */
        uint64 longBorrowingRate;
        /**
         * The rate at which borrowing fees are accruing for shorts.
         */
        uint64 shortBorrowingRate;
        /**
         * The last time the storage was updated.
         */
        uint48 lastUpdate;
        /**
         * Number of shares allocated to each sub-market.
         * A market can contain multiple index tokens, each of which have
         * a percentage of liquidity allocated to them.
         * Units are in shares, where 100% = 100
         * Cumulative allocations must total up to 100.
         */
        uint8 allocationShare;
        /**
         * The value (in USD) of total market funding accumulated.
         * Swings back and forth across 0 depending on the velocity / funding rate.
         */
        int256 fundingAccruedUsd;
        /**
         * The size of the Price impact pool.
         * Negative price impact is accumulated in the pool.
         * Positive price impact is paid out of the pool.
         * Units in USD (30 D.P).
         */
        uint256 impactPool;
    }

    struct Cumulatives {
        /**
         * The weighted average entry price of all long positions in the market.
         */
        uint256 longAverageEntryPriceUsd;
        /**
         * The weighted average entry price of all short positions in the market.
         */
        uint256 shortAverageEntryPriceUsd;
        /**
         * The value (%) of the total market borrowing fees accumulated for longs.
         */
        uint256 longCumulativeBorrowFees;
        /**
         * The value (%) of the total market borrowing fees accumulated for shorts.
         */
        uint256 shortCumulativeBorrowFees;
        /**
         * The average cumulative borrow fees at entry for long positions in the market.
         * Used to calculate total borrow fees owed for the market.
         */
        uint256 weightedAvgCumulativeLong;
        /**
         * The average cumulative borrow fees at entry for short positions in the market.
         * Used to calculate total borrow fees owed for the market.
         */
        uint256 weightedAvgCumulativeShort;
    }

    struct Config {
        /**
         * Maximum Leverage for the Market
         * Value to 0 decimal places. E.g. 5 = 5x leverage.
         */
        uint8 maxLeverage;
        /**
         * Percentage of the position's size that must be maintained as margin.
         * Used to prevent liquidation threshold from being at the point
         * of insolvency.
         * 2 d.p. precision. 1050 = 10.5%
         */
        uint16 maintenanceMargin;
        /**
         * % of liquidity that CAN'T be allocated to positions
         * Reserves should be higher for more volatile markets.
         * 2 d.p precision. 2500 = 25%
         */
        uint16 reserveFactor;
        /**
         * Maximum Funding Velocity
         * Units: % Per Day
         * 2 d.p precision. 1000 = 10%
         */
        int16 maxFundingVelocity;
        /**
         * Sensitivity to Market Skew
         * Units: USD
         * No decimals --> 1_000_000 = $1,000,000
         */
        int48 skewScale;
        /**
         * Dampening factor for the effect of skew in positive price impact.
         * Value as a percentage, with 2 d.p of precision.
         * Needs to be expanded to 30 dp for USD calculations.
         */
        int16 positiveSkewScalar;
        /**
         * Dampening factor for the effect of skew in negative price impact.
         * Value as a percentage, with 2 d.p of precision.
         * Needs to be expanded to 30 dp for USD calculations.
         */
        int16 negativeSkewScalar;
        /**
         * Dampening factor for the effect of liquidity in positive price impact.
         * Value as a percentage, with 2 d.p of precision.
         * Needs to be expanded to 30 dp for USD calculations.
         */
        int16 positiveLiquidityScalar;
        /**
         * Dampening factor for the effect of liquidity in negative price impact.
         * Value as a percentage, with 2 d.p of precision.
         * Needs to be expanded to 30 dp for USD calculations.
         */
        int16 negativeLiquidityScalar;
    }

    function initialize(Storage storage pool, Config memory _config) internal {
        pool.allocationShare = 100;
        pool.config = _config;
        pool.lastUpdate = uint48(block.timestamp);
    }

    /// @dev Needs to be external to keep bytecode size below threshold.
    function updateState(
        IVault vault,
        Storage storage pool,
        string calldata _ticker,
        uint256 _sizeDelta,
        uint256 _indexPrice,
        uint256 _impactedPrice,
        uint256 _collateralPrice,
        uint256 _collateralBaseUnit,
        bool _isLong,
        bool _isIncrease
    ) external {
        IMarket market = IMarket(address(this));
        if (msg.sender != address(this)) revert Pool_InvalidUpdate();
        // 1. Depends on Open Interest Delta to determine Skew
        Funding.updateState(market, pool, _ticker, _indexPrice);
        if (_sizeDelta != 0) {
            // Use Impacted Price for Entry
            // 2. Relies on Open Interest Delta
            _updateWeightedAverages(
                pool,
                market,
                _ticker,
                _impactedPrice == 0 ? _indexPrice : _impactedPrice, // If no price impact, set to the index price
                _isIncrease ? int256(_sizeDelta) : -int256(_sizeDelta),
                _isLong
            );
            // 3. Updated pre-borrowing rate if size delta > 0
            if (_isIncrease) {
                if (_isLong) {
                    pool.longOpenInterest += _sizeDelta;
                } else {
                    pool.shortOpenInterest += _sizeDelta;
                }
            } else {
                if (_isLong) {
                    pool.longOpenInterest -= _sizeDelta;
                } else {
                    pool.shortOpenInterest -= _sizeDelta;
                }
            }
        }
        // 4. Relies on Updated Open interest
        Borrowing.updateState(market, vault, pool, _ticker, _collateralPrice, _collateralBaseUnit, _isLong);
        // 5. Update the last update time
        pool.lastUpdate = uint48(block.timestamp);
        // Fire Event
        emit MarketStateUpdated(_ticker, _isLong);
    }

    /**
     * ============================= External Functions =============================
     */
    function createRequest(
        address _owner,
        address _transferToken, // Token In for Deposits, Out for Withdrawals
        uint256 _amountIn,
        uint256 _executionFee,
        bytes32 _priceRequestKey,
        bytes32 _pnlRequestKey,
        address _weth,
        bool _reverseWrap,
        bool _isDeposit
    ) external view returns (Pool.Input memory) {
        return Pool.Input({
            amountIn: _amountIn,
            executionFee: _executionFee,
            owner: _owner,
            requestTimestamp: uint48(block.timestamp),
            isLongToken: _transferToken == _weth,
            reverseWrap: _reverseWrap,
            isDeposit: _isDeposit,
            key: _generateKey(_owner, _transferToken, _amountIn, _isDeposit),
            priceRequestKey: _priceRequestKey,
            pnlRequestKey: _pnlRequestKey
        });
    }

    function validateConfig(Config calldata _config) external pure {
        /* 1. Validate the initial inputs */
        // Check Leverage is within bounds
        if (_config.maxLeverage == 0 || _config.maxLeverage > MAX_LEVERAGE) {
            revert Pool_InvalidLeverage();
        }
        // Check maintenance margin is within bounds
        if (_config.maintenanceMargin < MIN_MAINTENANCE_MARGIN || _config.maintenanceMargin > MAX_MAINTENANCE_MARGIN) {
            revert Pool_InvalidLeverage();
        }
        // Check the Reserve Factor is within bounds
        if (_config.reserveFactor < MIN_RESERVE_FACTOR || _config.reserveFactor > MAX_RESERVE_FACTOR) {
            revert Pool_InvalidReserveFactor();
        }
        /* 2. Validate the Funding Values */
        // Check the Max Velocity is within bounds
        if (_config.maxFundingVelocity < MIN_VELOCITY || _config.maxFundingVelocity > MAX_VELOCITY) {
            revert Pool_InvalidMaxVelocity();
        }
        // Check the Skew Scale is within bounds
        if (_config.skewScale < MIN_SKEW_SCALE || _config.skewScale > MAX_SKEW_SCALE) {
            revert Pool_InvalidSkewScale();
        }
        /* 3. Validate Impact Values */
        // Check Skew Scalars are > 0 and <= 100%
        if (_config.positiveSkewScalar <= 0 || _config.positiveSkewScalar > MAX_SCALAR) {
            revert Pool_InvalidSkewScalar();
        }
        if (_config.negativeSkewScalar <= 0 || _config.negativeSkewScalar > MAX_SCALAR) {
            revert Pool_InvalidSkewScalar();
        }
        // Check negative skew scalar is >= positive skew scalar
        if (_config.negativeSkewScalar < _config.positiveSkewScalar) {
            revert Pool_InvalidSkewScalar();
        }
        // Check Liquidity Scalars are > 0 and <= 100%
        if (_config.positiveLiquidityScalar <= 0 || _config.positiveLiquidityScalar > MAX_SCALAR) {
            revert Pool_InvalidLiquidityScalar();
        }
        if (_config.negativeLiquidityScalar <= 0 || _config.negativeLiquidityScalar > MAX_SCALAR) {
            revert Pool_InvalidLiquidityScalar();
        }
        // Check negative liquidity scalar is >= positive liquidity scalar
        if (_config.negativeLiquidityScalar < _config.positiveLiquidityScalar) {
            revert Pool_InvalidLiquidityScalar();
        }
    }

    /**
     * ========================= Private Functions =========================
     */

    /**
     * Updates the weighted average values for the market. Both rely on the market condition pre-open interest update.
     */
    function _updateWeightedAverages(
        Pool.Storage storage _storage,
        IMarket market,
        string calldata _ticker,
        uint256 _priceUsd,
        int256 _sizeDeltaUsd,
        bool _isLong
    ) private {
        if (_sizeDeltaUsd == 0) return;

        if (_isLong) {
            _storage.cumulatives.longAverageEntryPriceUsd = MarketUtils.calculateWeightedAverageEntryPrice(
                _storage.cumulatives.longAverageEntryPriceUsd, _storage.longOpenInterest, _sizeDeltaUsd, _priceUsd
            );
            _storage.cumulatives.weightedAvgCumulativeLong =
                Borrowing.getNextAverageCumulative(market, _ticker, _sizeDeltaUsd, true);
        } else {
            _storage.cumulatives.shortAverageEntryPriceUsd = MarketUtils.calculateWeightedAverageEntryPrice(
                _storage.cumulatives.shortAverageEntryPriceUsd, _storage.shortOpenInterest, _sizeDeltaUsd, _priceUsd
            );
            _storage.cumulatives.weightedAvgCumulativeShort =
                Borrowing.getNextAverageCumulative(market, _ticker, _sizeDeltaUsd, false);
        }
    }

    function _generateKey(address _owner, address _tokenIn, uint256 _tokenAmount, bool _isDeposit)
        private
        view
        returns (bytes32)
    {
        return keccak256(abi.encode(_owner, _tokenIn, _tokenAmount, _isDeposit, block.timestamp));
    }
}