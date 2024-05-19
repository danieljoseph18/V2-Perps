// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IMarketFactory} from "./interfaces/IMarketFactory.sol";
import {OwnableRoles} from "../auth/OwnableRoles.sol";
import {ReentrancyGuard} from "../utils/ReentrancyGuard.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {FeedRegistryInterface} from "@chainlink/contracts/src/v0.8/interfaces/FeedRegistryInterface.sol";
import {IUniswapV3Factory} from "../oracle/interfaces/IUniswapV3Factory.sol";
import {IUniswapV2Factory} from "../oracle/interfaces/IUniswapV2Factory.sol";
import {IVault} from "../markets/interfaces/IVault.sol";
import {ITradeStorage} from "../positions/interfaces/ITradeStorage.sol";
import {ITradeEngine} from "../positions/interfaces/ITradeEngine.sol";
import {IGlobalRewardTracker} from "../rewards/interfaces/IGlobalRewardTracker.sol";
import {EnumerableMap} from "../libraries/EnumerableMap.sol";
import {EnumerableSetLib} from "../libraries/EnumerableSetLib.sol";
import {IPriceFeed} from "../oracle/interfaces/IPriceFeed.sol";
import {Oracle} from "../oracle/Oracle.sol";
import {IReferralStorage} from "../referrals/ReferralStorage.sol";
import {IFeeDistributor} from "../rewards/interfaces/IFeeDistributor.sol";
import {IPositionManager} from "../router/interfaces/IPositionManager.sol";
import {Pool} from "../markets/Pool.sol";
import {SafeTransferLib} from "../libraries/SafeTransferLib.sol";
import {Deployer} from "./Deployer.sol";
import {MarketId, MarketIdLibrary} from "../types/MarketId.sol";

/// @dev Needs MarketFactory Role
/**
 * Known issues:
 * - Users can create pools with a reference price not associated to the asset provided.
 * User interfaces MUST display which pools are high-risk, and which are low risk, or at least have a verification system.
 * single asset markets with validated price sources (including reference price) are the lowest risk. Multi asset markets,
 * supporting illiquid assets, with price sources without references for verification are the highest risk.
 */
contract MarketFactory is IMarketFactory, OwnableRoles, ReentrancyGuard {
    using EnumerableMap for EnumerableMap.DeployMap;
    using EnumerableSetLib for EnumerableSetLib.Bytes32Set;
    using MarketIdLibrary for Input;

    IMarket market;
    ITradeStorage tradeStorage;
    ITradeEngine tradeEngine;
    IPriceFeed priceFeed;
    IReferralStorage referralStorage;
    IFeeDistributor feeDistributor;
    IGlobalRewardTracker rewardTracker;
    IPositionManager positionManager;
    address router;

    FeedRegistryInterface private feedRegistry;
    IUniswapV2Factory private uniV2Factory;
    IUniswapV3Factory private uniV3Factory;

    address private immutable WETH;
    address private immutable USDC;

    uint64 private constant LIQUIDATION_FEE = 0.05e18;
    uint64 private constant POSITION_FEE = 0.001e18;
    uint64 private constant ADL_FEE = 0.01e18;
    uint64 private constant FEE_FOR_EXECUTION = 0.1e18;
    uint128 private constant MIN_COLLATERAL_USD = 2e30;
    uint8 private constant MIN_TIME_TO_EXECUTE = 1 minutes;
    uint8 private constant DECIMALS = 18;
    uint8 private constant MAX_TICKER_LENGTH = 15;

    EnumerableMap.DeployMap private requests;
    EnumerableSetLib.Bytes32Set private marketIds;
    mapping(MarketId market => bool isMarket) public isMarket;
    mapping(uint256 index => MarketId market) public markets;

    // Required to create external Routers to determine optimal trading route
    mapping(string ticker => MarketId[] marketIds) public marketsByTicker;

    bool private isInitialized;
    Pool.Config public defaultConfig;
    address public feeReceiver;
    uint256 public marketCreationFee;
    uint256 public marketExecutionFee;
    uint256 public priceSupportFee;

    // Pyth Feed Id Whitelist
    bytes32 public pythMerkleRoot;

    // Stablecoin Address Whitelist for Uniswap V2 and V3 Pairs
    bytes32 public stablecoinMerkleRoot;

    uint256 public cumulativeMarketIndex;

    // Used to ensure the uniqueness of each request for Market Creation
    uint256 requestNonce;

    constructor(address _weth, address _usdc) {
        _initializeOwner(msg.sender);
        WETH = _weth;
        USDC = _usdc;
    }

    function initialize(
        Pool.Config memory _defaultConfig,
        address _market,
        address _tradeStorage,
        address _tradeEngine,
        address _priceFeed,
        address _referralStorage,
        address _positionManager,
        address _router,
        address _feeDistributor,
        address _feeReceiver,
        uint256 _marketCreationFee,
        uint256 _marketExecutionFee
    ) external onlyOwner {
        if (isInitialized) revert MarketFactory_AlreadyInitialized();
        market = IMarket(_market);
        tradeStorage = ITradeStorage(_tradeStorage);
        tradeEngine = ITradeEngine(_tradeEngine);
        priceFeed = IPriceFeed(_priceFeed);
        referralStorage = IReferralStorage(_referralStorage);
        feeDistributor = IFeeDistributor(_feeDistributor);
        positionManager = IPositionManager(_positionManager);
        router = _router;
        defaultConfig = _defaultConfig;
        feeReceiver = _feeReceiver;
        marketCreationFee = _marketCreationFee;
        marketExecutionFee = _marketExecutionFee;
        isInitialized = true;
        emit MarketFactoryInitialized(_priceFeed);
    }

    function setRewardTracker(address _rewardTracker) external onlyOwner {
        rewardTracker = IGlobalRewardTracker(_rewardTracker);
    }

    function setFeedValidators(address _chainlinkFeedRegistry, address _uniV2Factory, address _uniV3Factory)
        external
        onlyOwner
    {
        feedRegistry = FeedRegistryInterface(_chainlinkFeedRegistry);
        uniV2Factory = IUniswapV2Factory(_uniV2Factory);
        uniV3Factory = IUniswapV3Factory(_uniV3Factory);
    }

    function setDefaultConfig(Pool.Config memory _defaultConfig) external onlyOwner {
        defaultConfig = _defaultConfig;
        emit DefaultConfigSet();
    }

    function updatePriceFeed(IPriceFeed _priceFeed) external onlyOwner {
        priceFeed = _priceFeed;
    }

    function updateMarketFees(uint256 _marketCreationFee, uint256 _marketExecutionFee, uint256 _priceSupportFee)
        external
        onlyOwner
    {
        marketCreationFee = _marketCreationFee;
        marketExecutionFee = _marketExecutionFee;
        priceSupportFee = _priceSupportFee;
    }

    /// @dev - Merkle Trees used as whitelists for all valid Pyth Price Feed Ids and Stablecoin Addresses
    /// These are used for feed validation w.r.t secondary strategies
    function updateMerkleRoots(bytes32 _pythMerkleRoot, bytes32 _stablecoinMerkleRoot) external onlyOwner {
        pythMerkleRoot = _pythMerkleRoot;
        stablecoinMerkleRoot = _stablecoinMerkleRoot;
    }

    function updateFeeDistributor(address _feeDistributor) external onlyOwner {
        feeDistributor = IFeeDistributor(_feeDistributor);
    }

    function updatePositionManager(address _positionManager) external onlyOwner {
        positionManager = IPositionManager(_positionManager);
    }

    /// @dev  withdrawableAmount = balance - reserved incentives
    function withdrawCreationTaxes() external onlyOwner {
        uint256 withdrawableAmount = address(this).balance - (marketExecutionFee * requests.length());

        SafeTransferLib.safeTransferETH(payable(msg.sender), withdrawableAmount);
    }

    /**
     * =========================================== User Interaction Functions ===========================================
     */
    function createNewMarket(Input calldata _input) external payable nonReentrant returns (bytes32 requestKey) {
        uint256 priceUpdateFee = Oracle.estimateRequestCost(priceFeed);
        if (msg.value < marketCreationFee + priceUpdateFee) revert MarketFactory_InvalidFee();

        if (_input.isMultiAsset && msg.sender != owner()) revert MarketFactory_InvalidMultiAssetRequest();

        _initializeAsset(_input, priceUpdateFee);

        requestKey = _getMarketRequestKey(msg.sender, _input.indexTokenTicker);
        ++requestNonce;

        Request memory request = _createRequest(_input);

        if (!requests.set(requestKey, request)) revert MarketFactory_FailedToAddMarket();

        emit MarketRequested(requestKey, _input.indexTokenTicker);
    }

    /// @dev Request price feed pricing for a new asset. Used before adding new tokens to M.A.Ms
    function requestAssetPricing(Input calldata _input) external payable nonReentrant {
        uint256 priceUpdateFee = Oracle.estimateRequestCost(priceFeed);
        if (msg.value < priceUpdateFee + priceSupportFee) revert MarketFactory_InvalidFee();

        _initializeAsset(_input, priceUpdateFee);

        bytes32 requestKey = _getPriceRequestKey(_input.indexTokenTicker);
        if (requests.contains(requestKey)) revert MarketFactory_RequestExists();

        Request memory request = _createRequest(_input);

        if (!requests.set(requestKey, request)) revert MarketFactory_FailedToAddRequest();

        emit AssetRequested(_input.indexTokenTicker);
    }

    /**
     * =========================================== Keeper Functions ===========================================
     */

    /// @dev Fulfills requests from `requestAssetPricing`
    function supportAsset(bytes32 _assetRequestKey) external payable nonReentrant {
        Request memory request = requests.get(_assetRequestKey);

        Oracle.getPrice(priceFeed, request.input.indexTokenTicker, request.requestTimestamp);

        priceFeed.supportAsset(request.input.indexTokenTicker, request.input.strategy, DECIMALS);

        SafeTransferLib.safeTransferETH(payable(msg.sender), priceSupportFee);
    }

    /// @dev Fulfill requests from `createNewMarket`
    function executeMarketRequest(bytes32 _requestKey) external nonReentrant returns (MarketId id) {
        Request memory request = requests.get(_requestKey);

        Oracle.getPrice(priceFeed, request.input.indexTokenTicker, request.requestTimestamp);

        id = _initializeMarketContracts(request);

        SafeTransferLib.safeTransferETH(payable(msg.sender), marketExecutionFee);
    }

    /**
     * =========================================== Getter Functions ===========================================
     */
    function getRequest(bytes32 _requestKey) external view returns (Request memory) {
        return requests.get(_requestKey);
    }

    function getRequestKeys() external view returns (bytes32[] memory) {
        return requests.keys();
    }

    /**
     * =========================================== Private Functions ===========================================
     */
    function _initializeAsset(Input calldata _input, uint256 _priceUpdateFee) private {
        if (bytes(_input.indexTokenTicker).length > MAX_TICKER_LENGTH) revert MarketFactory_InvalidTicker();

        if (_input.strategy.exists) {
            _validateSecondaryStrategy(_input);
        }

        string[] memory args = Oracle.constructPriceArguments(_input.indexTokenTicker);
        priceFeed.requestPriceUpdate{value: _priceUpdateFee}(args, msg.sender);
    }

    // @audit - If token decimals are fetched from uniswap and differ from 18, it will cause issues.
    // If someone attempts to use a different asset, other than an ERC20 it might cause issues.
    function _initializeMarketContracts(Request memory _params) private returns (MarketId id) {
        priceFeed.supportAsset(_params.input.indexTokenTicker, _params.input.strategy, DECIMALS);

        // Generate Market Id
        id = _params.input.toId();
        if (marketIds.contains(MarketId.unwrap(id))) revert MarketFactory_MarketExists();

        address vault = Deployer.deployVault(_params, WETH, USDC);

        market.initializePool(
            id,
            defaultConfig,
            _params.requester,
            0.003e18,
            vault,
            _params.input.indexTokenTicker,
            _params.input.isMultiAsset
        );

        IVault(vault).initialize(
            address(market), address(feeDistributor), address(rewardTracker), address(tradeEngine), feeReceiver
        );

        ITradeStorage(tradeStorage).initializePool(id, vault);

        rewardTracker.addDepositToken(vault);
        feeDistributor.addVault(vault);

        isMarket[id] = true;
        marketIds.add(MarketId.unwrap(id));
        marketsByTicker[_params.input.indexTokenTicker].push(id);
        markets[cumulativeMarketIndex] = id;
        ++cumulativeMarketIndex;

        // Transfer ownership of the new vault contract to the super-user
        OwnableRoles(vault).transferOwnership(owner());

        emit MarketCreated(id, _params.input.indexTokenTicker);
    }

    function _validateSecondaryStrategy(Input calldata _params) private view {
        Oracle.validateFeedType(_params.strategy.feedType);

        if (_params.strategy.feedType == IPriceFeed.FeedType.CHAINLINK) {
            Oracle.isValidChainlinkFeed(feedRegistry, _params.strategy.feedAddress);
        } else if (_params.strategy.feedType == IPriceFeed.FeedType.PYTH) {
            Oracle.isValidPythFeed(_params.strategy.merkleProof, pythMerkleRoot, _params.strategy.feedId);
        } else if (
            _params.strategy.feedType == IPriceFeed.FeedType.UNI_V30
                || _params.strategy.feedType == IPriceFeed.FeedType.UNI_V31
        ) {
            Oracle.isValidUniswapV3Pool(
                uniV3Factory,
                _params.strategy.feedAddress,
                _params.strategy.feedType,
                _params.strategy.merkleProof,
                stablecoinMerkleRoot
            );
        } else if (
            _params.strategy.feedType == IPriceFeed.FeedType.UNI_V20
                || _params.strategy.feedType == IPriceFeed.FeedType.UNI_V21
        ) {
            Oracle.isValidUniswapV2Pool(
                uniV2Factory,
                _params.strategy.feedAddress,
                _params.strategy.feedType,
                _params.strategy.merkleProof,
                stablecoinMerkleRoot
            );
        } else {
            revert MarketFactory_InvalidSecondaryStrategy();
        }
    }

    /// @dev Uses requestNonce as a nonce, and block.timestamp to ensure uniqueness
    function _getMarketRequestKey(address _user, string calldata _indexTokenTicker)
        private
        view
        returns (bytes32 requestKey)
    {
        return keccak256(abi.encodePacked(_user, _indexTokenTicker, block.timestamp, requestNonce));
    }

    /// @dev Keys are determined by the hash of the ticker, to prevent overlapping requests
    function _getPriceRequestKey(string calldata _ticker) private pure returns (bytes32 requestKey) {
        return keccak256(abi.encodePacked(_ticker));
    }

    /// @dev No refunds. Fee is kept by the contract to incentivize requesters to play by the rules.
    function _deleteInvalidRequest(bytes32 _requestKey) private {
        if (!requests.contains(_requestKey)) revert MarketFactory_RequestDoesNotExist();
        if (!requests.remove(_requestKey)) revert MarketFactory_FailedToRemoveRequest();
    }

    // Construct a Request struct from the Input
    function _createRequest(Input calldata _params) private view returns (Request memory) {
        return Request({input: _params, requestTimestamp: uint48(block.timestamp), requester: msg.sender});
    }
}
