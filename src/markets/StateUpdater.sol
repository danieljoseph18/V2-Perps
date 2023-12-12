// contract for updating the state of the liquidity vault
// it should calculate the net pnl and net open interest then update the state
// function is separated from the liquidity vault to enable scalability
// when markets get too many, the contract could break as loops would exceed block gas limit

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.21;

import {ILiquidityVault} from "./interfaces/ILiquidityVault.sol";
import {RoleValidation} from "../access/RoleValidation.sol";
import {IMarket} from "./interfaces/IMarket.sol";
import {IMarketStorage} from "./interfaces/IMarketStorage.sol";
import {ITradeStorage} from "../positions/interfaces/ITradeStorage.sol";
import {ReentrancyGuard} from "@solmate/utils/ReentrancyGuard.sol";
import {PricingCalculator} from "../positions/PricingCalculator.sol";
import {MarketHelper} from "./MarketHelper.sol";

/// @dev needs StateUpdater Role
contract StateUpdater is RoleValidation, ReentrancyGuard {
    ILiquidityVault public liquidityVault;
    IMarketStorage public marketStorage;
    ITradeStorage public tradeStorage;

    error StateUpdater_AllocationExceedsAvailableLiquidity();

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
    /// @param _indexToken The index token of the market
    /// @param _allocation The amount of liquidity to allocate to the market in WUSDC
    /// @param _maxOI The maximum open interest of the market in index tokens
    function updateState(address _indexToken, uint256 _allocation, uint256 _maxOI)
        external
        nonReentrant
        onlyStateKeeper
    {
        uint256 totalAvailableLiquidity = liquidityVault.getAumInWusdc();
        if (_allocation > totalAvailableLiquidity) revert StateUpdater_AllocationExceedsAvailableLiquidity();
        bytes32 marketKey = MarketHelper.getMarketFromIndexToken(address(marketStorage), _indexToken).marketKey;
        marketStorage.updateState(marketKey, _allocation, _maxOI);
    }
}
