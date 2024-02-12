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
import {LiquidityVault} from "../liquidity/LiquidityVault.sol";
import {ReentrancyGuard} from "@solmate/utils/ReentrancyGuard.sol";
import {Funding} from "../libraries/Funding.sol";
import {Borrowing} from "../libraries/Borrowing.sol";
import {Pricing} from "../libraries/Pricing.sol";
import {MarketUtils} from "./MarketUtils.sol";
import {Market} from "./Market.sol";
import {IMarket} from "./interfaces/IMarket.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {PriceFeed} from "../oracle/PriceFeed.sol";
import {Oracle} from "../oracle/Oracle.sol";

/// @dev Needs MarketMaker Role
contract MarketMaker is IMarketMaker, RoleValidation, ReentrancyGuard {
    using EnumerableSet for EnumerableSet.AddressSet;

    LiquidityVault liquidityVault;
    PriceFeed priceFeed;

    EnumerableSet.AddressSet private markets;
    mapping(address indexToken => address market) public tokenToMarkets;

    bool private isInitialised;
    IMarket.Config public defaultConfig;

    constructor(address _liquidityVault, address _roleStorage) RoleValidation(_roleStorage) {
        liquidityVault = LiquidityVault(_liquidityVault);
    }

    function initialise(IMarket.Config memory _defaultConfig, address _priceFeed) external onlyAdmin {
        require(!isInitialised, "MS: Already Initialised");
        priceFeed = PriceFeed(_priceFeed);
        defaultConfig = _defaultConfig;
        isInitialised = true;
        emit MarketMakerInitialised(_priceFeed);
    }

    function setDefaultConfig(IMarket.Config memory _defaultConfig) external onlyAdmin {
        defaultConfig = _defaultConfig;
        emit DefaultConfigSet(_defaultConfig);
    }

    /// @dev Only MarketFactory
    // q -> Do we want to use indexToken? This will require a new token for each market
    // We need to enable the use of synthetic markets
    function createNewMarket(address _indexToken, bytes32 _priceId, uint256 _baseUnit, Oracle.Asset memory _asset)
        external
        onlyAdmin
        returns (Market market)
    {
        require(_indexToken != address(0), "MM: Invalid Address");
        require(_priceId != bytes32(0), "MM: Invalid Price Id");
        require(_baseUnit == 1e18 || _baseUnit == 1e8 || _baseUnit == 1e6, "MF: Invalid Base Unit");
        // Check if market already exists
        require(!markets.contains(_indexToken), "MM: Market Exists");

        // Set Up Price Oracle
        priceFeed.supportAsset(_indexToken, _asset);
        // Create new Market contract
        market = new Market(priceFeed, _indexToken, address(roleStorage));
        // Initialize
        market.initialise(defaultConfig);
        // Cache
        address marketAddress = address(market);
        // Add to Storage
        markets.add(marketAddress);
        // Fire Event
        emit MarketCreated(marketAddress, _indexToken, _priceId);
    }
}
