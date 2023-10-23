// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {MarketStructs} from "../markets/MarketStructs.sol";
import {ITradeStorage} from "./interfaces/ITradeStorage.sol";
import {IMarketStorage} from "../markets/interfaces/IMarketStorage.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {RoleValidation} from "../access/RoleValidation.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {TradeHelper} from "./TradeHelper.sol";

/// @dev Needs Liquidator role
contract Liquidator is RoleValidation {
    using MarketStructs for MarketStructs.Position;
    using SafeCast for int256;

    ITradeStorage public tradeStorage;
    IMarketStorage public marketStorage;

    error Liquidator_PositionNotLiquidatable();

    constructor(ITradeStorage _tradeStorage, IMarketStorage _marketStorage) RoleValidation(roleStorage) {
        tradeStorage = _tradeStorage;
        marketStorage = _marketStorage;
    }

    // need to store who flagged and liquidated
    // let the liquidator claim liquidation rewards from the tradestorage contract
    function liquidatePosition(bytes32 _positionKey) external onlyKeeper {
        // check if position is flagged for liquidation
        tradeStorage.liquidatePosition(_positionKey, msg.sender);
    }

}
