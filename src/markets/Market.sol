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
import {MarketId, MarketIdLibrary} from "../types/MarketId.sol";
import {Execution} from "../positions/Execution.sol";

/// @dev - Vault can support the trading of multiple assets under the same liquidity.
contract Market is IMarket, OwnableRoles, ReentrancyGuard {
    using EnumerableSetLib for EnumerableSetLib.Bytes32Set;
    using EnumerableMap for EnumerableMap.MarketMap;
    using Casting for int256;

    uint64 private constant MIN_BORROW_SCALE = 0.0001e18; // 0.01% per day
    uint64 private constant MAX_BORROW_SCALE = 0.01e18; // 1% per day
    uint8 private constant MAX_ASSETS = 100;
    uint8 private constant TOTAL_ALLOCATION = 100;
    uint48 private constant TIME_TO_EXPIRATION = 1 minutes;

    /**
     * Level of proportional skew beyond which funding rate starts to change
     * Units: % Per Day
     */
    uint64 public constant FUNDING_VELOCITY_CLAMP = 0.00001e18; // 0.001% per day

    string private constant LONG_TICKER = "ETH";
    string private constant SHORT_TICKER = "USDC";
    bool private initialized;

    address private immutable WETH;
    address private immutable USDC;

    ITradeStorage public tradeStorage;
    IPriceFeed public priceFeed;

    // Each Asset's storage is tracked through this mapping
    mapping(MarketId => mapping(bytes32 assetId => Pool.Storage assetStorage)) private marketStorage;
    mapping(MarketId => Pool.GlobalState) private globalState;

    modifier orderExists(MarketId _id, bytes32 _key) {
        _orderExists(_id, _key);
        _;
    }

    modifier onlyPoolOwner(MarketId _id) {
        _isPoolOwner(_id);
        _;
    }

    /**
     *  =========================================== Constructor  ===========================================
     */
    constructor(address _weth, address _usdc) {
        _initializeOwner(msg.sender);
        WETH = _weth;
        USDC = _usdc;
    }

    function initialize(address _tradeStorage, address _priceFeed, address _marketFactory) external onlyOwner {
        if (initialized) revert Market_AlreadyInitialized();
        tradeStorage = ITradeStorage(_tradeStorage);
        priceFeed = IPriceFeed(_priceFeed);
        _grantRoles(_marketFactory, _ROLE_0);
        initialized = true;
    }

    // Only Market Factory
    function initializePool(
        MarketId _id,
        Pool.Config memory _config,
        address _poolOwner,
        uint256 _borrowScale,
        address _marketToken,
        string memory _ticker,
        bool _isMultiAsset
    ) external onlyRoles(_ROLE_0) {
        Pool.GlobalState storage state = globalState[_id];

        if (state.isInitialized) revert Market_AlreadyInitialized();

        bytes32 assetId = MarketUtils.generateAssetId(_ticker);
        if (state.assetIds.contains(assetId)) revert Market_TokenAlreadyExists();
        if (!state.assetIds.add(assetId)) revert Market_FailedToAddAssetId();
        state.tickers.push(_ticker);
        Pool.initialize(marketStorage[_id][assetId], _config);
        emit TokenAdded(assetId);

        state.isMultiAsset = _isMultiAsset;
        state.poolOwner = _poolOwner;
        state.vault = IVault(_marketToken);
        state.borrowScale = _borrowScale;

        state.isInitialized = true;

        emit Market_Initialized();
    }
    /**
     * =========================================== Admin Functions  ===========================================
     */

    function addToken(
        MarketId _id,
        Pool.Config calldata _config,
        string memory _ticker,
        bytes calldata _newAllocations,
        bytes32 _priceRequestKey
    ) external onlyPoolOwner(_id) {
        Pool.GlobalState storage state = globalState[_id];

        if (!state.isMultiAsset) revert Market_SingleAssetMarket();
        if (state.assetIds.length() >= MAX_ASSETS) revert Market_MaxAssetsReached();
        bytes32 assetId = keccak256(abi.encode(_ticker));
        if (state.assetIds.contains(assetId)) revert Market_TokenAlreadyExists();

        Pool.validateConfig(_config);

        if (!state.assetIds.add(assetId)) revert Market_FailedToAddAssetId();
        state.tickers.push(_ticker);

        _reallocate(_id, _newAllocations, _priceRequestKey);

        Pool.initialize(marketStorage[_id][assetId], _config);
    }

    function removeToken(MarketId _id, string memory _ticker, bytes calldata _newAllocations, bytes32 _priceRequestKey)
        external
        onlyPoolOwner(_id)
    {
        Pool.GlobalState storage state = globalState[_id];

        if (!state.isMultiAsset) revert Market_SingleAssetMarket();
        bytes32 assetId = keccak256(abi.encode(_ticker));
        if (!state.assetIds.contains(assetId)) revert Market_TokenDoesNotExist();
        uint16 len = uint16(state.assetIds.length());
        if (len == 1) revert Market_MinimumAssetsReached();

        if (marketStorage[_id][assetId].longOpenInterest + marketStorage[_id][assetId].shortOpenInterest > 0) {
            revert Market_FailedToRemoveAssetId();
        }

        if (!state.assetIds.remove(assetId)) revert Market_FailedToRemoveAssetId();

        // Remove ticker by swap / pop method
        for (uint16 i = 0; i < len;) {
            if (keccak256(abi.encode(state.tickers[i])) == assetId) {
                state.tickers[i] = state.tickers[len - 1];
                state.tickers.pop();
                break;
            }
            unchecked {
                ++i;
            }
        }

        delete marketStorage[_id][assetId];

        _reallocate(_id, _newAllocations, _priceRequestKey);
    }

    function transferPoolOwnership(MarketId _id, address _newOwner) external {
        Pool.GlobalState storage state = globalState[_id];

        if (msg.sender != state.poolOwner || _newOwner == address(0)) revert Market_InvalidPoolOwner();

        state.poolOwner = _newOwner;
    }

    function updateConfig(MarketId _id, Pool.Config calldata _config, uint256 _borrowScale, string calldata _ticker)
        external
        onlyPoolOwner(_id)
    {
        Pool.GlobalState storage state = globalState[_id];

        if (_borrowScale < MIN_BORROW_SCALE || _borrowScale > MAX_BORROW_SCALE) revert Market_InvalidBorrowScale();

        Pool.validateConfig(_config);

        state.borrowScale = _borrowScale;

        bytes32 assetId = keccak256(abi.encode(_ticker));

        marketStorage[_id][assetId].config = _config;

        emit MarketConfigUpdated(assetId);
    }

    /**
     * =========================================== User Interaction Functions  ===========================================
     */
    function createRequest(
        MarketId _id,
        address _owner,
        address _transferToken, // Token In for Deposits, Out for Withdrawals
        uint256 _amountIn,
        uint256 _executionFee,
        bytes32 _priceRequestKey,
        bytes32 _pnlRequestKey,
        uint40 _stakeDuration,
        bool _reverseWrap,
        bool _isDeposit
    ) external payable onlyRoles(_ROLE_3) {
        Pool.GlobalState storage state = globalState[_id];
        Pool.Input memory request = Pool.createRequest(
            _owner,
            _transferToken,
            _amountIn,
            _executionFee,
            _priceRequestKey,
            _pnlRequestKey,
            WETH,
            _stakeDuration,
            _reverseWrap,
            _isDeposit
        );
        if (!state.requests.set(request.key, request)) revert Market_FailedToAddRequest();
        emit RequestCreated(request.key, _owner, _transferToken, _amountIn, _isDeposit);
    }

    function cancelRequest(MarketId _id, bytes32 _requestKey, address _caller)
        external
        onlyRoles(_ROLE_1)
        returns (address tokenOut, uint256 amountOut, bool shouldUnwrap)
    {
        Pool.GlobalState storage state = globalState[_id];

        if (!state.requests.contains(_requestKey)) revert Market_InvalidKey();

        Pool.Input memory request = state.requests.get(_requestKey);
        if (request.owner != _caller) revert Market_NotRequestOwner();

        if (request.requestTimestamp + TIME_TO_EXPIRATION > block.timestamp) revert Market_RequestNotExpired();

        if (!state.requests.remove(_requestKey)) revert Market_FailedToRemoveRequest();

        if (request.isDeposit) {
            // If deposit, token out is the token in
            tokenOut = request.isLongToken ? WETH : USDC;
            shouldUnwrap = request.reverseWrap;
        } else {
            // If withdrawal, token out is market tokens
            tokenOut = address(state.vault);
            shouldUnwrap = false;
        }
        amountOut = request.amountIn;

        emit RequestCanceled(_requestKey, _caller);
    }

    /**
     * =========================================== Vault Actions ===========================================
     */
    function executeDeposit(MarketId _id, IVault.ExecuteDeposit calldata _params)
        external
        onlyRoles(_ROLE_1)
        orderExists(_id, _params.key)
        nonReentrant
        returns (uint256)
    {
        Pool.GlobalState storage state = globalState[_id];
        if (!state.requests.remove(_params.key)) revert Market_FailedToRemoveRequest();
        return state.vault.executeDeposit(_params, _params.deposit.isLongToken ? WETH : USDC, msg.sender);
    }

    function executeWithdrawal(MarketId _id, IVault.ExecuteWithdrawal calldata _params)
        external
        onlyRoles(_ROLE_1)
        orderExists(_id, _params.key)
        nonReentrant
    {
        Pool.GlobalState storage state = globalState[_id];
        if (!state.requests.remove(_params.key)) revert Market_FailedToRemoveRequest();
        state.vault.executeWithdrawal(_params, _params.withdrawal.isLongToken ? WETH : USDC, msg.sender);
    }

    /**
     * =========================================== External State Functions  ===========================================
     */
    /// @dev - Caller must've requested a price before calling this function
    function reallocate(MarketId _id, bytes calldata _allocations, bytes32 _priceRequestKey)
        external
        onlyPoolOwner(_id)
    {
        _reallocate(_id, _allocations, _priceRequestKey);
    }

    function updateMarketState(
        MarketId _id,
        string calldata _ticker,
        uint256 _sizeDelta,
        Execution.Prices memory _prices,
        bool _isLong,
        bool _isIncrease
    ) external nonReentrant onlyRoles(_ROLE_6) {
        Pool.GlobalState storage state = globalState[_id];

        bytes32 assetId = keccak256(abi.encode(_ticker));
        if (!state.assetIds.contains(assetId)) revert Market_TokenDoesNotExist();

        Pool.Storage storage self = marketStorage[_id][assetId];

        Pool.updateState(_id, this, self, _ticker, _sizeDelta, _prices, _isLong, _isIncrease);
    }

    function updateImpactPool(MarketId _id, string calldata _ticker, int256 _priceImpactUsd)
        external
        nonReentrant
        onlyRoles(_ROLE_6)
    {
        bytes32 assetId = keccak256(abi.encode(_ticker));
        _priceImpactUsd > 0
            ? marketStorage[_id][assetId].impactPool += _priceImpactUsd.abs()
            : marketStorage[_id][assetId].impactPool -= _priceImpactUsd.abs();
    }

    /**
     * =========================================== Private Functions  ===========================================
     */

    /// @dev - Price request needs to contain all tickers in the market + long / short tokens, or will revert
    function _reallocate(MarketId _id, bytes calldata _allocations, bytes32 _priceRequestKey) private {
        Pool.GlobalState storage state = globalState[_id];

        if (!state.isMultiAsset) revert Market_SingleAssetMarket();
        uint48 requestTimestamp = Oracle.getRequestTimestamp(priceFeed, _priceRequestKey);

        uint256 longTokenPrice = Oracle.getPrice(priceFeed, LONG_TICKER, requestTimestamp);
        uint256 shortTokenPrice = Oracle.getPrice(priceFeed, SHORT_TICKER, requestTimestamp);

        string[] memory assetTickers = state.tickers;
        if (_allocations.length != assetTickers.length) revert Market_AllocationLength();

        uint8 total = 0;

        // Iterate over each byte in allocations calldata
        for (uint16 i = 0; i < _allocations.length;) {
            uint8 allocationValue = uint8(_allocations[i]);

            bytes32 assetId = keccak256(abi.encode(assetTickers[i]));
            marketStorage[_id][assetId].allocationShare = allocationValue;

            // Check the updated allocation value: new max open interest must be > current open interest
            _validateOpenInterest(_id, state.vault, assetTickers[i], longTokenPrice, shortTokenPrice);

            total += allocationValue;

            unchecked {
                ++i;
            }
        }

        if (total != TOTAL_ALLOCATION) revert Market_InvalidCumulativeAllocation();
    }

    function _validateOpenInterest(
        MarketId _id,
        IVault vault,
        string memory _ticker,
        uint256 _longSignedPrice,
        uint256 _shortSignedPrice
    ) private view {
        uint256 indexBaseUnit = Oracle.getBaseUnit(priceFeed, _ticker);

        uint256 longMaxOi =
            MarketUtils.getMaxOpenInterest(_id, this, vault, _ticker, _longSignedPrice, indexBaseUnit, true);

        bytes32 assetId = keccak256(abi.encode(_ticker));

        if (longMaxOi < marketStorage[_id][assetId].longOpenInterest) revert Market_InvalidAllocation();

        uint256 shortMaxOi =
            MarketUtils.getMaxOpenInterest(_id, this, vault, _ticker, _shortSignedPrice, indexBaseUnit, false);

        if (shortMaxOi < marketStorage[_id][assetId].shortOpenInterest) revert Market_InvalidAllocation();
    }

    function _orderExists(MarketId _id, bytes32 _orderKey) private view {
        if (!globalState[_id].requests.contains(_orderKey)) revert Market_InvalidKey();
    }

    function _isPoolOwner(MarketId _id) internal view returns (bool) {
        return msg.sender == globalState[_id].poolOwner;
    }

    /**
     * =========================================== Getter Functions  ===========================================
     */
    function getVault(MarketId _id) external view returns (IVault) {
        return globalState[_id].vault;
    }

    function getBorrowScale(MarketId _id) external view returns (uint256) {
        return globalState[_id].borrowScale;
    }

    function getAssetIds(MarketId _id) external view returns (bytes32[] memory) {
        return globalState[_id].assetIds.values();
    }

    function getStorage(MarketId _id, string calldata _ticker) external view returns (Pool.Storage memory) {
        return marketStorage[_id][keccak256(abi.encode(_ticker))];
    }

    function getConfig(MarketId _id, string calldata _ticker) external view returns (Pool.Config memory) {
        return marketStorage[_id][keccak256(abi.encode(_ticker))].config;
    }

    function getCumulatives(MarketId _id, string calldata _ticker) external view returns (Pool.Cumulatives memory) {
        return marketStorage[_id][keccak256(abi.encode(_ticker))].cumulatives;
    }

    function getImpactPool(MarketId _id, string calldata _ticker) external view returns (uint256) {
        return marketStorage[_id][keccak256(abi.encode(_ticker))].impactPool;
    }

    function getRequest(MarketId _id, bytes32 _requestKey) external view returns (Pool.Input memory) {
        return globalState[_id].requests.get(_requestKey);
    }

    function getRequestAtIndex(MarketId _id, uint256 _index) external view returns (Pool.Input memory request) {
        (, request) = globalState[_id].requests.at(_index);
    }

    function getTickers(MarketId _id) external view returns (string[] memory) {
        return globalState[_id].tickers;
    }

    function getImpactValues(MarketId _id, string calldata _ticker) external view returns (int16, int16) {
        bytes32 assetId = keccak256(abi.encode(_ticker));
        return (
            marketStorage[_id][assetId].config.positiveLiquidityScalar,
            marketStorage[_id][assetId].config.negativeLiquidityScalar
        );
    }

    function getLastUpdate(MarketId _id, string calldata _ticker) external view returns (uint48) {
        return marketStorage[_id][keccak256(abi.encode(_ticker))].lastUpdate;
    }

    function getFundingRates(MarketId _id, string calldata _ticker) external view returns (int64, int64) {
        bytes32 assetId = keccak256(abi.encode(_ticker));
        return (marketStorage[_id][assetId].fundingRate, marketStorage[_id][assetId].fundingRateVelocity);
    }

    function getCumulativeBorrowFees(MarketId _id, string memory _ticker)
        external
        view
        returns (uint256 longCumulativeBorrowFees, uint256 shortCumulativeBorrowFees)
    {
        bytes32 assetId = keccak256(abi.encode(_ticker));
        return (
            marketStorage[_id][assetId].cumulatives.longCumulativeBorrowFees,
            marketStorage[_id][assetId].cumulatives.shortCumulativeBorrowFees
        );
    }

    function getCumulativeBorrowFee(MarketId _id, string memory _ticker, bool _isLong) public view returns (uint256) {
        return _isLong
            ? marketStorage[_id][keccak256(abi.encode(_ticker))].cumulatives.longCumulativeBorrowFees
            : marketStorage[_id][keccak256(abi.encode(_ticker))].cumulatives.shortCumulativeBorrowFees;
    }

    function getFundingAccrued(MarketId _id, string memory _ticker) external view returns (int256) {
        return marketStorage[_id][keccak256(abi.encode(_ticker))].fundingAccruedUsd;
    }

    function getBorrowingRate(MarketId _id, string memory _ticker, bool _isLong) external view returns (uint256) {
        return _isLong
            ? marketStorage[_id][keccak256(abi.encode(_ticker))].longBorrowingRate
            : marketStorage[_id][keccak256(abi.encode(_ticker))].shortBorrowingRate;
    }

    function getMaintenanceMargin(MarketId _id, string memory _ticker) external view returns (uint256) {
        return marketStorage[_id][keccak256(abi.encode(_ticker))].config.maintenanceMargin;
    }

    function getMaxLeverage(MarketId _id, string memory _ticker) external view returns (uint8) {
        return marketStorage[_id][keccak256(abi.encode(_ticker))].config.maxLeverage;
    }

    function getAllocation(MarketId _id, string memory _ticker) external view returns (uint8) {
        return marketStorage[_id][keccak256(abi.encode(_ticker))].allocationShare;
    }

    function getOpenInterest(MarketId _id, string memory _ticker, bool _isLong) external view returns (uint256) {
        return _isLong
            ? marketStorage[_id][keccak256(abi.encode(_ticker))].longOpenInterest
            : marketStorage[_id][keccak256(abi.encode(_ticker))].shortOpenInterest;
    }

    function getAverageCumulativeBorrowFee(MarketId _id, string memory _ticker, bool _isLong)
        external
        view
        returns (uint256)
    {
        return _isLong
            ? marketStorage[_id][keccak256(abi.encode(_ticker))].cumulatives.weightedAvgCumulativeLong
            : marketStorage[_id][keccak256(abi.encode(_ticker))].cumulatives.weightedAvgCumulativeShort;
    }
}
