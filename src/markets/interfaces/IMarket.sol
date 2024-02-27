// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {IVault} from "../../liquidity/interfaces/IVault.sol";

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
        uint256 longCumulativeFundingFees;
        uint256 shortCumulativeFundingFees;
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
        uint256 longAverageEntryPrice;
        uint256 shortAverageEntryPrice;
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
        uint256 maxVelocity;
        int256 maxRate;
        int256 minRate;
        uint256 skewScale; // Sensitivity to Market Skew
    }

    struct BorrowingConfig {
        uint256 factor;
        uint256 exponent;
    }

    struct ImpactConfig {
        uint256 positiveFactor; // 0.01% per $50,000 = 0.0002e18
        uint256 negativeFactor;
        uint256 exponent;
    }

    /**
     * ================ Events ================
     */
    event TokenAdded(address indexed indexToken, Config config);
    event TokenRemoved(address indexed indexToken);
    event MarketConfigUpdated(address indexed indexToken, Config config);
    event AdlStateUpdated(address indexed indexToken, bool isFlaggedForAdl);
    event FundingUpdated(
        int256 fundingRate,
        int256 fundingRateVelocity,
        uint256 longCumulativeFundingFees,
        uint256 shortCumulativeFundingFees
    );
    event BorrowingRatesUpdated(address indexed indexToken, uint256 longBorrowingRate, uint256 shortBorrowingRate);
    event AverageEntryPriceUpdated(
        address indexed indexToken, uint256 longAverageEntryPrice, uint256 shortAverageEntryPrice
    );
    event OpenInterestUpdated(address indexed indexToken, uint256 longOpenInterest, uint256 shortOpenInterest);

    /**
     * ================ Functions ================
     */
    function addToken(Config memory _config, address _indexToken, uint256[] calldata _newAllocations) external;
    function removeToken(address _indexToken, uint256[] calldata _newAllocations) external;
    function updateConfig(Config memory _config, address _indexToken) external;
    function updateAdlState(address _indexToken, bool _isFlaggedForAdl, bool _isLong) external;
    function updateFundingRate(address _indexToken, uint256 _indexPrice, uint256 _indexBaseUnit) external;
    function updateBorrowingRate(
        address _indexToken,
        uint256 _indexPrice,
        uint256 _indexBaseUnit,
        uint256 _longTokenPrice,
        uint256 _longBaseUnit,
        uint256 _shortTokenPrice,
        uint256 _shortBaseUnit,
        bool _isLong
    ) external;
    function updateAverageEntryPrice(address _indexToken, uint256 _price, int256 _sizeDelta, bool _isLong) external;
    function updateOpenInterest(address _indexToken, uint256 _indexTokenAmount, bool _isLong, bool _shouldAdd)
        external;
    function updateImpactPool(address _indexToken, int256 _priceImpactUsd) external;

    function getCumulativeFees(address _indexToken)
        external
        view
        returns (
            uint256 _longCumulativeFundingFees,
            uint256 _shortCumulativeFundingFees,
            uint256 _longCumulativeBorrowFees,
            uint256 _shortCumulativeBorrowFees
        );

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
    function getCumulativeFundingFees(address _indexToken, bool _isLong) external view returns (uint256);
    function getCumulativeBorrowFees(address _indexToken, bool _isLong) external view returns (uint256);
    function getLastFundingUpdate(address _indexToken) external view returns (uint48);
    function getLastBorrowingUpdate(address _indexToken) external view returns (uint48);
    function getFundingRates(address _indexToken) external view returns (int256, int256);
    function getBorrowingRate(address _indexToken, bool _isLong) external view returns (uint256);
    function getImpactPool(address _indexToken) external view returns (uint256);
}
