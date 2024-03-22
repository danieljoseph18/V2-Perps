// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IMarketMaker} from "./interfaces/IMarketMaker.sol";
import {RoleValidation} from "../access/RoleValidation.sol";
import {ReentrancyGuard} from "@solmate/utils/ReentrancyGuard.sol";
import {Market, IMarket, IVault} from "./Market.sol";
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

    IPriceFeed priceFeed;
    IReferralStorage referralStorage;
    IFeeDistributor feeDistributor;
    IPositionManager positionManager;

    uint256 private constant LONG_BASE_UNIT = 1e18;
    uint256 private constant SHORT_BASE_UNIT = 1e6;
    uint256 private constant MAX_FEE_SCALE = 0.1e18; // 10%
    uint256 private constant MAX_FEE_TO_OWNER = 0.3e18; // 30%
    uint256 private constant MIN_TIME_TO_EXPIRATION = 1 days; // @audit
    uint256 private constant MAX_TIME_TO_EXPIRATION = 365 days; // @audit
    uint256 private constant MAX_HEARTBEAT_DURATION = 1 days;
    uint256 private constant MAX_PERCENTAGE = 1e18;
    uint256 private constant MIN_PERCENTAGE = 0.01e18; // 1%

    EnumerableSet.AddressSet private markets;
    // switch to enumerable set? what if a token has 2+ markets?
    mapping(bytes32 assetId => address market) public tokenToMarkets;
    uint256[] private defaultAllocation;

    bool private isInitialized;
    address private weth;
    address private usdc;
    IMarket.Config public defaultConfig;

    constructor(address _roleStorage) RoleValidation(_roleStorage) {
        defaultAllocation.push(10000 << 240);
    }

    modifier validAsset(Oracle.Asset calldata _asset) {
        if (!_asset.isValid) revert MarketMaker_InvalidAsset();
        if (_asset.baseUnit != 1e18 && _asset.baseUnit != 1e8 && _asset.baseUnit != 1e6) {
            revert MarketMaker_InvalidBaseUnit();
        }
        if (_asset.heartbeatDuration > MAX_HEARTBEAT_DURATION) {
            revert MarketMaker_InvalidHeartbeatDuration();
        }
        if (_asset.maxPriceDeviation > MAX_PERCENTAGE || _asset.maxPriceDeviation < MIN_PERCENTAGE) {
            revert MarketMaker_InvalidMaxPriceDeviation();
        }
        if (
            _asset.primaryStrategy != Oracle.PrimaryStrategy.PYTH
                && _asset.primaryStrategy != Oracle.PrimaryStrategy.OFFCHAIN
        ) {
            revert MarketMaker_InvalidPrimaryStrategy();
        }

        if (_asset.secondaryStrategy == Oracle.SecondaryStrategy.CHAINLINK && _asset.chainlinkPriceFeed == address(0)) {
            revert MarketMaker_InvalidSecondaryStrategy();
        } else if (_asset.secondaryStrategy == Oracle.SecondaryStrategy.AMM) {
            if (
                _asset.pool.poolType != Oracle.PoolType.UNISWAP_V3 && _asset.pool.poolType != Oracle.PoolType.UNISWAP_V2
            ) {
                revert MarketMaker_InvalidPoolType();
            }
            if (_asset.pool.token0 == address(0) || _asset.pool.token1 == address(0)) {
                revert MarketMaker_InvalidPoolTokens();
            }
            if (_asset.pool.poolAddress == address(0)) {
                revert MarketMaker_InvalidPoolAddress();
            }
        } else if (_asset.secondaryStrategy != Oracle.SecondaryStrategy.NONE) {
            revert MarketMaker_InvalidSecondaryStrategy();
        }
        _;
    }

    modifier validConfig(IVault.VaultConfig calldata _config) {
        if (_config.priceFeed != address(priceFeed)) revert MarketMaker_InvalidPriceFeed();
        if (
            _config.longToken != weth || _config.shortToken != usdc || _config.longBaseUnit != LONG_BASE_UNIT
                || _config.shortBaseUnit != SHORT_BASE_UNIT
        ) {
            revert MarketMaker_InvalidTokensOrBaseUnits();
        }
        if (_config.feeScale > MAX_FEE_SCALE || _config.feePercentageToOwner > MAX_FEE_TO_OWNER) {
            revert MarketMaker_InvalidFeeConfig();
        }
        if (_config.poolOwner != msg.sender) revert MarketMaker_InvalidPoolOwner();
        if (_config.positionManager != address(positionManager)) revert MarketMaker_InvalidPositionManager();
        if (_config.feeDistributor != address(feeDistributor)) revert MarketMaker_InvalidFeeDistributor();
        if (
            _config.minTimeToExpiration < MIN_TIME_TO_EXPIRATION || _config.minTimeToExpiration > MAX_TIME_TO_EXPIRATION
        ) revert MarketMaker_InvalidTimeToExpiration();
        _;
    }

    function initialize(
        IMarket.Config memory _defaultConfig,
        address _priceFeed,
        address _referralStorage,
        address _feeDistributor,
        address _positionManager,
        address _weth,
        address _usdc
    ) external onlyAdmin {
        if (isInitialized) revert MarketMaker_AlreadyInitialized();
        priceFeed = IPriceFeed(_priceFeed);
        referralStorage = IReferralStorage(_referralStorage);
        defaultConfig = _defaultConfig;
        feeDistributor = IFeeDistributor(_feeDistributor);
        positionManager = IPositionManager(_positionManager);
        weth = _weth;
        usdc = _usdc;
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

    function updateTokenAddresses(address _weth, address _usdc) external onlyAdmin {
        weth = _weth;
        usdc = _usdc;
    }

    function updateFeeDistributor(address _feeDistributor) external onlyAdmin {
        feeDistributor = IFeeDistributor(_feeDistributor);
    }

    function updatePositionManager(address _positionManager) external onlyAdmin {
        positionManager = IPositionManager(_positionManager);
    }

    function createNewMarket(
        IVault.VaultConfig calldata _vaultConfig,
        bytes32 _assetId,
        bytes32 _priceId,
        Oracle.Asset calldata _asset
    ) external nonReentrant onlyAdmin validAsset(_asset) validConfig(_vaultConfig) returns (address) {
        if (_assetId == bytes32(0)) revert MarketMaker_InvalidAsset();
        if (_priceId == bytes32(0)) revert MarketMaker_InvalidPriceId();
        if (tokenToMarkets[_assetId] != address(0)) revert MarketMaker_MarketExists();

        // Set Up Price Oracle
        priceFeed.supportAsset(_assetId, _asset);
        // Create new Market contract
        Market market = new Market(_vaultConfig, defaultConfig, _assetId, address(roleStorage));
        // Create new TradeStorage contract
        TradeStorage tradeStorage = new TradeStorage(market, referralStorage, address(roleStorage));
        // Initialize Market with TradeStorage
        market.initialize(tradeStorage);
        // Initialize TradeStorage with Default values
        tradeStorage.initialize(0.05e18, 0.001e18, 2e30, 10);

        // Add to Storage
        bool success = markets.add(address(market));
        if (!success) revert MarketMaker_FailedToAddMarket();
        tokenToMarkets[_assetId] = address(market);

        // Set Up Roles -> Enable Caller to control Market
        roleStorage.setMarketRoles(address(market), Roles.MarketRoles(address(tradeStorage), msg.sender, msg.sender));

        // Fire Event
        emit MarketCreated(address(market), _assetId, _priceId);

        return address(market);
    }

    function addTokenToMarket(
        IMarket market,
        bytes32 _assetId,
        bytes32 _priceId,
        Oracle.Asset memory _asset,
        uint256[] calldata _newAllocations
    ) external onlyAdmin nonReentrant {
        if (_assetId == bytes32(0)) revert MarketMaker_InvalidAsset();
        if (_priceId == bytes32(0)) revert MarketMaker_InvalidPriceId();
        if (_asset.baseUnit != 1e18 && _asset.baseUnit != 1e8 && _asset.baseUnit != 1e6) {
            revert MarketMaker_InvalidBaseUnit();
        }
        if (tokenToMarkets[_assetId] != address(0)) revert MarketMaker_MarketExists();
        if (!markets.contains(address(market))) revert MarketMaker_MarketDoesNotExist();

        // Set Up Price Oracle
        priceFeed.supportAsset(_assetId, _asset);
        // Cache
        address marketAddress = address(market);
        // Add to Storage
        tokenToMarkets[_assetId] = marketAddress;
        // Add to Market
        market.addToken(defaultConfig, _assetId, _newAllocations);

        // Fire Event
        emit TokenAddedToMarket(marketAddress, _assetId, _priceId);
    }

    function getMarkets() external view returns (address[] memory) {
        return markets.values();
    }

    function isMarket(address _market) external view returns (bool) {
        return markets.contains(_market);
    }
}
