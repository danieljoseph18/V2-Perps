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
import {ILiquidityVault} from "../liquidity/interfaces/ILiquidityVault.sol";
import {ReentrancyGuard} from "@solmate/utils/ReentrancyGuard.sol";
import {IDataOracle} from "../oracle/interfaces/IDataOracle.sol";
import {IPriceOracle} from "../oracle/interfaces/IPriceOracle.sol";
import {Funding} from "../libraries/Funding.sol";
import {Borrowing} from "../libraries/Borrowing.sol";
import {Pricing} from "../libraries/Pricing.sol";
import {MarketUtils} from "./MarketUtils.sol";
import {Market, IMarket} from "./Market.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/// @dev Needs MarketMaker Role
contract MarketMaker is IMarketMaker, RoleValidation, ReentrancyGuard {
    using EnumerableSet for EnumerableSet.AddressSet;

    ILiquidityVault liquidityVault;
    IDataOracle dataOracle;
    IPriceOracle priceOracle;

    EnumerableSet.AddressSet private markets;
    mapping(address indexToken => address market) public tokenToMarkets;

    bool private isInitialised;
    MarketConfig public defaultConfig;

    constructor(address _liquidityVault, address _roleStorage) RoleValidation(_roleStorage) {
        liquidityVault = ILiquidityVault(_liquidityVault);
    }

    function initialise(MarketConfig memory _defaultConfig, address _dataOracle, address _priceOracle)
        external
        onlyAdmin
    {
        require(!isInitialised, "MS: Already Initialised");
        dataOracle = IDataOracle(_dataOracle);
        priceOracle = IPriceOracle(_priceOracle);
        defaultConfig = _defaultConfig;
        isInitialised = true;
        emit MarketMakerInitialised(_dataOracle, _priceOracle);
    }

    function setDefaultConfig(MarketConfig memory _defaultConfig) external onlyAdmin {
        defaultConfig = _defaultConfig;
        emit DefaultConfigSet(_defaultConfig);
    }

    /// @dev Only MarketFactory
    // q -> Do we want to use indexToken? This will require a new token for each market
    // We need to enable the use of synthetic markets
    function createNewMarket(address _indexToken, address _priceFeed, uint256 _baseUnit)
        external
        onlyAdmin
        returns (Market market)
    {
        require(_indexToken != address(0) && _priceFeed != address(0), "MM: Invalid Address");
        require(_baseUnit == 1e18 || _baseUnit == 1e8 || _baseUnit == 1e6, "MF: Invalid Base Unit");

        // Check if market already exists
        require(!markets.contains(_indexToken), "MM: Market Exists");

        // Set Up Price Oracle
        priceOracle.updatePriceSource(_indexToken, _priceFeed);

        // Create new Market contract
        market = new Market(priceOracle, dataOracle, _indexToken, address(roleStorage));
        // Initialize
        market.initialise(
            IMarket.Config({
                maxFundingVelocity: 0.00000035e18,
                skewScale: 1_000_000e18,
                maxFundingRate: 0.0000000035e18,
                minFundingRate: -0.0000000035e18,
                borrowingFactor: 0.000000035e18,
                borrowingExponent: 1,
                priceImpactFactor: 0.0000001e18,
                priceImpactExponent: 2,
                maxPnlFactor: 0.45e18,
                targetPnlFactor: 0.2e18,
                feeForSmallerSide: false,
                adlFlaggedLong: false,
                adlFlaggedShort: false
            })
        );
        // Cache
        address marketAddress = address(market);
        // Add to Storage
        markets.add(marketAddress);
        // Fire Event
        emit MarketCreated(marketAddress, _indexToken, _priceFeed);
    }
}
