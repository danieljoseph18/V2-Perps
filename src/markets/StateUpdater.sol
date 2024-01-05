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

import {ILiquidityVault} from "./interfaces/ILiquidityVault.sol";
import {RoleValidation} from "../access/RoleValidation.sol";
import {IMarket} from "./interfaces/IMarket.sol";
import {IMarketStorage} from "./interfaces/IMarketStorage.sol";
import {ITradeStorage} from "../positions/interfaces/ITradeStorage.sol";
import {ReentrancyGuard} from "@solmate/utils/ReentrancyGuard.sol";
import {MarketHelper} from "./MarketHelper.sol";

/// @dev needs StateUpdater Role
contract StateUpdater is RoleValidation, ReentrancyGuard {
    ILiquidityVault public liquidityVault;
    IMarketStorage public marketStorage;
    ITradeStorage public tradeStorage;

    constructor(address _liquidityVault, address _marketStorage, address _tradeStorage, address _roleStorage)
        RoleValidation(_roleStorage)
    {
        liquidityVault = ILiquidityVault(_liquidityVault);
        marketStorage = IMarketStorage(_marketStorage);
        tradeStorage = ITradeStorage(_tradeStorage);
    }

    /*
        Off-Chain computation done to:
        1. Allocate Liquidity from the LiquidityVault to a Market
        2. Update the MaxOI of a Market 

        Setting Values to 0 will skip updating them.

        Note we don't want this off chain -> we want 100% decentralized
     */
    /// @param _indexToken The index token of the market
    /// @param _allocation The amount of liquidity to allocate to the market in WUSDC
    /// @param _maxOI The maximum open interest of the market in index tokens
    function updateState(address _indexToken, uint256 _allocation, uint256 _maxOI)
        external
        nonReentrant
        onlyStateKeeper
    {
        uint256 totalAvailableLiquidity = liquidityVault.getAumInWusdc();
        require(_allocation <= totalAvailableLiquidity, "SU: Allocation > Available");
        bytes32 marketKey = MarketHelper.getMarketFromIndexToken(address(marketStorage), _indexToken).marketKey;
        marketStorage.updateState(marketKey, _allocation, _maxOI);
    }
}
