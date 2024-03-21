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
import {Roles} from "../access/Roles.sol";

/// @dev Needs MarketMaker Role
contract MarketMaker is IMarketMaker, RoleValidation, ReentrancyGuard {
    using EnumerableSet for EnumerableSet.AddressSet;

    IPriceFeed priceFeed;
    IReferralStorage referralStorage;

    EnumerableSet.AddressSet private markets;
    // switch to enumerable set? what if a token has 2+ markets?
    mapping(bytes32 assetId => address market) public tokenToMarkets;
    uint256[] private defaultAllocation;

    bool private isInitialized;
    IMarket.Config public defaultConfig;

    constructor(address _roleStorage) RoleValidation(_roleStorage) {
        defaultAllocation.push(10000 << 240);
    }

    function initialize(IMarket.Config memory _defaultConfig, address _priceFeed, address _referralStorage)
        external
        onlyAdmin
    {
        if (isInitialized) revert MarketMaker_AlreadyInitialized();
        priceFeed = IPriceFeed(_priceFeed);
        referralStorage = IReferralStorage(_referralStorage);
        defaultConfig = _defaultConfig;
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

    /// @dev Only MarketFactory
    // We need to enable the use of synthetic markets
    // Can use an existing asset vault to attach multiple tokens to it, or
    // create a new asset vault for the token
    // @audit - config vulnerable?
    /// @dev Once a Market is created, for it to be functional, must grant role
    /// "MARKET"
    /// Need to grant roles to TradeStorage too
    /**
     * New structure is going to deploy an instance of TradeStorage with each market.
     * This will allow for a more scalable model.
     * To do this we need to:
     * - Make permissions more specific -> OnlyTradeStorage won't do with this model
     * - Deploy a TradeStorage contract in this function alongisde each market.
     * - Immutably store the TradeStorage contract within the market, so they're hard-linked.
     *
     * - Should also probably deploy a separate ReferralStorage for each market too?
     *
     * - add a flag for single asset markets to limit them to just 1 market. Only privileged roles
     * should be able to launch multi asset markets
     */
    /**
     * MarketMaker role should grant the contract permission to provide the roles:
     * - Market
     * - TradeStorage
     */
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

        // Set Up Price Oracle
        priceFeed.supportAsset(_assetId, _asset);
        // Create new Market contract
        Market market = new Market(_vaultDetails, defaultConfig, _assetId, address(roleStorage));
        // Create new TradeStorage contract
        TradeStorage tradeStorage = new TradeStorage(market, referralStorage, address(roleStorage));
        // Initialize Market with TradeStorage
        market.initialize(tradeStorage);
        // Initialize TradeStorage with Default values
        tradeStorage.initialize(0.05e18, 0.001e18, 2e30, 10);
        // Cache
        marketAddress = address(market);
        // Add to Storage
        bool success = markets.add(marketAddress);
        if (!success) revert MarketMaker_FailedToAddMarket();
        tokenToMarkets[_assetId] = marketAddress;

        // Set Up Roles -> Enable Caller to control Market
        roleStorage.setMarketRoles(marketAddress, Roles.MarketRoles(address(tradeStorage), msg.sender, msg.sender));

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
