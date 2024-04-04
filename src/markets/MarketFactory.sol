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
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IPriceFeed} from "../oracle/interfaces/IPriceFeed.sol";
import {Oracle} from "../oracle/Oracle.sol";
import {IReferralStorage} from "../referrals/ReferralStorage.sol";
import {IFeeDistributor} from "../rewards/interfaces/IFeeDistributor.sol";
import {IPositionManager} from "../router/interfaces/IPositionManager.sol";
import {Roles} from "../access/Roles.sol";

/// @dev Needs MarketFactory Role
contract MarketFactory is IMarketFactory, RoleValidation, ReentrancyGuard {
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.Bytes32Set;

    IPriceFeed priceFeed;
    IReferralStorage referralStorage;
    IFeeDistributor feeDistributor;
    IPositionManager positionManager;

    uint256 private constant MAX_FEE_TO_OWNER = 0.3e18; // 30%
    uint256 private constant MAX_HEARTBEAT_DURATION = 1 days;
    uint256 private constant MAX_PERCENTAGE = 1e18;
    uint256 private constant MIN_PERCENTAGE = 0.01e18; // 1%
    address private immutable WETH;
    address private immutable USDC;

    EnumerableSet.AddressSet private markets;
    EnumerableSet.Bytes32Set private requestKeys;
    mapping(bytes32 requestKey => MarketRequest) private requests;

    bool private isInitialized;
    IMarket.Config public defaultConfig;
    address public feeReceiver;
    uint256 public marketCreationFee;

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
        uint256 _marketCreationFee
    ) external onlyAdmin {
        if (isInitialized) revert MarketFactory_AlreadyInitialized();
        priceFeed = IPriceFeed(_priceFeed);
        referralStorage = IReferralStorage(_referralStorage);
        feeDistributor = IFeeDistributor(_feeDistributor);
        positionManager = IPositionManager(_positionManager);
        defaultConfig = _defaultConfig;
        feeReceiver = _feeReceiver;
        marketCreationFee = _marketCreationFee;
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

    function updateMarketCreationFee(uint256 _marketCreationFee) external onlyAdmin {
        marketCreationFee = _marketCreationFee;
    }

    function updateFeeDistributor(address _feeDistributor) external onlyAdmin {
        feeDistributor = IFeeDistributor(_feeDistributor);
    }

    function updatePositionManager(address _positionManager) external onlyAdmin {
        positionManager = IPositionManager(_positionManager);
    }

    function requestNewMarket(MarketRequest calldata _request) external payable nonReentrant {
        /* Validate the Inputs */
        // 1. Msg.value should be > marketCreationFee
        if (msg.value != marketCreationFee) revert MarketFactory_InvalidFee();
        // 2. Owner should be msg.sender
        if (_request.owner != msg.sender) revert MarketFactory_InvalidOwner();
        // 3. Base Unit should be non-zero
        if (_request.baseUnit == 0) revert MarketFactory_InvalidBaseUnit();
        if (_request.isMultiAsset) {
            // Caller must have the admin role
            if (!roleStorage.hasRole(Roles.DEFAULT_ADMIN_ROLE, msg.sender)) revert MarketFactory_AccessDenied();
        }

        /* Generate a differentiated Request Key based on the inputs */
        bytes32 requestKey = getMarketRequestKey(msg.sender, _request.indexTokenTicker);

        // Add the request key to storage
        requestKeys.add(requestKey);
        // Add the request to storage
        requests[requestKey] = _request;

        // Fire Event
        emit MarketRequested(requestKey, _request.indexTokenTicker);
    }

    /// @dev - Before calling this function, the request's input should be cross-referenced with EVs.
    /// @dev - using chainlink functions or similar, we can eventually open this up to the public by implementing off-chain validation
    /// @dev - never reverts. If the request is invalid, it's deleted and the function returns address(0);
    function executeNewMarket(bytes32 _requestKey) external nonReentrant onlyMarketKeeper returns (address) {
        // Get the Request
        MarketRequest memory request = requests[_requestKey];

        /* Validate and Update the Request */

        // 2. Make sure Market token name and symbol are < 32 bytes for gas efficiency
        if (bytes(request.marketTokenName).length > 32 || bytes(request.marketTokenSymbol).length > 32) {
            _deleteMarketRequest(_requestKey);
            return address(0);
        }

        // Set Up Price Oracle
        priceFeed.supportAsset(request.indexTokenTicker, request.baseUnit);
        // Create new Market Token
        MarketToken marketToken =
            new MarketToken(request.marketTokenName, request.marketTokenSymbol, address(roleStorage));
        // Create new Market contract
        IMarket market;
        if (request.isMultiAsset) {
            market = new MultiAssetMarket(
                defaultConfig,
                request.owner,
                feeReceiver,
                address(feeDistributor),
                WETH,
                USDC,
                address(marketToken),
                request.indexTokenTicker,
                address(roleStorage)
            );
        } else {
            market = new Market(
                defaultConfig,
                request.owner,
                feeReceiver,
                address(feeDistributor),
                WETH,
                USDC,
                address(marketToken),
                request.indexTokenTicker,
                address(roleStorage)
            );
        }
        // Create new TradeStorage contract
        TradeStorage tradeStorage = new TradeStorage(market, referralStorage, priceFeed, address(roleStorage));
        // Create new Reward Tracker contract
        RewardTracker rewardTracker = new RewardTracker(
            market,
            // Prepend an 's' to the start of the name / symbol (staked XYZ)
            string(abi.encodePacked("s", request.marketTokenName)),
            string(abi.encodePacked("s", request.marketTokenSymbol)),
            address(roleStorage)
        );
        // @audit - also deploy liquidity locker and TransferStakedTokens
        // Initialize Market with TradeStorage and 0.3% Borrow Scale
        market.initialize(address(tradeStorage), address(rewardTracker), 0.003e18);
        // Initialize TradeStorage with Default values
        tradeStorage.initialize(0.05e18, 0.001e18, 0.005e18, 0.1e18, 2e30, 10 seconds, 1 minutes);
        // Initialize RewardTracker with Default values
        // Initialize Liquidity Locker and TransferStakedTokens
        // @audit
        // Add to Storage
        bool success = markets.add(address(market));
        if (!success) revert MarketFactory_FailedToAddMarket();

        // Set Up Roles -> Enable Caller to control Market
        roleStorage.setMarketRoles(address(market), Roles.MarketRoles(address(tradeStorage), msg.sender, msg.sender));
        roleStorage.setMinter(address(marketToken), address(market));

        // Send Market Creation Fee to Executor
        payable(msg.sender).transfer(marketCreationFee);

        // Fire Event
        emit MarketCreated(address(market), request.indexTokenTicker);

        return address(market);
    }

    function deleteInvalidRequest(bytes32 _requestKey) external onlyMarketKeeper {
        // Check the Request exists
        if (!requestKeys.contains(_requestKey)) revert MarketFactory_RequestDoesNotExist();
        // Delete the Request
        _deleteMarketRequest(_requestKey);
    }

    /**
     * ========================= Getter Functions =========================
     */
    function getMarkets() external view returns (address[] memory) {
        return markets.values();
    }

    function getMarketAtIndex(uint256 _index) external view returns (address) {
        return markets.at(_index);
    }

    function getMarketRequestKey(address _user, string calldata _indexTokenTicker)
        public
        pure
        returns (bytes32 requestKey)
    {
        return keccak256(abi.encodePacked(_user, _indexTokenTicker));
    }

    function generateAssetId(string memory _indexTokenTicker) public pure returns (bytes32) {
        return keccak256(abi.encode(_indexTokenTicker));
    }

    function isMarket(address _market) external view returns (bool) {
        return markets.contains(_market);
    }

    function getRequest(bytes32 _requestKey) external view returns (MarketRequest memory) {
        return requests[_requestKey];
    }

    /**
     * ========================= Internal Functions =========================
     */
    function _deleteMarketRequest(bytes32 _requestKey) internal {
        requestKeys.remove(_requestKey);
        delete requests[_requestKey];
    }
}
