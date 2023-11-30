// contract for updating the state of the liquidity vault
// it should calculate the net pnl and net open interest then update the state
// function is separated from the liquidity vault to enable scalability
// when markets get too many, the contract could break as loops would exceed block gas limit

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {ILiquidityVault} from "./interfaces/ILiquidityVault.sol";
import {RoleValidation} from "../access/RoleValidation.sol";
import {IMarket} from "./interfaces/IMarket.sol";
import {IMarketStorage} from "./interfaces/IMarketStorage.sol";
import {ITradeStorage} from "../positions/interfaces/ITradeStorage.sol";
import {ReentrancyGuard} from "@solmate/utils/ReentrancyGuard.sol";
import {PricingCalculator} from "../positions/PricingCalculator.sol";

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
     */
    function updateState(address _indexToken, uint256 _allocation, uint256 _maxOI)
        external
        nonReentrant
        onlyStateKeeper
    {
        bytes32 marketKey = marketStorage.getMarketFromIndexToken(_indexToken).marketKey;
        marketStorage.updateState(marketKey, _allocation, _maxOI);
    }
}
