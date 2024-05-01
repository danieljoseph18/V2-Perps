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
import {IGlobalRewardTracker} from "../rewards/interfaces/IGlobalRewardTracker.sol";
import {EnumerableMap} from "../libraries/EnumerableMap.sol";
import {IPriceFeed} from "../oracle/interfaces/IPriceFeed.sol";
import {Oracle} from "../oracle/Oracle.sol";
import {IReferralStorage} from "../referrals/ReferralStorage.sol";
import {IGlobalFeeDistributor} from "../rewards/interfaces/IGlobalFeeDistributor.sol";
import {IPositionManager} from "../router/interfaces/IPositionManager.sol";
import {ILiquidityLocker} from "../rewards/interfaces/ILiquidityLocker.sol";
import {TransferStakedTokens} from "../rewards/TransferStakedTokens.sol";
import {Pool} from "../markets/Pool.sol";
import {SafeTransferLib} from "../libraries/SafeTransferLib.sol";
import {Deployer} from "./Deployer.sol";

/// @dev Needs MarketFactory Role
/**
 * Known issues:
 * - Users can create pools with a reference price not associated to the asset provided.
 * User interfaces MUST display which pools are high-risk, and which are low risk, or at least have a verification system.
 * single asset markets with validated price sources (including reference price) are the lowest risk. Multi asset markets,
 * supporting illiquid assets, with price sources without references for verification are the highest risk.
 */
contract MarketFactory is IMarketFactory, OwnableRoles, ReentrancyGuard {
    using EnumerableMap for EnumerableMap.DeployParamsMap;

    IPriceFeed priceFeed;
    IReferralStorage referralStorage;
    IGlobalFeeDistributor feeDistributor;
    IGlobalRewardTracker rewardTracker;
    ILiquidityLocker liquidityLocker;
    IPositionManager positionManager;
    TransferStakedTokens transferStakedTokens;
    address router;

    FeedRegistryInterface private feedRegistry;
    IUniswapV2Factory private uniV2Factory;
    IUniswapV3Factory private uniV3Factory;

    address private immutable WETH;
    address private immutable USDC;
    // Default Values
    uint64 private constant LIQUIDATION_FEE = 0.05e18;
    uint64 private constant POSITION_FEE = 0.001e18;
    uint64 private constant ADL_FEE = 0.01e18;
    uint64 private constant FEE_FOR_EXECUTION = 0.1e18;
    uint128 private constant MIN_COLLATERAL_USD = 2e30;
    uint8 private constant MIN_TIME_TO_EXECUTE = 1 minutes;
    uint8 private constant DECIMALS = 18;

    // @audit - rename, misleading
    EnumerableMap.DeployParamsMap private requests;
    mapping(address market => bool isMarket) public isMarket;
    mapping(uint256 index => address market) public markets;
    /**
     * Required to create a Router from interfaces.
     * By simulating the trade through each market associated with the ticker,
     * we can determine the optimal route to trade through.
     */
    mapping(string ticker => address[] markets) public marketsByTicker;

    bool private isInitialized;
    Pool.Config public defaultConfig;
    address public feeReceiver;
    uint256 public marketCreationFee;
    uint256 public marketExecutionFee;
    uint256 public priceSupportFee;
    /**
     * Stores the feed ids of all of the valid pyth price feeds.
     * This enables us to ensure that the pyth price feed a user inputs as
     * a reference price feed is a valid feed.
     */
    bytes32 public pythMerkleRoot;
    /**
     * Stores the addresses of all valid stablecoins for a given chain.
     * This is required for fetching prices from AMM secondary strategies,
     * as one of the tokens in the pair must be a stablecoin to get a USD
     * equivalent value for the computed price.
     */
    bytes32 public stablecoinMerkleRoot;
    uint256 cumulativeMarketIndex;
    // Used to ensure the uniqueness of each request for Market Creation
    uint256 requestNonce;

    constructor(address _weth, address _usdc) {
        _initializeOwner(msg.sender);
        WETH = _weth;
        USDC = _usdc;
    }

    function initialize(
        Pool.Config memory _defaultConfig,
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
        priceFeed = IPriceFeed(_priceFeed);
        referralStorage = IReferralStorage(_referralStorage);
        feeDistributor = IGlobalFeeDistributor(_feeDistributor);
        positionManager = IPositionManager(_positionManager);
        transferStakedTokens = new TransferStakedTokens();
        router = _router;
        defaultConfig = _defaultConfig;
        feeReceiver = _feeReceiver;
        marketCreationFee = _marketCreationFee;
        marketExecutionFee = _marketExecutionFee;
        isInitialized = true;
        emit MarketFactoryInitialized(_priceFeed);
    }

    function setRewardContracts(address _rewardTracker, address _liquidityLocker) external onlyOwner {
        rewardTracker = IGlobalRewardTracker(_rewardTracker);
        liquidityLocker = ILiquidityLocker(_liquidityLocker);
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
        feeDistributor = IGlobalFeeDistributor(_feeDistributor);
    }

    function updatePositionManager(address _positionManager) external onlyOwner {
        positionManager = IPositionManager(_positionManager);
    }

    /// @dev - Function called by the admin to withdraw the fees collected from market creation
    function withdrawCreationTaxes() external onlyOwner {
        // Calculate the withdrawable amount (amount not held in escrow for open positions)
        uint256 withdrawableAmount = address(this).balance;
        // Withdrawable amount is the balance minus the fees escrowed to incentivize executors
        withdrawableAmount -= (marketExecutionFee * requests.length());
        // Transfer the withdrawable amount to the fee receiver
        SafeTransferLib.safeTransferETH(payable(msg.sender), withdrawableAmount);
    }

    /**
     * ========================= User Interaction Functions =========================
     */
    /// @dev Params unrelated to the request can be left blank --> merkle roots, pyth id etc.
    /// @dev Decimals are hard-coded to 18. NFTs / non-ERC20s will be represented fractionally.
    function createNewMarket(DeployParams calldata _params) external payable nonReentrant {
        uint256 priceUpdateFee = Oracle.estimateRequestCost(priceFeed);
        if (msg.value < marketCreationFee + priceUpdateFee) revert MarketFactory_InvalidFee();

        _initializeAsset(_params, priceUpdateFee);

        bytes32 requestKey = _getMarketRequestKey(msg.sender, _params.indexTokenTicker);
        ++requestNonce;

        // Add the request to storage
        if (!requests.set(requestKey, _params)) revert MarketFactory_FailedToAddMarket();

        // Fire Event
        emit MarketRequested(requestKey, _params.indexTokenTicker);
    }

    /**
     * A user calls this function to request a new asset. The user must pay a fee to request the asset.
     * The fee is used to pay for the gas required to update the price feed.
     * This function can be used by pool owners to price an asset before adding a new one to their pool.
     * Returns if the asset is already supported
     * Nonce is not used to prevent duplicate requests.
     */
    function requestAssetPricing(DeployParams calldata _params) external payable nonReentrant {
        uint256 priceUpdateFee = Oracle.estimateRequestCost(priceFeed);
        if (msg.value < priceUpdateFee + priceSupportFee) revert MarketFactory_InvalidFee();

        _initializeAsset(_params, priceUpdateFee);

        bytes32 requestKey = _getPriceRequestKey(_params.indexTokenTicker);
        if (requests.contains(requestKey)) revert MarketFactory_RequestExists();

        if (!requests.set(requestKey, _params)) revert MarketFactory_FailedToAddRequest();

        emit AssetRequested(_params.indexTokenTicker);
    }

    /**
     * ========================= Keeper Functions =========================
     */

    /**
     * This function is called by a keeper to fulfill the request for support of a new asset.
     * 2 steps are required to fully validate the pricing strategy.
     */
    function supportAsset(bytes32 _assetRequestKey) external payable nonReentrant {
        DeployParams memory request = requests.get(_assetRequestKey);

        // Reverts if a price wasn't signed.
        try Oracle.getPrice(priceFeed, request.indexTokenTicker, request.requestTimestamp) {}
        catch {
            _deleteInvalidRequest(_assetRequestKey);
            return;
        }

        // Add the asset to the price feed
        priceFeed.supportAsset(request.indexTokenTicker, request.tokenData, request.pythData.id);

        // Send the Execution Fee to the fulfiller
        SafeTransferLib.safeTransferETH(payable(msg.sender), priceSupportFee);
    }

    /// @dev - This function is to be called by executors / keepers to execute a request.
    /// If the request fails to execute, it will be cleared from storage. If the request
    /// sucessfully executes, the keeper will be paid an execution fee as an incentive.
    function executeMarketRequest(bytes32 _requestKey) external nonReentrant {
        // Get the Request
        DeployParams memory request = requests.get(_requestKey);

        // Reverts if a price wasn't signed.
        try Oracle.getPrice(priceFeed, request.indexTokenTicker, request.requestTimestamp) {}
        catch {
            _deleteInvalidRequest(_requestKey);
            return;
        }

        _initializeMarketContracts(request);

        // Send the Execution Fee to the fulfiller
        SafeTransferLib.safeTransferETH(payable(msg.sender), marketExecutionFee);
    }

    /**
     * ========================= Getter Functions =========================
     */
    function getRequest(bytes32 _requestKey) external view returns (DeployParams memory) {
        return requests.get(_requestKey);
    }

    /**
     * @dev Return the an array containing all the keys
     *
     * WARNING: This operation will copy the entire storage to memory, which can be quite expensive. This is designed
     * to mostly be used by view accessors that are queried without any gas fees. Developers should keep in mind that
     * this function has an unbounded cost, and using it as part of a state-changing function may render the function
     * uncallable if the map grows to a point where copying to memory consumes too much gas to fit in a block.
     */
    function getRequestKeys() external view returns (bytes32[] memory) {
        return requests.keys();
    }

    /**
     * ========================= Private Functions =========================
     */
    function _initializeAsset(DeployParams calldata _params, uint256 _priceUpdateFee) private {
        if (bytes(_params.indexTokenTicker).length > 15) revert MarketFactory_InvalidTicker();
        if (_params.tokenData.tokenDecimals != DECIMALS) revert MarketFactory_InvalidDecimals();
        if (_params.requestTimestamp != uint48(block.timestamp)) revert MarketFactory_InvalidTimestamp();

        if (_params.tokenData.hasSecondaryFeed) {
            _validateSecondaryStrategy(_params);
        }

        string[] memory args = Oracle.constructPriceArguments(_params.indexTokenTicker);
        priceFeed.requestPriceUpdate{value: _priceUpdateFee}(args, _params.owner);
    }

    function _initializeMarketContracts(DeployParams memory _params) private {
        // Set Up Price Oracle
        priceFeed.supportAsset(_params.indexTokenTicker, _params.tokenData, _params.pythData.id);
        // Create new Market Token
        address vault = Deployer.deployVault(_params, WETH, USDC);
        // Create new Market contract
        address market = Deployer.deployMarket(defaultConfig, _params, vault, WETH, USDC);
        // Create new TradeStorage contract
        address tradeStorage = Deployer.deployTradeStorage(IMarket(market), IVault(vault), referralStorage, priceFeed);
        // Initialize Market with TradeStorage and 0.3% Borrow Scale
        address tradeStorageAddress = address(tradeStorage);
        IMarket(market).initialize(tradeStorageAddress, 0.003e18);
        // Initialize Vault with Market
        IVault(vault).initialize(market, address(feeDistributor), address(rewardTracker), feeReceiver);
        // Initialize TradeStorage with Default values
        ITradeStorage(tradeStorage).initialize(
            LIQUIDATION_FEE, POSITION_FEE, ADL_FEE, FEE_FOR_EXECUTION, MIN_COLLATERAL_USD, MIN_TIME_TO_EXECUTE
        );
        // Initialize RewardTracker with Default values
        address vaultAddress = address(vault);
        rewardTracker.addDepositToken(vaultAddress);
        // Add to Storage
        isMarket[market] = true;
        marketsByTicker[_params.indexTokenTicker].push(market);
        markets[cumulativeMarketIndex] = market;
        ++cumulativeMarketIndex;

        // Set Market's roles (1,2,3,4,5)
        OwnableRoles(market).grantRoles(address(positionManager), _ROLE_1);
        OwnableRoles(market).grantRoles(_params.owner, _ROLE_2);
        OwnableRoles(market).grantRoles(router, _ROLE_3);
        OwnableRoles(market).grantRoles(tradeStorageAddress, _ROLE_4);
        // Transfer ownership to super admin
        OwnableRoles(market).transferOwnership(owner());

        // Set Vault's roles (2,4,5)
        OwnableRoles(vaultAddress).grantRoles(_params.owner, _ROLE_2);
        OwnableRoles(vaultAddress).grantRoles(tradeStorageAddress, _ROLE_4);
        // Transfer ownership to super admin
        OwnableRoles(vaultAddress).transferOwnership(owner());

        // Set TradeStorage's roles (1,2,3,5)
        OwnableRoles(tradeStorageAddress).grantRoles(address(positionManager), _ROLE_1);
        OwnableRoles(tradeStorageAddress).grantRoles(_params.owner, _ROLE_2);
        OwnableRoles(tradeStorageAddress).grantRoles(router, _ROLE_3);
        // Transfer ownership to super admin
        OwnableRoles(tradeStorageAddress).transferOwnership(owner());

        // Fire Event
        emit MarketCreated(market, _params.indexTokenTicker);
    }

    function _validateSecondaryStrategy(DeployParams calldata _params) private view {
        Oracle.validateFeedType(_params.tokenData.feedType);
        // If the feed is a Chainlink feed, validate the feed
        if (_params.tokenData.feedType == IPriceFeed.FeedType.CHAINLINK) {
            Oracle.isValidChainlinkFeed(feedRegistry, _params.tokenData.secondaryFeed);
        } else if (_params.tokenData.feedType == IPriceFeed.FeedType.PYTH) {
            Oracle.isValidPythFeed(_params.pythData.merkleProof, pythMerkleRoot, _params.pythData.id);
        } else if (
            _params.tokenData.feedType == IPriceFeed.FeedType.UNI_V30
                || _params.tokenData.feedType == IPriceFeed.FeedType.UNI_V31
        ) {
            Oracle.isValidUniswapV3Pool(
                uniV3Factory,
                _params.tokenData.secondaryFeed,
                _params.tokenData.feedType,
                _params.stablecoinMerkleProof,
                stablecoinMerkleRoot
            );
        } else if (
            _params.tokenData.feedType == IPriceFeed.FeedType.UNI_V20
                || _params.tokenData.feedType == IPriceFeed.FeedType.UNI_V21
        ) {
            Oracle.isValidUniswapV2Pool(
                uniV2Factory,
                _params.tokenData.secondaryFeed,
                _params.tokenData.feedType,
                _params.stablecoinMerkleProof,
                stablecoinMerkleRoot
            );
        }
    }

    /// @dev - Each key has to be 100% unique, as deletion from the map can leave corrupted data
    /// Uses requestNonce as a nonce, and block.timestamp to ensure uniqueness
    function _getMarketRequestKey(address _user, string calldata _indexTokenTicker)
        private
        view
        returns (bytes32 requestKey)
    {
        return keccak256(abi.encodePacked(_user, _indexTokenTicker, block.timestamp, requestNonce));
    }

    function _getPriceRequestKey(string calldata _ticker) private pure returns (bytes32 requestKey) {
        return keccak256(abi.encodePacked(_ticker));
    }

    // No refunds. Fee is kept by the contract to ensure requesters play by the rules.
    function _deleteInvalidRequest(bytes32 _requestKey) private {
        // Check the Request exists
        if (!requests.contains(_requestKey)) revert MarketFactory_RequestDoesNotExist();
        // Delete the Request
        if (!requests.remove(_requestKey)) revert MarketFactory_FailedToRemoveRequest();
    }
}
