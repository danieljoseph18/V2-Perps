// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IMarketMaker} from "./interfaces/IMarketMaker.sol";
import {RoleValidation} from "../access/RoleValidation.sol";
import {ReentrancyGuard} from "@solmate/utils/ReentrancyGuard.sol";
import {Market, IMarket} from "./Market.sol";
import {MarketToken} from "./MarketToken.sol";
import {TradeStorage} from "../positions/TradeStorage.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IPriceFeed} from "../oracle/interfaces/IPriceFeed.sol";
import {Oracle} from "../oracle/Oracle.sol";
import {IReferralStorage} from "../referrals/ReferralStorage.sol";
import {IFeeDistributor} from "../rewards/interfaces/IFeeDistributor.sol";
import {IPositionManager} from "../router/interfaces/IPositionManager.sol";
import {Roles} from "../access/Roles.sol";

/// @dev Needs MarketMaker Role
contract MarketMaker is IMarketMaker, RoleValidation, ReentrancyGuard {
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
    mapping(bytes32 requestKey => MarketRequest) public requests;
    mapping(bytes32 assetId => address market) public tokenToMarket;
    uint256[] private defaultAllocation;

    bool private isInitialized;
    IMarket.Config public defaultConfig;
    address public feeReceiver;
    uint256 public marketCreationFee;

    constructor(address _weth, address _usdc, address _roleStorage) RoleValidation(_roleStorage) {
        WETH = _weth;
        USDC = _usdc;
        defaultAllocation.push(10000 << 240);
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
        if (isInitialized) revert MarketMaker_AlreadyInitialized();
        priceFeed = IPriceFeed(_priceFeed);
        referralStorage = IReferralStorage(_referralStorage);
        feeDistributor = IFeeDistributor(_feeDistributor);
        positionManager = IPositionManager(_positionManager);
        defaultConfig = _defaultConfig;
        feeReceiver = _feeReceiver;
        marketCreationFee = _marketCreationFee;
        isInitialized = true;
        emit MarketMakerInitialized(_priceFeed);
    }

    function setDefaultConfig(IMarket.Config memory _defaultConfig) external onlyAdmin {
        defaultConfig = _defaultConfig;
        emit DefaultConfigSet(_defaultConfig);
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

    /**
     * @dev - A user can pass in a spoofed price strategy. Requests should be reviewed by the executor
     * pre-execution to ensure the validity of these strategies. The payment of the non-refundable fee
     * is designed to disincentivize bad actors from creating invalid requests.
     * Illiquid AMM pools, incorrect price feeds, and other invalid inputs should be rejected.
     */
    function requestNewMarket(MarketRequest calldata _request) external payable nonReentrant {
        /* Validate the Inputs */
        // 1. Msg.value should be > marketCreationFee
        if (msg.value != marketCreationFee) revert MarketMaker_InvalidFee();
        // 2. Owner should be msg.sender
        if (_request.owner != msg.sender) revert MarketMaker_InvalidOwner();
        // 3. Base Unit should be non-zero
        if (_request.asset.baseUnit == 0) revert MarketMaker_InvalidBaseUnit();
        // 4. If primary strategy is pyth, priceId should be non-zero
        if (_request.asset.primaryStrategy == Oracle.PrimaryStrategy.PYTH) {
            if (_request.asset.priceId == bytes32(0)) revert MarketMaker_InvalidPriceId();
        } else if (_request.asset.primaryStrategy != Oracle.PrimaryStrategy.OFFCHAIN) {
            revert MarketMaker_InvalidPrimaryStrategy();
        }
        // 5. If secondary strategy is chainlink, chainlinkPriceFeed should be non-zero
        if (_request.asset.secondaryStrategy == Oracle.SecondaryStrategy.CHAINLINK) {
            if (_request.asset.chainlinkPriceFeed == address(0)) revert MarketMaker_InvalidPriceFeed();
        } else if (_request.asset.secondaryStrategy == Oracle.SecondaryStrategy.AMM) {
            // 6. If secondary strategy is AMM, Uniswap Pool should be correctly configured.
            if (
                _request.asset.pool.poolType != Oracle.PoolType.V3 && _request.asset.pool.poolType != Oracle.PoolType.V2
            ) {
                revert MarketMaker_InvalidPoolType();
            }
            if (_request.asset.pool.poolAddress == address(0)) revert MarketMaker_InvalidPoolAddress();
            if (_request.asset.pool.token0 == address(0) || _request.asset.pool.token1 == address(0)) {
                revert MarketMaker_InvalidPoolTokens();
            }
        } else if (_request.asset.secondaryStrategy == Oracle.SecondaryStrategy.NONE) {
            // If secondary strategy is NONE, caller has to have Admin role
            // For permissionless markets, users can't request a market with no secondary strategy
            if (!roleStorage.hasRole(Roles.DEFAULT_ADMIN_ROLE, msg.sender)) {
                revert MarketMaker_InvalidSecondaryStrategy();
            }
        } else {
            revert MarketMaker_InvalidSecondaryStrategy();
        }
        // 7. Max Price Deviation should be within bounds
        if (_request.asset.maxPriceDeviation > MAX_PERCENTAGE || _request.asset.maxPriceDeviation < MIN_PERCENTAGE) {
            revert MarketMaker_InvalidMaxPriceDeviation();
        }
        // 8. Market shouldn't already exist for that asset
        if (tokenToMarket[generateAssetId(_request.indexTokenTicker)] != address(0)) {
            revert MarketMaker_MarketExists();
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

        // Generate the Asset ID
        bytes32 assetId = generateAssetId(request.indexTokenTicker);

        /* Validate and Update the Request */

        // 1. If asset already has a market, delete request and return
        if (tokenToMarket[assetId] != address(0)) {
            _deleteMarketRequest(_requestKey);
            return address(0);
        }
        // 2. Make sure Market token name and symbol are < 32 bytes for gas efficiency
        if (bytes(request.marketTokenName).length > 32 || bytes(request.marketTokenSymbol).length > 32) {
            _deleteMarketRequest(_requestKey);
            return address(0);
        }
        // 3. If price id is set, make a call to check it returns a non 0 value from pyth
        if (request.asset.primaryStrategy == Oracle.PrimaryStrategy.PYTH) {
            (uint256 price,) = priceFeed.getPriceUnsafe(request.asset);
            if (price == 0) {
                _deleteMarketRequest(_requestKey);
                return address(0);
            }
        }
        // 4. If secondary strategy is set, make a call to check it returns a non 0 value
        if (request.asset.secondaryStrategy != Oracle.SecondaryStrategy.NONE) {
            if (Oracle.getReferencePrice(request.asset) == 0) {
                _deleteMarketRequest(_requestKey);
                return address(0);
            }
        }

        // Set Up Price Oracle
        priceFeed.supportAsset(assetId, request.asset);
        // Create new Market Token
        MarketToken marketToken =
            new MarketToken(request.marketTokenName, request.marketTokenSymbol, address(roleStorage));
        // Create new Market contract
        Market market = new Market(
            defaultConfig,
            request.owner,
            feeReceiver,
            address(feeDistributor),
            WETH,
            USDC,
            address(marketToken),
            assetId,
            address(roleStorage)
        );
        // Create new TradeStorage contract
        TradeStorage tradeStorage = new TradeStorage(market, referralStorage, priceFeed, address(roleStorage));
        // Initialize Market with TradeStorage and 0.3% Borrow Scale
        market.initialize(address(tradeStorage), 0.003e18);
        // Initialize TradeStorage with Default values
        tradeStorage.initialize(0.05e18, 0.001e18, 2e30, 10);

        // Add to Storage
        bool success = markets.add(address(market));
        if (!success) revert MarketMaker_FailedToAddMarket();
        tokenToMarket[assetId] = address(market);

        // Set Up Roles -> Enable Caller to control Market
        roleStorage.setMarketRoles(address(market), Roles.MarketRoles(address(tradeStorage), msg.sender, msg.sender));
        roleStorage.setMinter(address(marketToken), address(market));

        // Send Market Creation Fee to Executor
        payable(msg.sender).transfer(marketCreationFee);

        // Fire Event
        emit MarketCreated(address(market), assetId, request.asset.priceId);

        return address(market);
    }

    function deleteInvalidRequest(bytes32 _requestKey) external onlyMarketKeeper {
        // Check the Request exists
        if (!requestKeys.contains(_requestKey)) revert MarketMaker_RequestDoesNotExist();
        // Delete the Request
        _deleteMarketRequest(_requestKey);
    }

    /// @dev - Only the Admin can create multi-asset markets
    function addTokenToMarket(
        IMarket market,
        bytes32 _assetId,
        bytes32 _priceId,
        Oracle.Asset memory _asset,
        uint256[] calldata _newAllocations
    ) external onlyAdmin nonReentrant {
        if (_assetId == bytes32(0)) revert MarketMaker_InvalidAsset();
        if (_priceId == bytes32(0)) revert MarketMaker_InvalidPriceId();
        if (!markets.contains(address(market))) revert MarketMaker_MarketDoesNotExist();

        // Set Up Price Oracle
        priceFeed.supportAsset(_assetId, _asset);
        // Cache
        address marketAddress = address(market);
        // Add to Market
        market.addToken(defaultConfig, _assetId, _newAllocations);

        // Fire Event
        emit TokenAddedToMarket(marketAddress, _assetId, _priceId);
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

    /**
     * ========================= Internal Functions =========================
     */
    function _deleteMarketRequest(bytes32 _requestKey) internal {
        requestKeys.remove(_requestKey);
        delete requests[_requestKey];
    }
}
