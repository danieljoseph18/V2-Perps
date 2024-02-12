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

import {LiquidityVault} from "../liquidity/LiquidityVault.sol";
import {RoleValidation} from "../access/RoleValidation.sol";
import {MarketMaker} from "./MarketMaker.sol";
import {TradeStorage} from "../positions/TradeStorage.sol";
import {ReentrancyGuard} from "@solmate/utils/ReentrancyGuard.sol";

/// @dev needs StateUpdater Role
contract StateUpdater is RoleValidation, ReentrancyGuard {
    LiquidityVault public liquidityVault;
    MarketMaker public marketMaker;
    TradeStorage public tradeStorage;

    constructor(address _liquidityVault, address _marketMaker, address _tradeStorage, address _roleStorage)
        RoleValidation(_roleStorage)
    {
        liquidityVault = LiquidityVault(_liquidityVault);
        marketMaker = MarketMaker(_marketMaker);
        tradeStorage = TradeStorage(_tradeStorage);
    }

    /*
        Allocations virtually have to be centralized or they'll be too inefficient.
        We can pass them as percentages, then calculate accordingly?
        e.g [100,200,300,400] = [10%,20%,30%,40%]
        Then we can calculate the actual amounts to be allocated to each market.

        These calculations will be handled by Chainlink External Adapters.

        Structure TBD.

        Condense into smaller integers to save gas on updates

        We send a transaction to update the Max OIs periodically.
     */
}
