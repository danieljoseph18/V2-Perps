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

// Create new Market.sol contracts, with MarketToken.sol's associated
// Store them in MarketStorage.sol with associated information
// Should just be for making Perp markets, spot should work differently
// Also add the option to delete markets if underperforming
import {IMarketStorage} from "./interfaces/IMarketStorage.sol";
import {Market} from "./Market.sol";
import {RoleValidation} from "../access/RoleValidation.sol";
import {IPriceOracle} from "../oracle/interfaces/IPriceOracle.sol";
import {IDataOracle} from "../oracle/interfaces/IDataOracle.sol";
import {Types} from "../libraries/Types.sol";

/// @dev Needs MarketMaker role
contract MarketFactory is RoleValidation {
    address public marketStorage;
    address public dataOracle;
    address public priceOracle;

    event MarketCreated(address indexed indexToken, address indexed market);

    constructor(address _marketStorage, address _priceOracle, address _dataOracle, address _roleStorage)
        RoleValidation(_roleStorage)
    {
        marketStorage = _marketStorage;
        dataOracle = _dataOracle;
        priceOracle = _priceOracle;
    }

    /// @param _baseUnit 1 single unit of token -> 1e18 = 18 decimal places
    function createMarket(address _indexToken, address _priceFeed, uint256 _baseUnit)
        external
        onlyAdmin
        returns (Types.Market memory marketInfo)
    {
        require(_indexToken != address(0) && _priceFeed != address(0), "MF: Zero Address");
        require(_baseUnit == 1e18 || _baseUnit == 1e8 || _baseUnit == 1e6, "MF: Invalid Base Unit");

        // Check if market already exists
        bytes32 marketKey = keccak256(abi.encode(_indexToken));
        require(!IMarketStorage(marketStorage).markets(marketKey).exists, "MF: Market Exists");

        // Set Up Price Oracle
        IPriceOracle(priceOracle).updatePriceSource(_indexToken, _priceFeed);

        // Create new Market contract
        Market market =
            new Market(_indexToken, address(marketStorage), priceOracle, address(dataOracle), address(roleStorage));

        // Initialise With Default Values
        Market(market).initialise(
            0.00000035e18, 1_000_000e18, 0.0000000035e18, -0.0000000035e18, 0.000000035e18, 1, false, 0.0000001e18, 2
        );

        // Store everything in MarketStorage
        marketInfo = Types.Market(true, _indexToken, address(market), marketKey);
        IMarketStorage(marketStorage).storeMarket(marketInfo);
        IDataOracle(dataOracle).setBaseUnit(_indexToken, _baseUnit);

        emit MarketCreated(_indexToken, address(market));
    }
}
