// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IMarket} from "./interfaces/IMarket.sol";
import {RoleValidation} from "../access/RoleValidation.sol";
import {Funding} from "../libraries/Funding.sol";
import {Borrowing} from "../libraries/Borrowing.sol";
import {ReentrancyGuard} from "../utils/ReentrancyGuard.sol";
import {SignedMath} from "../libraries/SignedMath.sol";
import {EnumerableSet} from "../libraries/EnumerableSet.sol";
import {EnumerableMap} from "../libraries/EnumerableMap.sol";
import {IVault, IERC20} from "./interfaces/IVault.sol";
import {SafeTransferLib} from "../libraries/SafeTransferLib.sol";
import {IWETH} from "../tokens/interfaces/IWETH.sol";
import {MarketUtils} from "./MarketUtils.sol";
import {IPriceFeed} from "../oracle/interfaces/IPriceFeed.sol";
import {ITradeStorage} from "../positions/interfaces/ITradeStorage.sol";
import {IRewardTracker} from "../rewards/interfaces/IRewardTracker.sol";
import {IFeeDistributor} from "../rewards/interfaces/IFeeDistributor.sol";
import {MarketLogic} from "./MarketLogic.sol";
import {Pool} from "./Pool.sol";

/// @dev - Vault can support the trading of multiple assets under the same liquidity.
contract Market is IMarket, RoleValidation, ReentrancyGuard {
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using EnumerableMap for EnumerableMap.MarketRequestMap;
    using SignedMath for int256;
    using SafeTransferLib for IERC20;
    using SafeTransferLib for IVault;

    uint64 private constant MIN_BORROW_SCALE = 0.0001e18; // 0.01% per day
    uint64 private constant MAX_BORROW_SCALE = 0.01e18; // 1% per day
    /**
     * Level of pSkew beyond which funding rate starts to change
     * Units: % Per Day
     */
    uint64 public constant FUNDING_VELOCITY_CLAMP = 0.00001e18; // 0.001% per day

    IVault public immutable VAULT;
    address private immutable WETH;
    address private immutable USDC;
    bool private immutable IS_MULTI_ASSET;

    /* 0. Address of the Reward Tracker contract for the Market. */
    IRewardTracker public rewardTracker;
    /* 1. Address of the Fee Distributor contract for the Market. */
    IFeeDistributor feeDistributor;
    /* 2. Address of the TradeStorage contract for the Market.*/
    address public tradeStorage;
    bool isInitialized;
    /* 3. Address of the Pool Owner / Configurator. */
    address poolOwner;
    /* 4. Address for the protocol to receive 10% of fees to */
    address feeReceiver;
    /* 5. Accumulated fees from long positions */
    uint256 public longAccumulatedFees;
    /* 6. Accumulated fees from short positions */
    uint256 public shortAccumulatedFees;
    /* 7. Total long token balance */
    uint256 public longTokenBalance;
    /* 8. Total short token balance */
    uint256 public shortTokenBalance;
    /* 9. Long tokens reserved for liquidity */
    uint256 public longTokensReserved;
    /* 10. Short tokens reserved for liquidity */
    uint256 public shortTokensReserved;
    /**
     * 11. Maximum borrowing fee per day as a percentage.
     * The current borrowing fee will fluctuate along this scale,
     * based on the open interest to max open interest ratio.
     */
    uint256 public borrowScale;

    string[] private tickers;

    EnumerableSet.Bytes32Set private assetIds;
    EnumerableMap.MarketRequestMap private requests;

    // Each Asset's storage is tracked through this mapping
    mapping(bytes32 assetId => Pool.Storage assetStorage) private marketStorage;

    modifier orderExists(bytes32 _key) {
        _orderExists(_key);
        _;
    }

    /**
     *  ========================= Constructor  =========================
     */
    constructor(
        Pool.Config memory _config,
        address _poolOwner,
        address _feeReceiver,
        address _feeDistributor,
        address _weth,
        address _usdc,
        address _marketToken,
        string memory _ticker,
        bool _isMultiAsset,
        address _roleStorage
    ) RoleValidation(_roleStorage) {
        WETH = _weth;
        USDC = _usdc;
        VAULT = IVault(_marketToken);
        IS_MULTI_ASSET = _isMultiAsset;
        poolOwner = _poolOwner;
        feeDistributor = IFeeDistributor(_feeDistributor);
        feeReceiver = _feeReceiver;
        bytes32 assetId = MarketUtils.generateAssetId(_ticker);
        if (assetIds.contains(assetId)) revert Market_TokenAlreadyExists();
        if (!assetIds.add(assetId)) revert Market_FailedToAddAssetId();
        // Add Ticker
        tickers.push(_ticker);
        // Initialize Storage
        Pool.initialize(marketStorage[assetId], _config);
        emit TokenAdded(assetId);
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
        emit Market_Initialized();
    }
    /**
     * ========================= Setter Functions  =========================
     */

    function addToken(
        Pool.Config calldata _config,
        string memory _ticker,
        bytes calldata _newAllocations,
        bytes32 _priceRequestKey
    ) external onlyConfigurator(address(this)) nonReentrant {
        MarketLogic.validateConfig(_config);
        MarketLogic.addToken(
            ITradeStorage(tradeStorage).priceFeed(),
            marketStorage[keccak256(abi.encode(_ticker))],
            _config,
            _ticker,
            _newAllocations,
            _priceRequestKey
        );
    }

    function removeToken(string memory _ticker, bytes calldata _newAllocations, bytes32 _priceRequestKey)
        external
        onlyConfigurator(address(this))
        nonReentrant
    {
        MarketLogic.removeToken(ITradeStorage(tradeStorage).priceFeed(), _ticker, _newAllocations, _priceRequestKey);
    }

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

    function updateConfig(Pool.Config calldata _config, string calldata _ticker) external {
        MarketLogic.validateConfig(_config);
        bytes32 assetId = keccak256(abi.encode(_ticker));
        marketStorage[assetId].config = _config;
        emit MarketConfigUpdated(assetId);
    }

    /**
     * ========================= User Interaction Functions  =========================
     */
    function createRequest(
        address _owner,
        address _transferToken, // Token In for Deposits, Out for Withdrawals
        uint256 _amountIn,
        uint256 _executionFee,
        bytes32 _priceRequestKey,
        bytes32 _pnlRequestKey,
        bool _reverseWrap,
        bool _isDeposit
    ) external payable onlyRouter {
        MarketLogic.createRequest(
            requests,
            _owner,
            _transferToken,
            _amountIn,
            _executionFee,
            _priceRequestKey,
            _pnlRequestKey,
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
        return MarketLogic.cancelRequest(requests, _key, _caller, WETH, USDC, address(VAULT));
    }

    /**
     * ========================= Vault Actions
     */
    function executeDeposit(IVault.ExecuteDeposit calldata _params)
        external
        onlyPositionManager
        orderExists(_params.key)
        nonReentrant
    {
        // Delete Deposit Request
        if (!requests.remove(_params.key)) revert Market_FailedToRemoveRequest();
        // Execute the Deposit
        VAULT.executeDeposit(_params, _params.deposit.isLongToken ? WETH : USDC, msg.sender);
    }

    function executeWithdrawal(IVault.ExecuteWithdrawal calldata _params)
        external
        onlyPositionManager
        orderExists(_params.key)
        nonReentrant
    {
        // Delete the Withdrawal from Storage
        if (!requests.remove(_params.key)) revert Market_FailedToRemoveRequest();
        // Execute the withdrawal
        VAULT.executeWithdrawal(_params, _params.withdrawal.isLongToken ? WETH : USDC, msg.sender);
    }

    /**
     * ========================= Callback Functions  =========================
     */
    function setAllocationShare(string calldata _ticker, uint8 _allocationShare) external onlyCallback {
        if (!IS_MULTI_ASSET) revert Market_SingleAssetMarket();
        bytes32 assetId = keccak256(abi.encode(_ticker));
        marketStorage[assetId].allocationShare = _allocationShare;
    }

    function addAsset(string calldata _ticker) external onlyCallback {
        if (!IS_MULTI_ASSET) revert Market_SingleAssetMarket();
        bytes32 assetId = keccak256(abi.encode(_ticker));
        if (!assetIds.add(assetId)) revert Market_FailedToAddAssetId();
        tickers.push(_ticker);
        emit TokenAdded(assetId);
    }

    function removeAsset(string calldata _ticker) external onlyCallback {
        if (!IS_MULTI_ASSET) revert Market_SingleAssetMarket();
        bytes32 assetId = keccak256(abi.encode(_ticker));
        if (!assetIds.remove(assetId)) revert Market_FailedToRemoveAssetId();
        // Remove ticker by swap / pop method
        uint16 len = uint16(tickers.length);
        for (uint16 i = 0; i < len;) {
            if (keccak256(abi.encode(tickers[i])) == assetId) {
                tickers[i] = tickers[len - 1];
                tickers.pop();
                break;
            }
            unchecked {
                ++i;
            }
        }
        // Remove storage
        delete marketStorage[assetId];
    }

    /**
     * ========================= External State Functions  =========================
     */
    /// @dev - Caller must've requested a price before calling this function
    function reallocate(bytes calldata _allocations, bytes32 _priceRequestKey)
        external
        onlyConfigurator(address(this))
        nonReentrant
    {
        MarketLogic.reallocate(ITradeStorage(tradeStorage).priceFeed(), _allocations, _priceRequestKey);
    }

    function updateMarketState(
        string calldata _ticker,
        uint256 _sizeDelta,
        uint256 _indexPrice,
        uint256 _impactedPrice,
        uint256 _collateralPrice,
        uint256 _collateralBaseUnit,
        bool _isLong,
        bool _isIncrease
    ) external nonReentrant onlyTradeStorage(address(this)) {
        Pool.Storage storage self = marketStorage[keccak256(abi.encode(_ticker))];
        Pool.updateState(
            self,
            _ticker,
            _sizeDelta,
            _indexPrice,
            _impactedPrice,
            _collateralPrice,
            _collateralBaseUnit,
            _isLong,
            _isIncrease
        );
    }

    function updateImpactPool(string calldata _ticker, int256 _priceImpactUsd)
        external
        onlyTradeStorage(address(this))
    {
        bytes32 assetId = keccak256(abi.encode(_ticker));
        Pool.updateImpactPool(marketStorage[assetId], _priceImpactUsd);
    }

    /**
     * ========================= Private Functions  =========================
     */
    function _orderExists(bytes32 _key) private view {
        if (!requests.contains(_key)) revert Market_InvalidKey();
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

    function getStorage(string calldata _ticker) external view returns (Pool.Storage memory) {
        bytes32 assetId = keccak256(abi.encode(_ticker));
        return marketStorage[assetId];
    }

    function getConfig(string calldata _ticker) external view returns (Pool.Config memory) {
        bytes32 assetId = keccak256(abi.encode(_ticker));
        return marketStorage[assetId].config;
    }

    function getCumulatives(string calldata _ticker) external view returns (Pool.Cumulatives memory) {
        bytes32 assetId = keccak256(abi.encode(_ticker));
        return marketStorage[assetId].cumulatives;
    }

    function getImpactPool(string calldata _ticker) external view returns (uint256) {
        bytes32 assetId = keccak256(abi.encode(_ticker));
        return marketStorage[assetId].impactPool;
    }

    function getAllocationShare(string calldata _ticker) external view returns (uint8) {
        bytes32 assetId = keccak256(abi.encode(_ticker));
        return marketStorage[assetId].allocationShare;
    }

    function getRequest(bytes32 _key) external view returns (Input memory) {
        return requests.get(_key);
    }

    function getRequestAtIndex(uint256 _index) external view returns (Input memory request) {
        (, request) = requests.at(_index);
    }

    function totalAvailableLiquidity(bool _isLong) external view returns (uint256 total) {
        total = _isLong ? longTokenBalance - longTokensReserved : shortTokenBalance - shortTokensReserved;
    }

    function getTickers() external view returns (string[] memory) {
        return tickers;
    }

    function requestExists(bytes32 _key) external view returns (bool) {
        return requests.contains(_key);
    }

    function getImpactValues(string calldata _ticker) external view returns (int16, int16, int16, int16) {
        bytes32 assetId = keccak256(abi.encode(_ticker));
        return (
            marketStorage[assetId].config.positiveSkewScalar,
            marketStorage[assetId].config.negativeSkewScalar,
            marketStorage[assetId].config.positiveLiquidityScalar,
            marketStorage[assetId].config.negativeLiquidityScalar
        );
    }

    function getOpenInterestValues(string calldata _ticker) external view returns (uint256, uint256) {
        bytes32 assetId = keccak256(abi.encode(_ticker));
        return (marketStorage[assetId].longOpenInterest, marketStorage[assetId].shortOpenInterest);
    }
}
