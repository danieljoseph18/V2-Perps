// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// Create new Market.sol contracts, with MarketToken.sol's associated
// Store them in MarketStorage.sol with associated information
// Should just be for making Perp markets, spot should work differently
// Also add the option to delete markets if underperforming
import {IMarketStorage} from "./interfaces/IMarketStorage.sol";
import {Market} from "./Market.sol";
import {MarketStructs} from "./MarketStructs.sol";
import {ILiquidityVault} from "./interfaces/ILiquidityVault.sol";
import {RoleValidation} from "../access/RoleValidation.sol";
import {ITradeStorage} from "../positions/interfaces/ITradeStorage.sol";

/// @dev Needs MarketMaker role
contract MarketFactory is RoleValidation {
    IMarketStorage public marketStorage;
    ILiquidityVault public liquidityVault;
    ITradeStorage public tradeStorage;

    event MarketCreated(address indexed indexToken, address indexed stablecoin, address market);

    error MarketFactory_TokenNotWhitelisted();
    error MarketFactory_IncorrectCollateralToken();
    error MarketFactory_MarketAlreadyExists();

    constructor(IMarketStorage _marketStorage, ILiquidityVault _liquidityVault, ITradeStorage _tradeStorage)
        RoleValidation(roleStorage)
    {
        marketStorage = _marketStorage;
        liquidityVault = _liquidityVault;
        tradeStorage = _tradeStorage;
    }

    // Only callable by MARKET_MAKER roles
    function createMarket(address _indexToken, address _collateralToken) external onlyAdmin {
        // long and short tokens cant be same, short must be stables
        if (!marketStorage.isWhitelistedToken(_indexToken)) revert MarketFactory_TokenNotWhitelisted();
        if (_collateralToken != liquidityVault.collateralToken()) revert MarketFactory_IncorrectCollateralToken();

        // pool cant already exist
        bytes32 _marketKey = keccak256(abi.encodePacked(_indexToken, _collateralToken));
        if (marketStorage.getMarket(_marketKey).market != address(0)) revert MarketFactory_MarketAlreadyExists();
        // Create new Market contract
        Market _market = new Market(_indexToken, _collateralToken, marketStorage, liquidityVault, tradeStorage);
        // Initialize With Default Values
        Market(_market).initialize(0.0003e18, 1_000_000e18, 500e18, -500e18, 0.000000035e18, 1, false, 0.000001e18, 1);
        // Store everything in MarketStorage
        MarketStructs.Market memory _marketInfo =
            MarketStructs.Market(_indexToken, _collateralToken, address(_market), _marketKey);
        marketStorage.storeMarket(_marketInfo);
        liquidityVault.addMarket(_marketInfo);

        emit MarketCreated(_indexToken, _collateralToken, address(_market));
    }
}
