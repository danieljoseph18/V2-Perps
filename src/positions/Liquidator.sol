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
pragma solidity 0.8.21;

import {MarketStructs} from "../markets/MarketStructs.sol";
import {ITradeStorage} from "./interfaces/ITradeStorage.sol";
import {IMarketStorage} from "../markets/interfaces/IMarketStorage.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {RoleValidation} from "../access/RoleValidation.sol";
import {TradeHelper} from "./TradeHelper.sol";

/// @dev Needs Liquidator role
contract Liquidator is RoleValidation {
    using MarketStructs for MarketStructs.Position;

    ITradeStorage public tradeStorage;
    IMarketStorage public marketStorage;

    error Liquidator_PositionNotLiquidatable();

    constructor(address _tradeStorage, address _marketStorage, address _roleStorage) RoleValidation(_roleStorage) {
        tradeStorage = ITradeStorage(_tradeStorage);
        marketStorage = IMarketStorage(_marketStorage);
    }

    // need to store who flagged and liquidated
    // let the liquidator claim liquidation rewards from the tradestorage contract
    function liquidatePosition(bytes32 _positionKey) external onlyKeeper {
        // check if position is flagged for liquidation
        tradeStorage.liquidatePosition(_positionKey, msg.sender);
    }
}
