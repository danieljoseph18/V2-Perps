// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {IVault} from "./IVault.sol";

interface IMarket is IVault {
    /**
     * ================ Storage for Each Market ================
     */
    struct MarketStorage {
        Config config;
        FundingValues funding;
        BorrowingValues borrowing;
        OpenInterestValues openInterest;
        PnlValues pnl;
        /**
         * The size of the Price impact pool.
         * Negative price impact is accumulated in the pool.
         * Positive price impact is paid out of the pool.
         * Units in USD (30 D.P).
         */
        uint256 impactPool;
        /**
         * The percentage of the pool that is allocated to each sub-market.
         * A market can contain multiple index tokens, each of which have
         * a percentage of liquidity allocated to them.
         * Units are in percentage, where 100% = 1e18.
         * Cumulative allocations must total up to 100%
         */
        uint256 allocationPercentage;
    }

    struct FundingValues {
        /**
         * The last time the funding rate was updated.
         */
        uint48 lastFundingUpdate;
        /**
         * The rate at which funding is accumulated.
         */
        int256 fundingRate;
        /**
         * The rate at which the funding rate is changing.
         */
        int256 fundingRateVelocity;
        /**
         * The value (in USD) of total market funding accumulated.
         * Swings back and forth across 0 depending on the velocity / funding rate.
         */
        int256 fundingAccruedUsd;
    }

    struct BorrowingValues {
        uint48 lastBorrowUpdate;
        uint256 longBorrowingRate;
        uint256 longCumulativeBorrowFees;
        uint256 shortBorrowingRate;
        uint256 shortCumulativeBorrowFees;
    }

    struct OpenInterestValues {
        uint256 longOpenInterest;
        uint256 shortOpenInterest;
    }

    struct PnlValues {
        uint256 longAverageEntryPriceUsd;
        uint256 shortAverageEntryPriceUsd;
    }

    /**
     * ================ Config for the Market ================
     */
    struct Config {
        /**
         * Maximum Leverage for the Market
         * Value to 2 Decimal Places -> 100 = 1x, 200 = 2x
         */
        uint32 maxLeverage;
        /**
         * % of liquidity that can't be allocated to positions
         * Reserves should be higher for more volatile markets.
         * Value as a percentage, where 100% = 1e18.
         */
        uint256 reserveFactor;
        /**
         * Funding Config Values
         */
        FundingConfig funding;
        /**
         * Borrowing Config Values
         */
        BorrowingConfig borrowing;
        /**
         * Price Impact Config Values
         */
        ImpactConfig impact;
        /**
         * ADL Config Values
         */
        AdlConfig adl;
    }

    struct AdlConfig {
        /**
         * Maximum PNL:POOL ratio before ADL is triggered.
         */
        uint256 maxPnlFactor;
        /**
         * The Pnl Factor the system aims to reduce the PNL:POOL ratio to.
         */
        uint256 targetPnlFactor;
        /**
         * Flag for ADL on each side
         */
        bool flaggedLong;
        bool flaggedShort;
    }

    struct FundingConfig {
        /**
         * Maximum Funding Velocity
         * Units: % Per Day
         */
        int256 maxVelocity;
        /**
         * Sensitivity to Market Skew
         * Units: USD
         */
        int256 skewScale;
        /**
         * Level of pSkew beyond which funding rate starts to change
         * Units: % Per Day
         */
        uint256 fundingVelocityClamp;
    }

    struct BorrowingConfig {
        uint256 factor;
        uint256 exponent;
    }

    // Used to scale price impact per market
    // Both values lower for less volatile markets
    struct ImpactConfig {
        int256 positiveSkewScalar;
        int256 negativeSkewScalar;
        int256 positiveLiquidityScalar;
        int256 negativeLiquidityScalar;
    }

    /**
     * ================ Errors ================
     */
    error Market_TokenAlreadyExists();
    error Market_TokenDoesNotExist();
    error Market_PriceIsZero();
    error Market_InvalidCumulativeAllocation();

    /**
     * ================ Events ================
     */
    event TokenAdded(address indexed indexToken, Config config);
    event TokenRemoved(address indexed indexToken);
    event MarketConfigUpdated(address indexed indexToken, Config config);
    event AdlStateUpdated(address indexed indexToken, bool isFlaggedForAdl);
    event FundingUpdated(int256 fundingRate, int256 fundingRateVelocity, int256 fundingAccruedUsd);
    event BorrowingRatesUpdated(address indexed indexToken, uint256 longBorrowingRate, uint256 shortBorrowingRate);
    event AverageEntryPriceUpdated(
        address indexed indexToken, uint256 longAverageEntryPriceUsd, uint256 shortAverageEntryPriceUsd
    );
    event OpenInterestUpdated(address indexed indexToken, uint256 longOpenInterestUsd, uint256 shortOpenInterestUsd);

    /**
     * ================ Functions ================
     */
    function addToken(Config memory _config, address _indexToken, uint256[] calldata _newAllocations) external;
    function removeToken(address _indexToken, uint256[] calldata _newAllocations) external;
    function updateConfig(Config memory _config, address _indexToken) external;
    function updateAdlState(address _indexToken, bool _isFlaggedForAdl, bool _isLong) external;
    function updateFundingRate(address _indexToken, uint256 _indexPrice) external;
    function updateBorrowingRate(
        address _indexToken,
        uint256 _indexPrice,
        uint256 _indexBaseUnit,
        uint256 _collateralPrice,
        uint256 _collateralBaseUnit,
        bool _isLong
    ) external;
    function updateAverageEntryPrice(address _indexToken, uint256 _priceUsd, int256 _sizeDeltaUsd, bool _isLong)
        external;
    function updateOpenInterest(address _indexToken, uint256 _sizeDeltaUsd, bool _isLong, bool _shouldAdd) external;
    function updateImpactPool(address _indexToken, int256 _priceImpactUsd) external;

    function getConfig(address _indexToken) external view returns (Config memory);
    function getBorrowingConfig(address _indexToken) external view returns (BorrowingConfig memory);
    function getFundingConfig(address _indexToken) external view returns (FundingConfig memory);
    function getImpactConfig(address _indexToken) external view returns (ImpactConfig memory);
    function getAdlConfig(address _indexToken) external view returns (AdlConfig memory);
    function getReserveFactor(address _indexToken) external view returns (uint256);
    function getMaxLeverage(address _indexToken) external view returns (uint32);
    function getMaxPnlFactor(address _indexToken) external view returns (uint256);
    function getAllocation(address _indexToken) external view returns (uint256);
    function getOpenInterest(address _indexToken, bool _isLong) external view returns (uint256);
    function getAverageEntryPrice(address _indexToken, bool _isLong) external view returns (uint256);
    function getFundingAccrued(address _indexToken) external view returns (int256);
    function getCumulativeBorrowFees(address _indexToken) external view returns (uint256, uint256);
    function getCumulativeBorrowFee(address _indexToken, bool _isLong) external view returns (uint256);
    function getLastFundingUpdate(address _indexToken) external view returns (uint48);
    function getLastBorrowingUpdate(address _indexToken) external view returns (uint48);
    function getFundingRates(address _indexToken) external view returns (int256, int256);
    function getBorrowingRate(address _indexToken, bool _isLong) external view returns (uint256);
    function getImpactPool(address _indexToken) external view returns (uint256);
}
