// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IMarketFactory} from "./interfaces/IMarketFactory.sol";
import {RoleValidation} from "../access/RoleValidation.sol";
import {ReentrancyGuard} from "../utils/ReentrancyGuard.sol";
import {Market, IMarket} from "./Market.sol";
import {FeedRegistryInterface} from "@chainlink/contracts/src/v0.8/interfaces/FeedRegistryInterface.sol";
import {IUniswapV3Factory} from "../oracle/interfaces/IUniswapV3Factory.sol";
import {IUniswapV2Factory} from "../oracle/interfaces/IUniswapV2Factory.sol";
import {Vault} from "./Vault.sol";
import {TradeStorage} from "../positions/TradeStorage.sol";
import {RewardTracker} from "../rewards/RewardTracker.sol";
import {EnumerableMap} from "../libraries/EnumerableMap.sol";
import {IPriceFeed} from "../oracle/interfaces/IPriceFeed.sol";
import {Oracle} from "../oracle/Oracle.sol";
import {IReferralStorage} from "../referrals/ReferralStorage.sol";
import {IFeeDistributor} from "../rewards/interfaces/IFeeDistributor.sol";
import {IPositionManager} from "../router/interfaces/IPositionManager.sol";
import {LiquidityLocker} from "../rewards/LiquidityLocker.sol";
import {TradeEngine} from "../positions/TradeEngine.sol";
import {TransferStakedTokens} from "../rewards/TransferStakedTokens.sol";
import {Roles} from "../access/Roles.sol";
import {Pool} from "./Pool.sol";
import {SafeTransferLib} from "../libraries/SafeTransferLib.sol";

/// @dev Needs MarketFactory Role
/**
 * Known issues:
 * - Users can create pools with a reference price not associated to the asset provided.
 * User interfaces MUST display which pools are high-risk, and which are low risk, or at least have a verification system.
 * single asset markets with validated price sources (including reference price) are the lowest risk. Multi asset markets,
 * supporting illiquid assets, with price sources without references for verification are the highest risk.
 */
contract MarketFactory is IMarketFactory, RoleValidation, ReentrancyGuard {
    using EnumerableMap for EnumerableMap.DeployParamsMap;

    IPriceFeed priceFeed;
    IReferralStorage referralStorage;
    IFeeDistributor feeDistributor;
    IPositionManager positionManager;
    TransferStakedTokens transferStakedTokens;

    FeedRegistryInterface private feedRegistry;
    IUniswapV2Factory private uniV2Factory;
    IUniswapV3Factory private uniV3Factory;

    address private immutable WETH;
    address private immutable USDC;

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
    uint256 requestNonce;

    constructor(address _weth, address _usdc, address _roleStorage) RoleValidation(_roleStorage) {
        WETH = _weth;
        USDC = _usdc;
    }

    function initialize(
        Pool.Config memory _defaultConfig,
        address _priceFeed,
        address _referralStorage,
        address _positionManager,
        address _feeDistributor,
        address _feeReceiver,
        uint256 _marketCreationFee,
        uint256 _marketExecutionFee
    ) external onlyAdmin {
        if (isInitialized) revert MarketFactory_AlreadyInitialized();
        priceFeed = IPriceFeed(_priceFeed);
        referralStorage = IReferralStorage(_referralStorage);
        feeDistributor = IFeeDistributor(_feeDistributor);
        positionManager = IPositionManager(_positionManager);
        transferStakedTokens = new TransferStakedTokens();
        defaultConfig = _defaultConfig;
        feeReceiver = _feeReceiver;
        marketCreationFee = _marketCreationFee;
        marketExecutionFee = _marketExecutionFee;
        isInitialized = true;
        emit MarketFactoryInitialized(_priceFeed);
    }

    function setFeedValidators(address _chainlinkFeedRegistry, address _uniV2Factory, address _uniV3Factory)
        external
        onlyAdmin
    {
        feedRegistry = FeedRegistryInterface(_chainlinkFeedRegistry);
        uniV2Factory = IUniswapV2Factory(_uniV2Factory);
        uniV3Factory = IUniswapV3Factory(_uniV3Factory);
    }

    function setDefaultConfig(Pool.Config memory _defaultConfig) external onlyAdmin {
        defaultConfig = _defaultConfig;
        emit DefaultConfigSet();
    }

    function updatePriceFeed(IPriceFeed _priceFeed) external onlyAdmin {
        priceFeed = _priceFeed;
    }

    function updateMarketFees(uint256 _marketCreationFee, uint256 _marketExecutionFee) external onlyAdmin {
        marketCreationFee = _marketCreationFee;
        marketExecutionFee = _marketExecutionFee;
    }

    function updateMerkleRoots(bytes32 _pythMerkleRoot, bytes32 _stablecoinMerkleRoot) external onlyAdmin {
        pythMerkleRoot = _pythMerkleRoot;
        stablecoinMerkleRoot = _stablecoinMerkleRoot;
    }

    function updateFeeDistributor(address _feeDistributor) external onlyAdmin {
        feeDistributor = IFeeDistributor(_feeDistributor);
    }

    function updatePositionManager(address _positionManager) external onlyAdmin {
        positionManager = IPositionManager(_positionManager);
    }

    /// @dev - Function called by the admin to withdraw the fees collected from market creation
    function withdrawCreationTaxes() external onlyAdmin {
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
    function createNewMarket(DeployParams calldata _params) external payable nonReentrant {
        /* Validate the Inputs */
        uint256 priceUpdateFee = Oracle.estimateRequestCost(priceFeed);
        if (msg.value != marketCreationFee + priceUpdateFee) revert MarketFactory_InvalidFee();
        if (_params.owner != msg.sender) revert MarketFactory_InvalidOwner();
        if (_params.tokenData.tokenDecimals == 0) revert MarketFactory_InvalidDecimals();
        if (bytes(_params.indexTokenTicker).length > 15) revert MarketFactory_InvalidTicker();
        if (_params.requestTimestamp != uint48(block.timestamp)) revert MarketFactory_InvalidTimestamp();
        if (_params.tokenData.hasSecondaryFeed) _validateSecondaryStrategy(_params);

        /* Create a Price Request --> used to ensure the price feed returns a valid response */
        string[] memory args = Oracle.constructPriceArguments(_params.indexTokenTicker);
        priceFeed.requestPriceUpdate{value: priceUpdateFee}(args, _params.owner);

        /* Generate a differentiated Request Key based on the inputs */
        bytes32 requestKey = _getMarketRequestKey(msg.sender, _params.indexTokenTicker);
        ++requestNonce;

        // Add the request to storage
        if (!requests.set(requestKey, _params)) revert MarketFactory_FailedToAddMarket();

        // Fire Event
        emit MarketRequested(requestKey, _params.indexTokenTicker);
    }

    /// @dev - This function is to be called by executors / keepers to execute a request.
    /// If the request fails to execute, it will be cleared from storage. If the request
    /// sucessfully executes, the keeper will be paid an execution fee as an incentive.
    function executeMarketRequest(bytes32 _requestKey) external nonReentrant {
        // Get the Request
        DeployParams memory request = requests.get(_requestKey);
        // Users can't execute their own requests
        if (msg.sender == request.owner) revert MarketFactory_SelfExecution();

        /* Validate the Requests Pricing Strategies */

        // Reverts if a price wasn't signed.
        try Oracle.getPrice(priceFeed, request.indexTokenTicker, request.requestTimestamp) returns (
            uint256 priceReponse
        ) {
            // Validate the price range from reference price --> will revert if failed to fetch ref price
            if (request.tokenData.hasSecondaryFeed) {
                try Oracle.validatePriceRange(priceFeed, request.indexTokenTicker, priceReponse) {
                    // If the price is valid, continue
                } catch {
                    _deleteInvalidRequest(_requestKey);
                    return;
                }
            }
        } catch {
            _deleteInvalidRequest(_requestKey);
            return;
        }
        /* Create and initiate the market contracts */
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
    function _initializeMarketContracts(DeployParams memory _params) private {
        // Set Up Price Oracle
        priceFeed.supportAsset(_params.indexTokenTicker, _params.tokenData, _params.pythData.id);
        // Create new Market Token
        Vault vault = new Vault(WETH, USDC, _params.marketTokenName, _params.marketTokenSymbol, address(roleStorage));
        // Create new Market contract
        IMarket market = new Market(
            defaultConfig,
            _params.owner,
            feeReceiver,
            address(feeDistributor),
            WETH,
            USDC,
            address(vault),
            _params.indexTokenTicker,
            _params.isMultiAsset,
            address(roleStorage)
        );

        // Create new TradeStorage contract
        TradeStorage tradeStorage = new TradeStorage(market, referralStorage, priceFeed, address(roleStorage));
        // Create new Trade Engine contract
        TradeEngine tradeEngine = new TradeEngine(tradeStorage, address(roleStorage));
        // Create new Reward Tracker contract
        RewardTracker rewardTracker = new RewardTracker(
            market,
            // Prepend Staked Prefix
            string(abi.encodePacked("Staked ", _params.marketTokenName)),
            string(abi.encodePacked("s", _params.marketTokenSymbol)),
            address(roleStorage)
        );
        // Deploy LiquidityLocker
        LiquidityLocker liquidityLocker =
            new LiquidityLocker(address(rewardTracker), address(transferStakedTokens), WETH, USDC, address(roleStorage));
        // Initialize Market with TradeStorage and 0.3% Borrow Scale
        market.initialize(address(tradeStorage), address(rewardTracker), 0.003e18);
        // Initialize Vault with Market
        vault.initialize(address(market));
        // Initialize TradeStorage with Default values
        // @gas - we can clean this up --> don't like the magic numbers
        tradeStorage.initialize(tradeEngine, 0.05e18, 0.001e18, 0.01e18, 0.1e18, 2e30, 1 minutes);
        // Initialize RewardTracker with Default values
        rewardTracker.initialize(address(vault), address(feeDistributor), address(liquidityLocker));
        // Add to Storage
        isMarket[address(market)] = true;
        marketsByTicker[_params.indexTokenTicker].push(address(market));
        markets[cumulativeMarketIndex] = address(market);
        ++cumulativeMarketIndex;

        // Set Up Roles -> Enable Requester to control Market
        roleStorage.setMarketRoles(address(market), Roles.MarketRoles(address(tradeStorage), _params.owner));
        roleStorage.setMinter(address(vault), address(market));

        // Fire Event
        emit MarketCreated(address(market), _params.indexTokenTicker);
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

    // No refunds. Fee is kept by the contract to ensure requesters play by the rules.
    function _deleteInvalidRequest(bytes32 _requestKey) private {
        // Check the Request exists
        if (!requests.contains(_requestKey)) revert MarketFactory_RequestDoesNotExist();
        // Delete the Request
        if (!requests.remove(_requestKey)) revert MarketFactory_FailedToRemoveRequest();
    }
}
