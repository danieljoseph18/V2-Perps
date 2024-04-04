// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IMarket} from "./interfaces/IMarket.sol";
import {RoleValidation} from "../access/RoleValidation.sol";
import {Funding} from "../libraries/Funding.sol";
import {Borrowing} from "../libraries/Borrowing.sol";
import {ReentrancyGuard} from "@solmate/utils/ReentrancyGuard.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {mulDiv} from "@prb/math/Common.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IMarketToken, IERC20} from "./interfaces/IMarketToken.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IWETH} from "../tokens/interfaces/IWETH.sol";
import {MarketUtils} from "./MarketUtils.sol";
import {IPriceFeed} from "../oracle/interfaces/IPriceFeed.sol";
import {ITradeStorage} from "../positions/interfaces/ITradeStorage.sol";
import {IRewardTracker} from "../rewards/interfaces/IRewardTracker.sol";
import {IFeeDistributor} from "../rewards/interfaces/IFeeDistributor.sol";
import {MarketLogic} from "./MarketLogic.sol";

// @audit - optimize. Can probably remove some stuff
contract Market is IMarket, RoleValidation, ReentrancyGuard {
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using SignedMath for int256;
    using SafeERC20 for IERC20;
    using SafeERC20 for IMarketToken;

    IMarketToken public immutable MARKET_TOKEN;
    IRewardTracker public rewardTracker;
    IFeeDistributor public feeDistributor;

    address public tradeStorage;

    uint32 private constant MIN_LEVERAGE = 100; // Min 1x Leverage
    uint32 private constant MAX_LEVERAGE = 1000_00; // Max 1000x leverage
    uint64 private constant MIN_RESERVE_FACTOR = 0.1e18; // 10% reserve factor
    uint64 private constant MAX_RESERVE_FACTOR = 0.5e18; // 50% reserve factor
    uint64 private constant SCALING_FACTOR = 1e18;
    uint64 private constant MIN_BORROW_SCALE = 0.0001e18; // 0.01% per day
    uint64 private constant MAX_BORROW_SCALE = 0.01e18; // 1% per day
    uint64 public constant BASE_FEE = 0.001e18; // 0.1%
    int64 private constant MIN_VELOCITY = 0.001e18; // 0.1% per day
    int64 private constant MAX_VELOCITY = 0.2e18; // 20% per day
    int256 private constant MIN_SKEW_SCALE = 1000e30; // $1000
    int256 private constant MAX_SKEW_SCALE = 10_000_000_000e30; // $10 Bn
    int64 private constant SIGNED_SCALAR = 1e18;
    string private constant LONG_TICKER = "ETH";
    string private constant SHORT_TICKER = "USDC";
    /**
     * Level of pSkew beyond which funding rate starts to change
     * Units: % Per Day
     */
    uint64 public constant FUNDING_VELOCITY_CLAMP = 0.00001e18; // 0.001% per day
    /**
     * Maximum PNL:POOL ratio before ADL is triggered.
     */
    uint64 public constant MAX_PNL_FACTOR = 0.45e18; // 45%
    uint64 public constant MAX_ADL_PERCENTAGE = 0.5e18; // Can only ADL up to 50% of a position
    // Value = Max Bonus Fee
    // Users will be charged a % of this fee based on the skew of the market
    uint256 public constant FEE_SCALE = 0.01e18; // 1%

    // The rest of the 80% of the fees go to the FeeDistributor to distribute to LPs
    uint256 private constant FEES_TO_OWNER = 0.1e18; // 10% to Owner
    uint256 private constant FEES_TO_PROTOCOL = 0.1e18; // 10% to Protocol

    address private immutable WETH;
    address private immutable USDC;
    uint48 private constant TIME_TO_EXPIRATION = 1 minutes;
    uint256 private constant LONG_BASE_UNIT = 1e18;
    uint256 private constant SHORT_BASE_UNIT = 1e6;

    EnumerableSet.Bytes32Set private assetIds;
    bool private isInitialized;

    address private poolOwner;
    address private feeReceiver;

    uint256 private longAccumulatedFees;
    uint256 private shortAccumulatedFees;

    uint256 public longTokenBalance;
    uint256 public shortTokenBalance;
    uint256 public longTokensReserved;
    uint256 public shortTokensReserved;
    /**
     * Maximum borrowing fee per day as a percentage.
     * The current borrowing fee will fluctuate along this scale,
     * based on the open interest to max open interest ratio.
     */
    uint256 public borrowScale;

    string[] private tickers;

    // Store the Collateral Amount for each User
    mapping(address user => mapping(bool _isLong => uint256 collateralAmount)) public collateralAmounts;

    mapping(bytes32 key => Input request) private requests;
    EnumerableSet.Bytes32Set private requestKeys;

    // Each Asset's storage is tracked through this mapping
    mapping(bytes32 assetId => MarketStorage assetStorage) private marketStorage;

    modifier orderExists(bytes32 _key) {
        if (!requestKeys.contains(_key)) revert Market_InvalidKey();
        _;
    }

    /**
     *  ========================= Constructor  =========================
     */
    constructor(
        Config memory _config,
        address _poolOwner,
        address _feeReceiver,
        address _feeDistributor,
        address _weth,
        address _usdc,
        address _marketToken,
        string memory _ticker,
        address _roleStorage
    ) RoleValidation(_roleStorage) {
        WETH = _weth;
        USDC = _usdc;
        MARKET_TOKEN = IMarketToken(_marketToken);
        poolOwner = _poolOwner;
        feeDistributor = IFeeDistributor(_feeDistributor);
        feeReceiver = _feeReceiver;
        bytes32 assetId = MarketUtils.generateAssetId(_ticker);
        if (assetIds.contains(assetId)) revert Market_TokenAlreadyExists();
        if (!assetIds.add(assetId)) revert Market_FailedToAddAssetId();
        // Add Ticker
        tickers.push(_ticker);
        // Initialize Storage
        marketStorage[assetId].allocationPercentage = 1e18;
        marketStorage[assetId].config = _config;
        marketStorage[assetId].funding.lastFundingUpdate = uint48(block.timestamp);
        marketStorage[assetId].borrowing.lastBorrowUpdate = uint48(block.timestamp);
        emit TokenAdded(assetId);
    }

    // @audit - do we need this
    receive() external payable {
        if (msg.sender != WETH) revert Market_InvalidETHTransfer();
    }

    function initialize(address _tradeStorage, address _rewardTracker, uint256 _borrowScale)
        external
        onlyMarketFactory
    {
        if (isInitialized) revert Market_AlreadyInitialized();
        tradeStorage = _tradeStorage;
        rewardTracker = IRewardTracker(_rewardTracker);
        borrowScale = _borrowScale;
        isInitialized = true;
        emit Market_Initialzied();
    }
    /**
     * ========================= Setter Functions  =========================
     */

    function transferPoolOwnership(address _newOwner) external {
        if (msg.sender != poolOwner || _newOwner == address(0)) revert Market_InvalidPoolOwner();
        poolOwner = _newOwner;
    }

    function updateFeeDistributor(IFeeDistributor _feeDistributor) external onlyAdmin {
        if (address(_feeDistributor) == address(0)) revert Market_InvalidFeeDistributor();
        feeDistributor = _feeDistributor;
    }

    function updateBorrowScale(uint256 _borrowScale) external onlyConfigurator(address(this)) {
        if (_borrowScale < MIN_BORROW_SCALE || _borrowScale > MAX_BORROW_SCALE) revert Market_InvalidBorrowScale();
        borrowScale = _borrowScale;
    }

    function updateConfig(Config calldata _config, string calldata _ticker) external {
        MarketLogic.validateConfig(_config);
        bytes32 assetId = keccak256(abi.encode(_ticker));
        marketStorage[assetId].config = _config;
        emit MarketConfigUpdated(assetId);
    }

    // @audit - only self
    function setFunding(FundingValues calldata _funding, string calldata _ticker) external {
        if (msg.sender != address(this)) revert Market_InvalidCaller();
        bytes32 assetId = keccak256(abi.encode(_ticker));
        marketStorage[assetId].funding = _funding;
    }

    // @audit - only self
    function setBorrowing(BorrowingValues calldata _borrowing, string calldata _ticker) external {
        if (msg.sender != address(this)) revert Market_InvalidCaller();
        bytes32 assetId = keccak256(abi.encode(_ticker));
        marketStorage[assetId].borrowing = _borrowing;
    }

    function setWeightedAverages(
        uint256 _averageEntryPrice,
        uint256 _weightedAvgCumulative,
        string calldata _ticker,
        bool _isLong
    ) external {
        if (msg.sender != address(this)) revert Market_InvalidCaller();
        bytes32 assetId = keccak256(abi.encode(_ticker));
        if (_isLong) {
            marketStorage[assetId].pnl.longAverageEntryPriceUsd = _averageEntryPrice;
            marketStorage[assetId].borrowing.weightedAvgCumulativeLong = _weightedAvgCumulative;
        } else {
            marketStorage[assetId].pnl.shortAverageEntryPriceUsd = _averageEntryPrice;
            marketStorage[assetId].borrowing.weightedAvgCumulativeShort = _weightedAvgCumulative;
        }
    }

    function setAllocationPercentage(string calldata _ticker, uint256 _allocationPercentage) external {
        revert Market_SingleAssetMarket();
    }

    /**
     * ========================= Market State Functions  =========================
     */
    function updateMarketState(
        string calldata _ticker,
        uint256 _sizeDelta,
        uint256 _indexPrice,
        uint256 _impactedPrice,
        uint256 _collateralPrice,
        uint256 _indexBaseUnit,
        bool _isLong,
        bool _isIncrease
    ) external nonReentrant onlyTradeStorage(address(this)) {
        MarketLogic.updateMarketState(
            this,
            _ticker,
            _sizeDelta,
            _indexPrice,
            _impactedPrice,
            _collateralPrice,
            _indexBaseUnit,
            _isLong,
            _isIncrease
        );
    }

    // @audit - only market should be able to call
    function deleteRequest(bytes32 _key) external {
        if (msg.sender != address(this)) revert Market_InvalidCaller();
        if (!requestKeys.remove(_key)) revert Market_FailedToRemoveRequest();
        delete requests[_key];
    }

    // @audit - only market should be able to call
    function addRequest(Input calldata _request) external {
        if (msg.sender != address(this)) revert Market_InvalidCaller();
        if (!requestKeys.add(_request.key)) revert Market_FailedToAddRequest();
        requests[_request.key] = _request;
    }

    function addAsset(string calldata _ticker) external {
        revert Market_SingleAssetMarket();
    }

    function removeAsset(string calldata _ticker) external {
        revert Market_SingleAssetMarket();
    }

    function setConfig(string calldata _ticker, Config calldata _config) external {
        revert Market_SingleAssetMarket();
    }

    function setLastUpdate(string calldata _ticker) external {
        revert Market_SingleAssetMarket();
    }

    // @audit - only market should be able to call
    function updateOpenInterest(string calldata _ticker, uint256 _sizeDeltaUsd, bool _isLong, bool _shouldAdd)
        external
    {
        if (msg.sender != address(this)) revert Market_InvalidCaller();
        // Update the open interest
        bytes32 assetId = keccak256(abi.encode(_ticker));
        if (_shouldAdd) {
            _isLong
                ? marketStorage[assetId].openInterest.longOpenInterest += _sizeDeltaUsd
                : marketStorage[assetId].openInterest.shortOpenInterest += _sizeDeltaUsd;
        } else {
            _isLong
                ? marketStorage[assetId].openInterest.longOpenInterest -= _sizeDeltaUsd
                : marketStorage[assetId].openInterest.shortOpenInterest -= _sizeDeltaUsd;
        }
    }

    /**
     * ========================= Token Functions  =========================
     */
    function batchWithdrawFees() external onlyConfigurator(address(this)) nonReentrant {
        uint256 longFees = longAccumulatedFees;
        uint256 shortFees = shortAccumulatedFees;
        longAccumulatedFees = 0;
        shortAccumulatedFees = 0;
        MarketLogic.batchWithdrawFees(WETH, USDC, address(feeDistributor), feeReceiver, poolOwner, longFees, shortFees);
    }

    function transferOutTokens(address _to, uint256 _amount, bool _isLongToken, bool _shouldUnwrap)
        external
        onlyTradeStorage(address(this))
        nonReentrant
    {
        uint256 available =
            _isLongToken ? longTokenBalance - longTokensReserved : shortTokenBalance - shortTokensReserved;
        if (_amount > available) revert Market_InsufficientAvailableTokens();
        if (_isLongToken) {
            if (_shouldUnwrap) {
                IWETH(WETH).withdraw(_amount);
                (bool success,) = _to.call{value: _amount}("");
                if (!success) revert Market_FailedToTransferETH();
            } else {
                IERC20(WETH).safeTransfer(_to, _amount);
            }
        } else {
            IERC20(USDC).safeTransfer(_to, _amount);
        }
    }

    function accumulateFees(uint256 _amount, bool _isLong) external onlyTradeStorageOrMarket(address(this)) {
        _isLong ? longAccumulatedFees += _amount : shortAccumulatedFees += _amount;
        emit FeesAccumulated(_amount, _isLong);
    }

    function updateLiquidityReservation(uint256 _amount, bool _isLong, bool _isIncrease)
        external
        onlyTradeStorage(address(this))
    {
        if (_isIncrease) {
            _isLong ? longTokensReserved += _amount : shortTokensReserved += _amount;
        } else {
            if (_isLong) {
                if (_amount > longTokensReserved) longTokensReserved = 0;
                else longTokensReserved -= _amount;
            } else {
                if (_amount > shortTokensReserved) shortTokensReserved = 0;
                else shortTokensReserved -= _amount;
            }
        }
    }

    function updatePoolBalance(uint256 _amount, bool _isLong, bool _isIncrease)
        external
        onlyTradeStorageOrMarket(address(this))
    {
        if (_isIncrease) {
            _isLong ? longTokenBalance += _amount : shortTokenBalance += _amount;
        } else {
            _isLong ? longTokenBalance -= _amount : shortTokenBalance -= _amount;
        }
    }

    function updateCollateralAmount(uint256 _amount, address _user, bool _isLong, bool _isIncrease)
        external
        onlyTradeStorage(address(this))
    {
        if (_isIncrease) {
            collateralAmounts[_user][_isLong] += _amount;
        } else {
            if (_amount > collateralAmounts[_user][_isLong]) revert Market_InsufficientCollateral();
            else collateralAmounts[_user][_isLong] -= _amount;
        }
    }

    function updateImpactPool(string calldata _ticker, int256 _priceImpactUsd)
        external
        onlyTradeStorage(address(this))
    {
        bytes32 assetId = keccak256(abi.encode(_ticker));
        _priceImpactUsd > 0
            ? marketStorage[assetId].impactPool += _priceImpactUsd.abs()
            : marketStorage[assetId].impactPool -= _priceImpactUsd.abs();
    }

    function createRequest(
        address _owner,
        address _transferToken, // Token In for Deposits, Out for Withdrawals
        uint256 _amountIn,
        uint256 _executionFee,
        bytes32 _priceRequestId,
        bytes32 _pnlRequestId,
        bool _reverseWrap,
        bool _isDeposit
    ) external payable onlyRouter {
        MarketLogic.createRequest(
            this,
            _owner,
            _transferToken,
            _amountIn,
            _executionFee,
            _priceRequestId,
            _pnlRequestId,
            WETH,
            _reverseWrap,
            _isDeposit
        );
    }

    function cancelRequest(bytes32 _key, address _caller)
        external
        onlyPositionManager
        returns (address tokenOut, uint256 amountOut, bool shouldUnwrap)
    {
        return MarketLogic.cancelRequest(this, _key, _caller, WETH, USDC, address(MARKET_TOKEN));
    }

    function executeDeposit(ExecuteDeposit calldata _params)
        external
        onlyPositionManager
        orderExists(_params.key)
        nonReentrant
    {
        MarketLogic.executeDeposit(
            ITradeStorage(tradeStorage).priceFeed(), _params, _params.deposit.isLongToken ? WETH : USDC
        );
    }

    function executeWithdrawal(ExecuteWithdrawal calldata _params)
        external
        onlyPositionManager
        orderExists(_params.key)
        nonReentrant
    {
        if (_params.withdrawal.isLongToken) {
            MarketLogic.executeWithdrawal(
                ITradeStorage(tradeStorage).priceFeed(), _params, WETH, longTokenBalance, longTokensReserved
            );
        } else {
            MarketLogic.executeWithdrawal(
                ITradeStorage(tradeStorage).priceFeed(), _params, USDC, shortTokenBalance, shortTokensReserved
            );
        }
    }

    /**
     * ========================= Getter Functions  =========================
     */
    function getAssetIds() external view returns (bytes32[] memory) {
        return assetIds.values();
    }

    function isAssetInMarket(string calldata _ticker) external view returns (bool) {
        bytes32 assetId = keccak256(abi.encode(_ticker));
        return assetIds.contains(assetId);
    }

    function getAssetsInMarket() external view returns (uint256) {
        return assetIds.length();
    }

    function getStorage(string calldata _ticker) external view returns (MarketStorage memory) {
        bytes32 assetId = keccak256(abi.encode(_ticker));
        return marketStorage[assetId];
    }

    function getRequest(bytes32 _key) external view returns (Input memory) {
        return requests[_key];
    }

    function getRequestAtIndex(uint256 _index) external view returns (Input memory) {
        return requests[requestKeys.at(_index)];
    }

    function totalAvailableLiquidity(bool _isLong) external view returns (uint256 total) {
        total = _isLong ? longTokenBalance - longTokensReserved : shortTokenBalance - shortTokensReserved;
    }

    function getTickers() external view returns (string[] memory) {
        return tickers;
    }

    function requestExists(bytes32 _key) external view returns (bool) {
        return requestKeys.contains(_key);
    }

    function getState() external view returns (State memory) {
        return State({
            totalSupply: MARKET_TOKEN.totalSupply(),
            wethBalance: IERC20(WETH).balanceOf(address(this)),
            usdcBalance: IERC20(USDC).balanceOf(address(this))
        });
    }
}
