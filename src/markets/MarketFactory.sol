// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.21;

// Create new Market.sol contracts, with MarketToken.sol's associated
// Store them in MarketStorage.sol with associated information
// Should just be for making Perp markets, spot should work differently
// Also add the option to delete markets if underperforming
import {IMarketStorage} from "./interfaces/IMarketStorage.sol";
import {Market} from "./Market.sol";
import {MarketStructs} from "./MarketStructs.sol";
import {RoleValidation} from "../access/RoleValidation.sol";
import {IWUSDC} from "../token/interfaces/IWUSDC.sol";
import {IPriceOracle} from "../oracle/interfaces/IPriceOracle.sol";
import {IDataOracle} from "../oracle/interfaces/IDataOracle.sol";

/// @dev Needs MarketMaker role
contract MarketFactory is RoleValidation {
    address public immutable WUSDC;

    address public marketStorage;
    address public dataOracle;
    address public priceOracle;

    event MarketCreated(address indexed indexToken, address indexed market);

    constructor(address _marketStorage, address _wusdc, address _priceOracle, address _dataOracle, address _roleStorage)
        RoleValidation(_roleStorage)
    {
        marketStorage = _marketStorage;
        dataOracle = _dataOracle;
        WUSDC = _wusdc;
        priceOracle = _priceOracle;
    }

    function createMarket(address _indexToken, address _priceFeed, uint256 _baseUnit)
        external
        onlyAdmin
        returns (address)
    {
        // pool cant already exist
        bytes32 _marketKey = keccak256(abi.encodePacked(_indexToken));
        // Set Up Price Oracle
        IPriceOracle(priceOracle).updatePriceSource(_indexToken, _priceFeed);
        // Create new Market contract
        Market market = new Market(
            _indexToken, address(marketStorage), priceOracle, address(dataOracle), WUSDC, address(roleStorage)
        );
        // Initialise With Default Values
        Market(market).initialise(
            0.00000035e18, 1_000_000e18, 0.0000000035e18, -0.0000000035e18, 0.000000035e18, 1, false, 0.0000001e18, 2
        );
        // Store everything in MarketStorage
        MarketStructs.Market memory _marketInfo = MarketStructs.Market(_indexToken, address(market), _marketKey);
        IMarketStorage(marketStorage).storeMarket(_marketInfo);
        IDataOracle(dataOracle).setBaseUnit(_indexToken, _baseUnit);

        emit MarketCreated(_indexToken, address(market));
        return address(market);
    }
}
