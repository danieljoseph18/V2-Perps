// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IMarket} from "./IMarket.sol";
import {Oracle} from "../../oracle/Oracle.sol";
import {IPriceFeed} from "../../oracle/interfaces/IPriceFeed.sol";
import {IMarketToken} from "./IMarketToken.sol";
import {IRewardTracker} from "../../rewards/interfaces/IRewardTracker.sol";

interface IMarket {
    /**
     * ================ Structs ================
     */

    // For snapshotting state for invariant checks
    struct State {
        uint256 totalSupply;
        uint256 wethBalance;
        uint256 usdcBalance;
        uint256 accumulatedFees;
        uint256 poolBalance;
    }

    struct Input {
        uint256 amountIn;
        uint256 executionFee;
        address owner;
        uint48 expirationTimestamp;
        bool isLongToken;
        bool reverseWrap;
        bool isDeposit;
        bytes32 key;
        bytes32 priceRequestId; // Id of the price update request
        bytes32 pnlRequestId; // Id of the cumulative pnl request
    }

    struct ExecuteDeposit {
        IMarket market;
        IMarketToken marketToken;
        Input deposit;
        IPriceFeed.Price longPrices;
        IPriceFeed.Price shortPrices;
        bytes32 key;
        uint256 longBorrowFeesUsd;
        uint256 shortBorrowFeesUsd;
        int256 cumulativePnl;
    }

    struct ExecuteWithdrawal {
        IMarket market;
        IMarketToken marketToken;
        Input withdrawal;
        IPriceFeed.Price longPrices;
        IPriceFeed.Price shortPrices;
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
         * Number of shares allocated to each sub-market.
         * A market can contain multiple index tokens, each of which have
         * a percentage of liquidity allocated to them.
         * Units are in shares, where 100% = 10,000.
         * Cumulative allocations must total up to 10,000.
         */
        uint256 allocationShare;
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
         * Price Impact Config Values
         */
        ImpactConfig impact;
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
    }

    // Used to scale price impact per market
    // Both values lower for less volatile markets
    struct ImpactConfig {
        /**
         * Dampening factor for the effect of skew in positive price impact.
         * Value as a percentage, with 30 d.p of precision, as it deals with USD values.
         * 100% = 1e30
         */
        int256 positiveSkewScalar;
        /**
         * Dampening factor for the effect of skew in negative price impact.
         * Value as a percentage, with 30 d.p of precision, as it deals with USD values.
         * 100% = 1e30
         */
        int256 negativeSkewScalar;
        /**
         * Dampening factor for the effect of liquidity in positive price impact.
         * Value as a percentage, with 30 d.p of precision, as it deals with USD values.
         * 100% = 1e30
         */
        int256 positiveLiquidityScalar;
        /**
         * Dampening factor for the effect of liquidity in negative price impact.
         * Value as a percentage, with 30 d.p of precision, as it deals with USD values.
         * 100% = 1e30
         */
        int256 negativeLiquidityScalar;
    }

    /**
     * ================ Errors ================
     */
    error Market_InvalidKey();
    error Market_InvalidPoolOwner();
    error Market_InvalidFeeDistributor();
    error Market_InsufficientAvailableTokens();
    error Market_FailedToAddRequest();
    error Market_FailedToRemoveRequest();
    error Market_InsufficientCollateral();
    error Market_TokenAlreadyExists();
    error Market_FailedToAddAssetId();
    error Market_FailedToRemoveAssetId();
    error Market_AlreadyInitialized();
    error Market_FailedToTransferETH();
    error Market_InvalidETHTransfer();
    error Market_InvalidBorrowScale();
    error Market_InvalidCaller();
    error Market_SingleAssetMarket();

    /**
     * ================ Events ================
     */
    event TokenAdded(bytes32 indexed assetId);
    event MarketConfigUpdated(bytes32 indexed assetId);
    event Market_Initialzied();
    event FeesAccumulated(uint256 amount, bool _isLong);

    // Admin functions

    // Trading related functions
    function updateLiquidityReservation(uint256 _amount, bool _isLong, bool _isIncrease) external;
    function accumulateFees(uint256 _amount, bool _isLong) external;
    function updatePoolBalance(uint256 _amount, bool _isLong, bool _isIncrease) external;
    function transferOutTokens(address _to, uint256 _amount, bool _isLongToken, bool _shouldUnwrap) external;
    function updateCollateralAmount(uint256 _amount, address _user, bool _isLong, bool _isIncrease) external;

    // Deposit execution
    function executeDeposit(ExecuteDeposit memory _params) external;

    // Withdrawal execution
    function executeWithdrawal(ExecuteWithdrawal memory _params) external;

    function createRequest(
        address _owner,
        address _transferToken, // Token In for Deposits, Out for Withdrawals
        uint256 _amountIn,
        uint256 _executionFee,
        bytes32 _priceRequestId,
        bytes32 _pnlRequestId,
        bool _reverseWrap,
        bool _isDeposit
    ) external payable;

    function cancelRequest(bytes32 _key, address _caller)
        external
        returns (address tokenOut, uint256 amountOut, bool shouldUnwrap);

    // Getter
    function totalAvailableLiquidity(bool _isLong) external view returns (uint256 total);
    function getRequest(bytes32 _key) external view returns (Input memory);
    function getRequestAtIndex(uint256 _index) external view returns (Input memory);
    function rewardTracker() external view returns (IRewardTracker);

    /**
     * ================ Functions ================
     */
    function initialize(address _tradeStorage, address _rewardTracker, uint256 _borrowScale) external;
    function updateMarketState(
        string calldata _ticker,
        uint256 _sizeDelta,
        uint256 _indexPrice,
        uint256 _impactedPrice,
        uint256 _collateralPrice,
        uint256 _indexBaseUnit,
        bool _isLong,
        bool _isIncrease
    ) external;
    function updateImpactPool(string memory _ticker, int256 _priceImpactUsd) external;

    function tradeStorage() external view returns (address);
    function MARKET_TOKEN() external view returns (IMarketToken);
    function borrowScale() external view returns (uint256);
    function getAssetIds() external view returns (bytes32[] memory);
    function getAssetsInMarket() external view returns (uint256);
    function getStorage(string memory _ticker) external view returns (MarketStorage memory);
    function longTokenBalance() external view returns (uint256);
    function shortTokenBalance() external view returns (uint256);
    function longTokensReserved() external view returns (uint256);
    function shortTokensReserved() external view returns (uint256);
    function isAssetInMarket(string memory _ticker) external view returns (bool);
    function getTickers() external view returns (string[] memory);
    function FUNDING_VELOCITY_CLAMP() external view returns (uint64);
    function MAX_PNL_FACTOR() external view returns (uint64);
    function MAX_ADL_PERCENTAGE() external view returns (uint64);

    function deleteRequest(bytes32 _key) external;
    function addRequest(Input calldata _request) external;
    function requestExists(bytes32 _key) external view returns (bool);
    function setFunding(FundingValues calldata _funding, string calldata _ticker) external;
    function setBorrowing(BorrowingValues calldata _borrowing, string calldata _ticker) external;
    function setWeightedAverages(
        uint256 _averageEntryPrice,
        uint256 _weightedAvgCumulative,
        string calldata _ticker,
        bool _isLong
    ) external;
    function updateOpenInterest(string calldata _ticker, uint256 _sizeDeltaUsd, bool _isLong, bool _shouldAdd)
        external;
    function setAllocationShare(string calldata _ticker, uint256 _allocationShare) external;
    function addAsset(string calldata _ticker) external;
    function removeAsset(string calldata _ticker) external;
    function setConfig(string calldata _ticker, Config calldata _config) external;
    function setLastUpdate(string calldata _ticker) external;
    function getState(bool _isLong) external view returns (State memory);
}
