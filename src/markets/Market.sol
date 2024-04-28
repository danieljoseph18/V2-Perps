// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IMarket} from "./interfaces/IMarket.sol";
import {OwnableRoles} from "../auth/OwnableRoles.sol";
import {ReentrancyGuard} from "../utils/ReentrancyGuard.sol";
import {EnumerableSetLib} from "../libraries/EnumerableSetLib.sol";
import {EnumerableMap} from "../libraries/EnumerableMap.sol";
import {IVault, IERC20} from "./interfaces/IVault.sol";
import {MarketUtils} from "./MarketUtils.sol";
import {Casting} from "../libraries/Casting.sol";
import {IPriceFeed} from "../oracle/interfaces/IPriceFeed.sol";
import {ITradeStorage} from "../positions/interfaces/ITradeStorage.sol";
import {Pool} from "./Pool.sol";
import {Oracle} from "../oracle/Oracle.sol";

/// @dev - Vault can support the trading of multiple assets under the same liquidity.
contract Market is IMarket, OwnableRoles, ReentrancyGuard {
    using EnumerableSetLib for EnumerableSetLib.Bytes32Set;
    using EnumerableMap for EnumerableMap.MarketRequestMap;
    using Casting for int256;

    uint64 private constant MIN_BORROW_SCALE = 0.0001e18; // 0.01% per day
    uint64 private constant MAX_BORROW_SCALE = 0.01e18; // 1% per day
    uint8 private constant MAX_ASSETS = 100;
    uint8 private constant TOTAL_ALLOCATION = 100;
    uint48 private constant TIME_TO_EXPIRATION = 1 minutes;
    /**
     * Level of pSkew beyond which funding rate starts to change
     * Units: % Per Day
     */
    uint64 public constant FUNDING_VELOCITY_CLAMP = 0.00001e18; // 0.001% per day
    string private constant LONG_TICKER = "ETH";
    string private constant SHORT_TICKER = "USDC";

    IVault public immutable VAULT;
    address private immutable WETH;
    address private immutable USDC;
    bool private immutable IS_MULTI_ASSET;

    address public tradeStorage;
    bool isInitialized;
    address poolOwner;

    /**
     * 11. Maximum borrowing fee per day as a percentage.
     * The current borrowing fee will fluctuate along this scale,
     * based on the open interest to max open interest ratio.
     */
    uint256 public borrowScale;

    string[] private tickers;

    EnumerableSetLib.Bytes32Set private assetIds;
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
        address _weth,
        address _usdc,
        address _marketToken,
        string memory _ticker,
        bool _isMultiAsset
    ) {
        _initializeOwner(msg.sender);
        WETH = _weth;
        USDC = _usdc;
        VAULT = IVault(_marketToken);
        IS_MULTI_ASSET = _isMultiAsset;
        poolOwner = _poolOwner;
        bytes32 assetId = MarketUtils.generateAssetId(_ticker);
        if (assetIds.contains(assetId)) revert Market_TokenAlreadyExists();
        if (!assetIds.add(assetId)) revert Market_FailedToAddAssetId();
        // Add Ticker
        tickers.push(_ticker);
        // Initialize Storage
        Pool.initialize(marketStorage[assetId], _config);
        emit TokenAdded(assetId);
    }

    function initialize(address _tradeStorage, uint256 _borrowScale) external onlyOwner {
        if (isInitialized) revert Market_AlreadyInitialized();
        tradeStorage = _tradeStorage;
        borrowScale = _borrowScale;
        isInitialized = true;
        emit Market_Initialized();
    }
    /**
     * ========================= Admin Functions  =========================
     */

    function addToken(
        IPriceFeed priceFeed,
        Pool.Config calldata _config,
        string memory _ticker,
        bytes calldata _newAllocations,
        bytes32 _priceRequestKey
    ) external onlyRoles(_ROLE_2) nonReentrant {
        if (!IS_MULTI_ASSET) revert Market_SingleAssetMarket();
        if (assetIds.length() >= MAX_ASSETS) revert Market_MaxAssetsReached();
        bytes32 assetId = keccak256(abi.encode(_ticker));
        if (assetIds.contains(assetId)) revert Market_TokenAlreadyExists();

        Pool.validateConfig(_config);

        if (!assetIds.add(assetId)) revert Market_FailedToAddAssetId();
        tickers.push(_ticker);

        _reallocate(priceFeed, _newAllocations, _priceRequestKey);

        Pool.initialize(marketStorage[assetId], _config);
    }

    function removeToken(
        IPriceFeed priceFeed,
        string memory _ticker,
        bytes calldata _newAllocations,
        bytes32 _priceRequestKey
    ) external onlyRoles(_ROLE_2) nonReentrant {
        if (!IS_MULTI_ASSET) revert Market_SingleAssetMarket();
        bytes32 assetId = keccak256(abi.encode(_ticker));
        if (!assetIds.contains(assetId)) revert Market_TokenDoesNotExist();
        uint16 len = uint16(assetIds.length());
        if (len == 1) revert Market_MinimumAssetsReached();

        // Remove Asset
        if (!assetIds.remove(assetId)) revert Market_FailedToRemoveAssetId();
        // Remove ticker by swap / pop method
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

        // Reallocate
        _reallocate(priceFeed, _newAllocations, _priceRequestKey);
    }

    // @audit - need to update roles accordingly
    function transferPoolOwnership(address _newOwner) external {
        if (msg.sender != poolOwner || _newOwner == address(0)) revert Market_InvalidPoolOwner();
        poolOwner = _newOwner;
    }

    function updateConfig(Pool.Config calldata _config, uint256 _borrowScale, string calldata _ticker)
        external
        onlyRoles(_ROLE_2)
    {
        if (_borrowScale < MIN_BORROW_SCALE || _borrowScale > MAX_BORROW_SCALE) revert Market_InvalidBorrowScale();
        Pool.validateConfig(_config);
        borrowScale = _borrowScale;
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
    ) external payable onlyRoles(_ROLE_3) {
        Pool.Input memory request = Pool.createRequest(
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
        if (!requests.set(request.key, request)) revert Market_FailedToAddRequest();
        emit RequestCreated(request.key, _owner, _transferToken, _amountIn, _isDeposit);
    }

    function cancelRequest(bytes32 _key, address _caller)
        external
        onlyRoles(_ROLE_1)
        returns (address tokenOut, uint256 amountOut, bool shouldUnwrap)
    {
        // Check the Request Exists
        if (!requests.contains(_key)) revert Market_InvalidKey();
        // Check the caller owns the request
        Pool.Input memory request = requests.get(_key);
        if (request.owner != _caller) revert Market_NotRequestOwner();
        // Ensure the request has passed the expiration time
        if (request.requestTimestamp + TIME_TO_EXPIRATION > block.timestamp) revert Market_RequestNotExpired();
        // Delete the request
        if (!requests.remove(_key)) revert Market_FailedToRemoveRequest();
        // Set Token Out and Should Unwrap
        if (request.isDeposit) {
            // If is deposit, token out is the token in
            tokenOut = request.isLongToken ? WETH : USDC;
            shouldUnwrap = request.reverseWrap;
        } else {
            // If is withdrawal, token out is market tokens
            tokenOut = address(VAULT);
            shouldUnwrap = false;
        }
        amountOut = request.amountIn;
        // Fire event
        emit RequestCanceled(_key, _caller);
    }

    /**
     * ========================= Vault Actions =========================
     */
    function executeDeposit(IVault.ExecuteDeposit calldata _params)
        external
        onlyRoles(_ROLE_1)
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
        onlyRoles(_ROLE_1)
        orderExists(_params.key)
        nonReentrant
    {
        // Delete the Withdrawal from Storage
        if (!requests.remove(_params.key)) revert Market_FailedToRemoveRequest();
        // Execute the withdrawal
        VAULT.executeWithdrawal(_params, _params.withdrawal.isLongToken ? WETH : USDC, msg.sender);
    }

    /**
     * ========================= External State Functions  =========================
     */
    /// @dev - Caller must've requested a price before calling this function
    function reallocate(bytes calldata _allocations, bytes32 _priceRequestKey)
        external
        onlyRoles(_ROLE_2)
        nonReentrant
    {
        _reallocate(ITradeStorage(tradeStorage).priceFeed(), _allocations, _priceRequestKey);
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
    ) external nonReentrant onlyRoles(_ROLE_5) {
        bytes32 assetId = keccak256(abi.encode(_ticker));
        if (!assetIds.contains(assetId)) revert Market_TokenDoesNotExist();
        Pool.Storage storage self = marketStorage[assetId];
        Pool.updateState(
            this,
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

    function updateImpactPool(string calldata _ticker, int256 _priceImpactUsd) external onlyRoles(_ROLE_5) {
        bytes32 assetId = keccak256(abi.encode(_ticker));
        _priceImpactUsd > 0
            ? marketStorage[assetId].impactPool += _priceImpactUsd.abs()
            : marketStorage[assetId].impactPool -= _priceImpactUsd.abs();
    }

    /**
     * ========================= Private Functions  =========================
     */
    /// @dev - Caller must've requested a price before calling this function
    /// @dev - Price request needs to contain all tickers in the market + long / short tokens, or will revert
    function _reallocate(IPriceFeed priceFeed, bytes calldata _allocations, bytes32 _priceRequestKey) private {
        if (!IS_MULTI_ASSET) revert Market_SingleAssetMarket();
        // Validate the Price Request
        uint48 requestTimestamp = Oracle.getRequestTimestamp(priceFeed, _priceRequestKey);

        // Fetch token prices
        uint256 longTokenPrice = Oracle.getPrice(priceFeed, LONG_TICKER, requestTimestamp);
        uint256 shortTokenPrice = Oracle.getPrice(priceFeed, SHORT_TICKER, requestTimestamp);

        // Copy tickers to memory
        string[] memory assetTickers = tickers;
        if (_allocations.length != assetTickers.length) revert Market_AllocationLength();

        uint8 total = 0;

        // Iterate over each byte in allocations calldata
        for (uint16 i = 0; i < _allocations.length;) {
            uint8 allocationValue = uint8(_allocations[i]);
            // Update Storage
            bytes32 assetId = keccak256(abi.encode(assetTickers[i]));
            marketStorage[assetId].allocationShare = allocationValue;
            // Check the allocation value -> new max open interest must be > current open interest
            _validateOpenInterest(priceFeed, assetTickers[i], requestTimestamp, longTokenPrice, shortTokenPrice);
            // Increment total
            total += allocationValue;
            unchecked {
                ++i;
            }
        }

        if (total != TOTAL_ALLOCATION) revert Market_InvalidCumulativeAllocation();
    }

    function _validateOpenInterest(
        IPriceFeed priceFeed,
        string memory _ticker,
        uint48 _requestTimestamp,
        uint256 _longSignedPrice,
        uint256 _shortSignedPrice
    ) private view {
        // Get the index price and the index base unit
        uint256 indexPrice = Oracle.getPrice(priceFeed, _ticker, _requestTimestamp);
        uint256 indexBaseUnit = Oracle.getBaseUnit(priceFeed, _ticker);
        // Get the Long Max Oi
        uint256 longMaxOi =
            MarketUtils.getAvailableOiUsd(this, VAULT, _ticker, indexPrice, _longSignedPrice, indexBaseUnit, true);
        bytes32 assetId = keccak256(abi.encode(_ticker));
        // Get the Current oi
        if (longMaxOi < marketStorage[assetId].longOpenInterest) revert Market_InvalidAllocation();
        // Get the Short Max Oi
        uint256 shortMaxOi =
            MarketUtils.getAvailableOiUsd(this, VAULT, _ticker, indexPrice, _shortSignedPrice, indexBaseUnit, false);
        // Get the Current oi
        if (shortMaxOi < marketStorage[assetId].shortOpenInterest) revert Market_InvalidAllocation();
    }

    function _orderExists(bytes32 _key) private view {
        if (!requests.contains(_key)) revert Market_InvalidKey();
    }

    /**
     * ========================= Getter Functions  =========================
     */
    function getAssetIds() external view returns (bytes32[] memory) {
        return assetIds.values();
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

    function getRequest(bytes32 _key) external view returns (Pool.Input memory) {
        return requests.get(_key);
    }

    function getRequestAtIndex(uint256 _index) external view returns (Pool.Input memory request) {
        (, request) = requests.at(_index);
    }

    function getTickers() external view returns (string[] memory) {
        return tickers;
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
}
