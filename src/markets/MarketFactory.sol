// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// Create new Market.sol contracts, with MarketToken.sol's associated
// Store them in MarketStorage.sol with associated information
// Should just be for making Perp markets, spot should work differently
// Also add the option to delete markets if underperforming
import {MarketStorage} from "./MarketStorage.sol";
import {Market} from "./Market.sol";
import {MarketStructs} from "./MarketStructs.sol";
import {ILiquidityVault} from "./interfaces/ILiquidityVault.sol";
import {RoleValidation} from "../access/RoleValidation.sol";

/// @dev Needs MarketMaker role
contract MarketFactory is RoleValidation {
    MarketStorage public marketStorage;
    ILiquidityVault public liquidityVault;

    event MarketCreated(address indexed indexToken, address indexed stablecoin, address market);

    constructor(address _marketStorage, address _liquidityVault) RoleValidation(roleStorage) {
        marketStorage = MarketStorage(_marketStorage);
        liquidityVault = ILiquidityVault(_liquidityVault);
    }

    // Only callable by MARKET_MAKER roles
    function createMarket(address _indexToken, address _stablecoin) public onlyAdmin {
        // long and short tokens cant be same, short must be stables
        require(marketStorage.isStable(_stablecoin), "Short token must be a stable token");
        require(_stablecoin != address(0), "Zero address not allowed");
        require(_indexToken != address(0), "Zero address not allowed");
        // pool cant already exist
        bytes32 _key = keccak256(abi.encodePacked(_indexToken, _stablecoin));
        require(marketStorage.getMarket(_key).market == address(0), "Market already exists");
        // Create new Market contract
        Market _market = new Market(_indexToken, _stablecoin, address(marketStorage), address(liquidityVault));
        // Store everything in MarketStorage
        MarketStructs.Market memory _marketInfo = MarketStructs.Market(_indexToken, _stablecoin, address(_market));
        marketStorage.storeMarket(_marketInfo);
        liquidityVault.addMarket(_marketInfo);

        emit MarketCreated(_indexToken, _stablecoin, address(_market));
    }
}
