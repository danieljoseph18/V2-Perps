// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IMarketMaker} from "./interfaces/IMarketMaker.sol";
import {RoleValidation} from "../access/RoleValidation.sol";
import {ReentrancyGuard} from "@solmate/utils/ReentrancyGuard.sol";
import {Market, IMarket, IVault} from "./Market.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IPriceFeed} from "../oracle/interfaces/IPriceFeed.sol";
import {Oracle} from "../oracle/Oracle.sol";
import {IPositionManager} from "../router/interfaces/IPositionManager.sol";
import {Roles} from "../access/Roles.sol";

/// @dev Needs MarketMaker Role
contract MarketMaker is IMarketMaker, RoleValidation, ReentrancyGuard {
    using EnumerableSet for EnumerableSet.AddressSet;

    IPriceFeed priceFeed;
    IPositionManager positionManager;

    EnumerableSet.AddressSet private markets;
    // switch to enumerable set? what if a token has 2+ markets?
    mapping(bytes32 assetId => address market) public tokenToMarkets;
    uint256[] private defaultAllocation;

    bool private isInitialised;
    IMarket.Config public defaultConfig;

    constructor(address _roleStorage) RoleValidation(_roleStorage) {
        defaultAllocation.push(10000 << 240);
    }

    function initialise(IMarket.Config memory _defaultConfig, address _priceFeed, address _positionManager)
        external
        onlyAdmin
    {
        if (isInitialised) revert MarketMaker_AlreadyInitialised();
        priceFeed = IPriceFeed(_priceFeed);
        positionManager = IPositionManager(_positionManager);
        defaultConfig = _defaultConfig;
        isInitialised = true;
        emit MarketMakerInitialised(_priceFeed);
    }

    function setDefaultConfig(IMarket.Config memory _defaultConfig) external onlyAdmin {
        defaultConfig = _defaultConfig;
        emit DefaultConfigSet(_defaultConfig);
    }

    function updatePriceFeed(IPriceFeed _priceFeed) external onlyConfigurator {
        priceFeed = _priceFeed;
    }

    function updatepositionManager(IPositionManager _positionManager) external onlyConfigurator {
        positionManager = _positionManager;
    }

    /// @dev Only MarketFactory
    // We need to enable the use of synthetic markets
    // Can use an existing asset vault to attach multiple tokens to it, or
    // create a new asset vault for the token
    // @audit - config vulnerable?
    /// @dev Once a Market is created, for it to be functional, must grant role
    /// "MARKET"
    function createNewMarket(
        IVault.VaultConfig memory _vaultDetails,
        bytes32 _assetId, // use a bytes32 asset id instead???
        bytes32 _priceId,
        Oracle.Asset memory _asset
    ) external nonReentrant onlyAdmin returns (address marketAddress) {
        if (_assetId == bytes32(0)) revert MarketMaker_InvalidAsset();
        if (_priceId == bytes32(0)) revert MarketMaker_InvalidPriceId();
        if (_asset.baseUnit != 1e18 && _asset.baseUnit != 1e8 && _asset.baseUnit != 1e6) {
            revert MarketMaker_InvalidBaseUnit();
        }
        if (tokenToMarkets[_assetId] != address(0)) revert MarketMaker_MarketExists();
        if (_vaultDetails.priceFeed != address(priceFeed)) revert MarketMaker_InvalidPriceFeed();
        if (_vaultDetails.positionManager != address(positionManager)) revert MarketMaker_InvalidPositionManager();

        // Set Up Price Oracle
        priceFeed.supportAsset(_assetId, _asset);
        // Create new Market contract
        Market market = new Market(_vaultDetails, defaultConfig, _assetId, address(roleStorage));
        // Cache
        marketAddress = address(market);
        // Add to Storage
        bool success = markets.add(marketAddress);
        if (!success) revert MarketMaker_FailedToAddMarket();
        tokenToMarkets[_assetId] = marketAddress;

        // Fire Event
        emit MarketCreated(marketAddress, _assetId, _priceId);
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
