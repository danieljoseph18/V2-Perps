// SPDX-License-Identifier: MIT
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
    error Market_FailedToAddAssetId();
    error Market_FailedToRemoveAssetId();

    /**
     * ================ Events ================
     */
    event TokenAdded(bytes32 indexed assetId, Config config);
    event TokenRemoved(bytes32 indexed assetId);
    event MarketConfigUpdated(bytes32 indexed assetId, Config config);
    event AdlStateUpdated(bytes32 indexed assetId, bool isFlaggedForAdl);
    event FundingUpdated(int256 fundingRate, int256 fundingRateVelocity, int256 fundingAccruedUsd);
    event BorrowingRatesUpdated(bytes32 indexed assetId, uint256 longBorrowingRate, uint256 shortBorrowingRate);
    event AverageEntryPriceUpdated(
        bytes32 indexed assetId, uint256 longAverageEntryPriceUsd, uint256 shortAverageEntryPriceUsd
    );
    event OpenInterestUpdated(bytes32 indexed assetId, uint256 longOpenInterestUsd, uint256 shortOpenInterestUsd);

    /**
     * ================ Functions ================
     */
    function addToken(Config memory _config, bytes32 _assetId, uint256[] calldata _newAllocations) external;
    function removeToken(bytes32 _assetId, uint256[] calldata _newAllocations) external;
    function updateConfig(Config memory _config, bytes32 _assetId) external;
    function updateAdlState(bytes32 _assetId, bool _isFlaggedForAdl, bool _isLong) external;
    function updateFundingRate(bytes32 _assetId, uint256 _indexPrice) external;
    function updateBorrowingRate(
        bytes32 _assetId,
        uint256 _indexPrice,
        uint256 _indexBaseUnit,
        uint256 _collateralPrice,
        uint256 _collateralBaseUnit,
        bool _isLong
    ) external;
    function updateAverageEntryPrice(bytes32 _assetId, uint256 _priceUsd, int256 _sizeDeltaUsd, bool _isLong)
        external;
    function updateOpenInterest(bytes32 _assetId, uint256 _sizeDeltaUsd, bool _isLong, bool _shouldAdd) external;
    function updateImpactPool(bytes32 _assetId, int256 _priceImpactUsd) external;

    function getAssetIds() external view returns (bytes32[] memory);
    function getStorage(bytes32 _assetId) external view returns (MarketStorage memory);
    function getConfig(bytes32 _assetId) external view returns (Config memory);
    function getBorrowingConfig(bytes32 _assetId) external view returns (BorrowingConfig memory);
    function getFundingConfig(bytes32 _assetId) external view returns (FundingConfig memory);
    function getImpactConfig(bytes32 _assetId) external view returns (ImpactConfig memory);
    function getAdlConfig(bytes32 _assetId) external view returns (AdlConfig memory);
    function getReserveFactor(bytes32 _assetId) external view returns (uint256);
    function getMaxLeverage(bytes32 _assetId) external view returns (uint32);
    function getMaxPnlFactor(bytes32 _assetId) external view returns (uint256);
    function getAllocation(bytes32 _assetId) external view returns (uint256);
    function getOpenInterest(bytes32 _assetId, bool _isLong) external view returns (uint256);
    function getAverageEntryPrice(bytes32 _assetId, bool _isLong) external view returns (uint256);
    function getFundingAccrued(bytes32 _assetId) external view returns (int256);
    function getCumulativeBorrowFees(bytes32 _assetId) external view returns (uint256, uint256);
    function getCumulativeBorrowFee(bytes32 _assetId, bool _isLong) external view returns (uint256);
    function getLastFundingUpdate(bytes32 _assetId) external view returns (uint48);
    function getLastBorrowingUpdate(bytes32 _assetId) external view returns (uint48);
    function getFundingRates(bytes32 _assetId) external view returns (int256, int256);
    function getBorrowingRate(bytes32 _assetId, bool _isLong) external view returns (uint256);
    function getImpactPool(bytes32 _assetId) external view returns (uint256);
}
