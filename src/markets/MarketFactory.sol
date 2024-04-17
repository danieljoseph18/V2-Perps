// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IMarketFactory} from "./interfaces/IMarketFactory.sol";
import {RoleValidation} from "../access/RoleValidation.sol";
import {ReentrancyGuard} from "@solmate/utils/ReentrancyGuard.sol";
import {Market, IMarket} from "./Market.sol";
import {MultiAssetMarket} from "./MultiAssetMarket.sol";
import {MarketToken} from "./MarketToken.sol";
import {TradeStorage} from "../positions/TradeStorage.sol";
import {RewardTracker} from "../rewards/RewardTracker.sol";
import {EnumerableMap} from "../libraries/EnumerableMap.sol";
import {IPriceFeed} from "../oracle/interfaces/IPriceFeed.sol";
import {Oracle} from "../oracle/Oracle.sol";
import {IReferralStorage} from "../referrals/ReferralStorage.sol";
import {IFeeDistributor} from "../rewards/interfaces/IFeeDistributor.sol";
import {IPositionManager} from "../router/interfaces/IPositionManager.sol";
import {LiquidityLocker} from "../rewards/LiquidityLocker.sol";
import {TransferStakedTokens} from "../rewards/TransferStakedTokens.sol";
import {Roles} from "../access/Roles.sol";

/// @dev Needs MarketFactory Role
/**
 * Known issues:
 * - Users can create pools with spoofed reference price feeds (either ref price feed not associated with asset, or a fake)
 */
// @audit - could we introduce a flagging system to stall requests that are suspicious?
// they then move into limbo, and if the flag is validated, the flagger gets paid a % of the request fee?
// would need to blacklist a user after multiple invalid flags
contract MarketFactory is IMarketFactory, RoleValidation, ReentrancyGuard {
    using EnumerableMap for EnumerableMap.DeployParamsMap;

    IPriceFeed priceFeed;
    IReferralStorage referralStorage;
    IFeeDistributor feeDistributor;
    IPositionManager positionManager;
    TransferStakedTokens transferStakedTokens;

    uint256 private constant MAX_FEE_TO_OWNER = 0.3e18; // 30%
    uint256 private constant MAX_HEARTBEAT_DURATION = 1 days;
    uint256 private constant MAX_PERCENTAGE = 1e18;
    uint256 private constant MIN_PERCENTAGE = 0.01e18; // 1%
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
    IMarket.Config public defaultConfig;
    address public feeReceiver;
    uint256 public marketCreationFee;
    uint256 public marketExecutionFee;
    uint256 cumulativeMarketIndex;
    uint256 requestNonce;

    constructor(address _weth, address _usdc, address _roleStorage) RoleValidation(_roleStorage) {
        WETH = _weth;
        USDC = _usdc;
    }

    function initialize(
        IMarket.Config memory _defaultConfig,
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

    function setDefaultConfig(IMarket.Config memory _defaultConfig) external onlyAdmin {
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
        payable(msg.sender).transfer(withdrawableAmount);
    }

    /**
     * ========================= User Interaction Functions =========================
     */
    function createNewMarket(DeployParams calldata _params) external payable nonReentrant {
        /* Validate the Inputs */
        if (msg.value != marketCreationFee) revert MarketFactory_InvalidFee();
        if (_params.owner != msg.sender) revert MarketFactory_InvalidOwner();
        if (_params.tokenData.tokenDecimals == 0) revert MarketFactory_InvalidDecimals();
        if (bytes(_params.indexTokenTicker).length > 15) revert MarketFactory_InvalidTicker();
        if (_params.tokenData.hasSecondaryFeed) {
            Oracle.validateFeedType(_params.tokenData.feedType);
            if (_params.tokenData.feedType == IPriceFeed.FeedType.PYTH && _params.pythId == bytes32(0)) {
                revert MarketFactory_InvalidPythFeed();
            }
        }
        if (_params.requestTimestamp != uint48(block.timestamp)) revert MarketFactory_InvalidTimestamp();

        /* Create a Price Request --> used to ensure the price feed returns a valid response */
        string[] memory tickers = new string[](1);
        tickers[0] = _params.indexTokenTicker;
        priceFeed.requestPriceUpdate(tickers, _params.owner);

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
    /// sucessfully executes, the user will
    // @audit - caller could forcibly execute a request and make it fail to revert it
    function executeMarketRequest(bytes32 _requestKey) external nonReentrant {
        // Get the Request
        DeployParams memory request = requests.get(_requestKey);
        // Users can't execute their own requests
        if (msg.sender == request.owner) revert MarketFactory_SelfExecution();

        /* Validate the Requests Pricing Strategies */

        // Reverts if a price wasn't signed.
        // @audit - wrap in try catch --> if fail, call _deleteInvalidRequest(_requestKey)
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
        payable(msg.sender).transfer(marketExecutionFee);
    }

    /**
     * ========================= Getter Functions =========================
     */
    function generateAssetId(string memory _indexTokenTicker) public pure returns (bytes32) {
        return keccak256(abi.encode(_indexTokenTicker));
    }

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
        priceFeed.supportAsset(_params.indexTokenTicker, _params.tokenData, _params.pythId);
        // Create new Market Token
        MarketToken marketToken =
            new MarketToken(_params.marketTokenName, _params.marketTokenSymbol, address(roleStorage));
        // Create new Market contract
        IMarket market;
        if (_params.isMultiAsset) {
            market = new MultiAssetMarket(
                defaultConfig,
                _params.owner,
                feeReceiver,
                address(feeDistributor),
                WETH,
                USDC,
                address(marketToken),
                _params.indexTokenTicker,
                address(roleStorage)
            );
        } else {
            market = new Market(
                defaultConfig,
                _params.owner,
                feeReceiver,
                address(feeDistributor),
                WETH,
                USDC,
                address(marketToken),
                _params.indexTokenTicker,
                address(roleStorage)
            );
        }
        // Create new TradeStorage contract
        TradeStorage tradeStorage = new TradeStorage(market, referralStorage, priceFeed, address(roleStorage));
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
        // Initialize TradeStorage with Default values
        // @audit - we can clean this up --> don't like the magic numbers
        tradeStorage.initialize(0.05e18, 0.001e18, 0.01e18, 0.1e18, 2e30, 1 minutes);
        // Initialize RewardTracker with Default values
        rewardTracker.initialize(address(marketToken), address(feeDistributor), address(liquidityLocker));
        // Add to Storage
        isMarket[address(market)] = true;
        marketsByTicker[_params.indexTokenTicker].push(address(market));
        markets[cumulativeMarketIndex] = address(market);
        ++cumulativeMarketIndex;

        // Set Up Roles -> Enable Requester to control Market
        roleStorage.setMarketRoles(address(market), Roles.MarketRoles(address(tradeStorage), _params.owner));
        roleStorage.setMinter(address(marketToken), address(market));

        // Fire Event
        emit MarketCreated(address(market), _params.indexTokenTicker);
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
