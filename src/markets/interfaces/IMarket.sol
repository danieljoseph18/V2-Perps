// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

interface IMarket {
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

    // Public state variables accessors
    function indexToken() external view returns (address);
    function lastFundingUpdate() external view returns (uint48);
    function fundingRate() external view returns (int256);
    function fundingRateVelocity() external view returns (int256);
    function longCumulativeFundingFees() external view returns (uint256);
    function shortCumulativeFundingFees() external view returns (uint256);
    function lastBorrowUpdate() external view returns (uint48);
    function longBorrowingRate() external view returns (uint256);
    function longCumulativeBorrowFees() external view returns (uint256);
    function shortBorrowingRate() external view returns (uint256);
    function shortCumulativeBorrowFees() external view returns (uint256);
    function longOpenInterest() external view returns (uint256);
    function shortOpenInterest() external view returns (uint256);
    function percentageAllocation() external view returns (uint256);
    function longAverageEntryPrice() external view returns (uint256);
    function shortAverageEntryPrice() external view returns (uint256);
    function impactPoolUsd() external view returns (uint256);

    // Events
    event MarketInitialised(Config config);
    event MarketConfigUpdated(Config config);
    event FundingUpdated(
        int256 fundingRate,
        int256 fundingRateVelocity,
        uint256 longCumulativeFundingFees,
        uint256 shortCumulativeFundingFees
    );
    event BorrowingRatesUpdated(uint256 longBorrowingRate, uint256 shortBorrowingRate);
    event AverageEntryPriceUpdated(uint256 longAverageEntryPrice, uint256 shortAverageEntryPrice);
    event OpenInterestUpdated(uint256 longOpenInterest, uint256 shortOpenInterest);
    event AllocationUpdated(address market, uint256 percentageAllocation);
    event AdlStateUpdated(bool adlState);

    // Functions
    function initialise(Config memory _config) external;
    function updateConfig(Config memory _config) external;
    function updateAdlState(bool _isFlaggedForAdl, bool _isLong) external;
    function updateFundingRate(uint256 _indexPrice, uint256 _indexBaseUnit) external;
    function updateBorrowingRate(
        uint256 _indexPrice,
        uint256 _indexBaseUnit,
        uint256 _longTokenPrice,
        uint256 _longBaseUnit,
        uint256 _shortTokenPrice,
        uint256 _shortBaseUnit,
        bool _isLong
    ) external;
    function updateAverageEntryPrice(uint256 _price, int256 _sizeDelta, bool _isLong) external;
    function updateOpenInterest(uint256 _indexTokenAmount, bool _isLong, bool _shouldAdd) external;
    function updateImpactPool(int256 _priceImpactUsd) external;
    function updateAllocation(uint256 _percentageAllocation) external;
    function getCumulativeFees()
        external
        view
        returns (
            uint256 _longCumulativeFundingFees,
            uint256 _shortCumulativeFundingFees,
            uint256 _longCumulativeBorrowFees,
            uint256 _shortCumulativeBorrowFees
        );
    function getConfig() external view returns (Config memory);
    function getBorrowingConfig() external view returns (BorrowingConfig memory);
    function getFundingConfig() external view returns (FundingConfig memory);
    function getImpactConfig() external view returns (ImpactConfig memory);
    function getAdlConfig() external view returns (AdlConfig memory);
    function getReserveFactor() external view returns (uint256);
    function getMaxLeverage() external view returns (uint32);
    function getMaxPnlFactor() external view returns (uint256);
}
