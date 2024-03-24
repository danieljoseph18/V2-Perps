// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IMarket} from "./IMarket.sol";
import {Oracle} from "../../oracle/Oracle.sol";
import {IMarketToken} from "./IMarketToken.sol";

interface IMarket {
    /**
     * ================ Structs ================
     */
    struct VaultConfig {
        address longToken;
        address shortToken;
        uint64 longBaseUnit;
        uint64 shortBaseUnit;
        uint64 feeScale;
        uint64 feePercentageToOwner;
        uint48 minTimeToExpiration;
        address poolOwner;
        address feeDistributor;
        string name;
        string symbol;
    }

    // For snapshotting state for invariant checks
    struct State {
        uint256 totalSupply;
        uint256 wethBalance;
        uint256 usdcBalance;
    }

    struct Input {
        uint256 amountIn;
        uint256 executionFee;
        address owner;
        uint48 expirationTimestamp;
        bool isLongToken;
        bool reverseWrap;
        bool isDeposit;
        uint256 blockNumber;
        bytes32 key;
    }

    struct ExecuteDeposit {
        IMarket market;
        Input deposit;
        Oracle.Price longPrices;
        Oracle.Price shortPrices;
        bytes32 key;
        uint256 longBorrowFeesUsd;
        uint256 shortBorrowFeesUsd;
        int256 cumulativePnl;
    }

    struct ExecuteWithdrawal {
        IMarket market;
        Input withdrawal;
        Oracle.Price longPrices;
        Oracle.Price shortPrices;
        bytes32 key;
        uint256 longBorrowFeesUsd;
        uint256 shortBorrowFeesUsd;
        int256 cumulativePnl;
        uint256 amountOut;
        bool shouldUnwrap;
    }

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
        uint256 weightedAvgCumulativeLong;
        uint256 shortBorrowingRate;
        uint256 shortCumulativeBorrowFees;
        uint256 weightedAvgCumulativeShort;
    }

    struct OpenInterestValues {
        uint256 longOpenInterest;
        uint256 shortOpenInterest;
    }

    struct PnlValues {
        uint256 longAverageEntryPriceUsd;
        uint256 shortAverageEntryPriceUsd;
    }

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
    error Market_InvalidKey();
    error Market_InvalidPoolOwner();
    error Market_InvalidFeeDistributor();
    error Market_InvalidFeeScale();
    error Market_InvalidFeePercentage();
    error Market_InsufficientAvailableTokens();
    error Market_InvalidUnwrapToken();
    error Market_FailedToAddRequest();
    error Market_FailedToRemoveRequest();
    error Market_InsufficientLongBalance();
    error Market_InsufficientShortBalance();
    error Market_InsufficientCollateral();
    error Market_InvalidAmountOut(uint256 actualOut, uint256 expectedOut);
    error Market_TokenAlreadyExists();
    error Market_TokenDoesNotExist();
    error Market_PriceIsZero();
    error Market_InvalidCumulativeAllocation();
    error Market_FailedToAddAssetId();
    error Market_FailedToRemoveAssetId();
    error Market_AlreadyInitialized();
    error Market_MaxAssetsReached();

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
    event Market_Initialzied();
    event RequestCreated(
        bytes32 indexed key,
        address indexed owner,
        address indexed tokenIn,
        uint256 amountIn,
        uint256 blockNumber,
        bool isDeposit
    );
    event DepositRequestCancelled(
        bytes32 indexed key, address indexed owner, address indexed tokenIn, uint256 amountIn
    );
    event DepositExecuted(
        bytes32 indexed key, address indexed owner, address indexed tokenIn, uint256 amountIn, uint256 mintAmount
    );
    event WithdrawalRequestCancelled(
        bytes32 indexed key, address indexed owner, address indexed tokenOut, uint256 marketTokenAmountIn
    );
    event WithdrawalExecuted(
        bytes32 indexed key,
        address indexed owner,
        address indexed tokenOut,
        uint256 marketTokenAmountIn,
        uint256 amountOut
    );
    event ProfitTransferred(address indexed user, uint256 amount, bool isLong);
    event LiquidityReserved(address indexed user, uint256 amount, bool isIncrease, bool isLong);
    event FeesAccumulated(uint256 amount, bool _isLong);
    event TransferOutTokens(address _market, address indexed _to, uint256 _collateralDelta, bool _isLong);
    event PositionCollateralLiquidated(
        address indexed _liquidator, uint256 indexed _liqFee, address _market, uint256 _totalCollateral, bool _isLong
    );
    event FeesWithdrawn(uint256 _longFees, uint256 _shortFees);
    event TransferInCollateral(address indexed _market, uint256 indexed _collateralDelta, bool _isLong);
    event MarketAdded(address indexed _market);

    // Admin functions

    function updateFees(address _poolOwner, address _feeDistributor, uint256 _feeScale, uint256 _feePercentageToOwner)
        external;

    // Trading related functions
    function reserveLiquidity(uint256 _amount, bool _isLong) external;
    function unreserveLiquidity(uint256 _amount, bool _isLong) external;
    function accumulateFees(uint256 _amount, bool _isLong) external;
    function decreasePoolBalance(uint256 _amount, bool _isLong) external;
    function increasePoolBalance(uint256 _amount, bool _isLong) external;
    function transferOutTokens(address _to, uint256 _amount, bool _isLongToken, bool _shouldUnwrap) external;
    function updateCollateralAmount(uint256 _amount, address _user, bool _isLong, bool _isIncrease) external;

    // Deposit execution
    function executeDeposit(ExecuteDeposit memory _params) external;

    // Withdrawal execution
    function executeWithdrawal(ExecuteWithdrawal memory _params) external;

    function createRequest(
        address _owner,
        address _tokenIn,
        uint256 _amountIn,
        uint256 _executionFee,
        bool _reverseWrap,
        bool _isDeposit
    ) external payable;

    function deleteRequest(bytes32 _key) external;
    function withdrawMarketTokensToTokens(
        Oracle.Price memory _longPrices,
        Oracle.Price memory _shortPrices,
        uint256 _marketTokenAmountIn,
        uint256 _longBorrowFeesUsd,
        uint256 _shortBorrowFeesUsd,
        int256 _cumulativePnl,
        bool _isLongToken
    ) external view returns (uint256 tokenAmount);

    // Getter
    function feeScale() external view returns (uint256);
    function BASE_FEE() external view returns (uint64);
    function totalAvailableLiquidity(bool _isLong) external view returns (uint256 total);
    function getRequest(bytes32 _key) external view returns (Input memory);
    function getRequestAtIndex(uint256 _index) external view returns (Input memory);

    /**
     * ================ Functions ================
     */
    function initialize(address _tradeStorage) external;
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
    function updateWeightedAverages(bytes32 _assetId, uint256 _priceUsd, int256 _sizeDeltaUsd, bool _isLong) external;
    function updateOpenInterest(bytes32 _assetId, uint256 _sizeDeltaUsd, bool _isLong, bool _shouldAdd) external;
    function updateImpactPool(bytes32 _assetId, int256 _priceImpactUsd) external;
    function setAllocationsWithBits(uint256[] memory _allocations) external;

    function tradeStorage() external view returns (address);
    function MARKET_TOKEN() external view returns (IMarketToken);
    function getAssetIds() external view returns (bytes32[] memory);
    function getAssetsInMarket() external view returns (uint256);
    function getStorage(bytes32 _assetId) external view returns (MarketStorage memory);
}
