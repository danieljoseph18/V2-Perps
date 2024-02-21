//  ,----,------------------------------,------.
//   | ## |                              |    - |
//   | ## |                              |    - |
//   |    |------------------------------|    - |
//   |    ||............................||      |
//   |    ||,-                        -.||      |
//   |    ||___                      ___||    ##|
//   |    ||---`--------------------'---||      |
//   `--mb'|_|______________________==__|`------'

//    ____  ____  ___ _   _ _____ _____ ____
//   |  _ \|  _ \|_ _| \ | |_   _|___ /|  _ \
//   | |_) | |_) || ||  \| | | |   |_ \| |_) |
//   |  __/|  _ < | || |\  | | |  ___) |  _ <
//   |_|   |_| \_\___|_| \_| |_| |____/|_| \_\

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {IMarketMaker} from "./interfaces/IMarketMaker.sol";
import {RoleValidation} from "../access/RoleValidation.sol";
import {ReentrancyGuard} from "@solmate/utils/ReentrancyGuard.sol";
import {Funding} from "../libraries/Funding.sol";
import {Borrowing} from "../libraries/Borrowing.sol";
import {Pricing} from "../libraries/Pricing.sol";
import {MarketUtils} from "./MarketUtils.sol";
import {Market} from "./Market.sol";
import {IMarket} from "./interfaces/IMarket.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IPriceFeed} from "../oracle/interfaces/IPriceFeed.sol";
import {Oracle} from "../oracle/Oracle.sol";

/// @dev Needs MarketMaker Role
contract MarketMaker is IMarketMaker, RoleValidation, ReentrancyGuard {
    using EnumerableSet for EnumerableSet.AddressSet;

    IPriceFeed priceFeed;
    address liquidityVault;

    EnumerableSet.AddressSet private markets;
    mapping(address indexToken => address market) public tokenToMarkets;

    bool private isInitialised;
    IMarket.Config public defaultConfig;

    constructor(address _roleStorage) RoleValidation(_roleStorage) {}

    function initialise(IMarket.Config memory _defaultConfig, address _priceFeed, address _liquidityVault)
        external
        onlyAdmin
    {
        require(!isInitialised, "MarketMaker: Already Initialised");
        priceFeed = IPriceFeed(_priceFeed);
        liquidityVault = _liquidityVault;
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

    /// @dev Only MarketFactory
    // q -> Do we want to use indexToken? This will require a new token for each market
    // We need to enable the use of synthetic markets
    function createNewMarket(address _indexToken, bytes32 _priceId, Oracle.Asset memory _asset)
        external
        onlyAdmin
        returns (address marketAddress)
    {
        require(_indexToken != address(0), "MarketMaker: Invalid Address");
        require(_priceId != bytes32(0), "MarketMaker: Invalid Price Id");
        require(
            _asset.baseUnit == 1e18 || _asset.baseUnit == 1e8 || _asset.baseUnit == 1e6,
            "MarketMaker: Invalid Base Unit"
        );
        // Check if market already exists
        require(!markets.contains(_indexToken), "MarketMaker: Market Exists");

        // Set Up Price Oracle
        priceFeed.supportAsset(_indexToken, _asset);
        // Create new Market contract
        Market market = new Market(liquidityVault, _indexToken, address(roleStorage));
        // Initialize
        market.initialise(defaultConfig);
        // Cache
        marketAddress = address(market);
        // Add to Storage
        markets.add(marketAddress);
        tokenToMarkets[_indexToken] = marketAddress;
        // Fire Event
        emit MarketCreated(marketAddress, _indexToken, _priceId);
    }
}
