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
        uint256 impactPool;
        uint256 allocationPercentage;
    }

    struct FundingValues {
        uint48 lastFundingUpdate;
        int256 fundingRate;
        int256 fundingRateVelocity;
        // The value (in USD) of total market funding accumulated.
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
        uint32 maxLeverage; // 2 D.P -> 100 = 1x, 200 = 2x
        bool feeForSmallerSide;
        // 0.3e18 = 30%
        uint256 reserveFactor; // % of liquiditythat can't be allocated to positions
        // reserves should be higher for more volatile markets
        FundingConfig funding;
        BorrowingConfig borrowing;
        ImpactConfig impact;
        AdlConfig adl;
    }

    struct AdlConfig {
        uint256 maxPnlFactor;
        uint256 targetPnlFactor;
        bool flaggedLong;
        bool flaggedShort;
    }

    struct FundingConfig {
        int256 maxVelocity; // Max funding Velocity
        int256 skewScale; // Sensitivity to Market Skew
    }

    struct BorrowingConfig {
        uint256 factor;
        uint256 exponent;
    }

    // Used to scale price impact per market
    // Both values lower for less volatile markets
    struct ImpactConfig {
        int256 positiveSkewScalar;
        int256 positiveLiquidityScalar;
        int256 negativeSkewScalar;
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
