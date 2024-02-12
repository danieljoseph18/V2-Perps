// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

interface IMarket {
    struct Config {
        uint256 maxFundingVelocity;
        uint256 skewScale;
        int256 maxFundingRate;
        int256 minFundingRate;
        uint256 borrowingFactor;
        uint256 borrowingExponent;
        uint256 priceImpactFactor;
        uint256 priceImpactExponent;
        uint256 maxPnlFactor;
        uint256 targetPnlFactor;
        uint32 maxLeverage;
        bool feeForSmallerSide;
        bool adlFlaggedLong;
        bool adlFlaggedShort;
    }
    // Public state variables accessors

    function indexToken() external view returns (address);
    function maxFundingVelocity() external view returns (uint256);
    function skewScale() external view returns (uint256);
    function maxFundingRate() external view returns (int256);
    function minFundingRate() external view returns (int256);
    function borrowingFactor() external view returns (uint256);
    function borrowingExponent() external view returns (uint256);
    function feeForSmallerSide() external view returns (bool);
    function priceImpactExponent() external view returns (uint256);
    function priceImpactFactor() external view returns (uint256);
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
    function longTokenAllocation() external view returns (uint256);
    function shortTokenAllocation() external view returns (uint256);
    function longTotalWAEP() external view returns (uint256);
    function shortTotalWAEP() external view returns (uint256);
    function longSizeSumUSD() external view returns (uint256);
    function shortSizeSumUSD() external view returns (uint256);
    function maxPnlFactor() external view returns (uint256);
    function targetPnlFactor() external view returns (uint256);
    function adlFlaggedLong() external view returns (bool);
    function adlFlaggedShort() external view returns (bool);

    // Events
    event MarketInitialised(
        uint256 maxFundingVelocity,
        uint256 skewScale,
        int256 maxFundingRate,
        int256 minFundingRate,
        uint256 borrowingFactor,
        uint256 borrowingExponent,
        bool feeForSmallerSide,
        uint256 priceImpactFactor,
        uint256 priceImpactExponent,
        uint256 maxPnlFactor,
        uint256 targetPnlFactor
    );
    event MarketConfigUpdated(
        uint256 maxFundingVelocity,
        uint256 skewScale,
        int256 maxFundingRate,
        int256 minFundingRate,
        uint256 borrowingFactor,
        uint256 borrowingExponent,
        bool feeForSmallerSide,
        uint256 priceImpactFactor,
        uint256 priceImpactExponent,
        uint256 maxPnlFactor,
        uint256 targetPnlFactor
    );
    event FundingUpdated(
        int256 fundingRate,
        int256 fundingRateVelocity,
        uint256 longCumulativeFundingFees,
        uint256 shortCumulativeFundingFees
    );
    event BorrowingUpdated(bool isLong, uint256 rate);
    event TotalWAEPUpdated(uint256 longTotalWAEP, uint256 shortTotalWAEP);
    event OpenInterestUpdated(uint256 longOpenInterest, uint256 shortOpenInterest);
    event AllocationUpdated(address market, uint256 longTokenAllocation, uint256 shortTokenAllocation);
    event AdlStateUpdated(bool adlState);

    // Functions
    function initialise(Config memory _config) external;
    function updateConfig(Config memory _config) external;
    function updateAdlState(bool _isFlaggedForAdl, bool _isLong) external;
    function updateFundingRate() external;
    function updateBorrowingRate(uint256 _indexPrice, uint256 _longTokenPrice, uint256 _shortTokenPrice, bool _isLong)
        external;
    function updateTotalWAEP(uint256 _price, int256 _sizeDeltaUsd, bool _isLong) external;
    function updateOpenInterest(uint256 _indexTokenAmount, bool _isLong, bool _shouldAdd) external;
    function updateAllocation(uint256 _longTokenAllocation, uint256 _shortTokenAllocation) external;
    function getCumulativeFees()
        external
        view
        returns (
            uint256 _longCumulativeFundingFees,
            uint256 _shortCumulativeFundingFees,
            uint256 _longCumulativeBorrowFees,
            uint256 _shortCumulativeBorrowFees
        );
}
