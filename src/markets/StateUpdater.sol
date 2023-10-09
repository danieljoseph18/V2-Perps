// contract for updating the state of the liquidity vault
// it should calculate the net pnl and net open interest then update the state
// function is separated from the liquidity vault to enable scalability
// when markets get too many, the contract could break as loops would exceed block gas limit

// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {ILiquidityVault} from "./interfaces/ILiquidityVault.sol";
import {RoleValidation} from "../access/RoleValidation.sol";
import {IMarket} from "./interfaces/IMarket.sol";
import {IMarketStorage} from "./interfaces/IMarketStorage.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @dev needs StateUpdater Role
/// Note When arrays are too large, the contract could break as loops would exceed block gas limit
/// When this happens, state is to be updated with use of Off-chain computation or similar
contract StateUpdater is RoleValidation, ReentrancyGuard {

    ILiquidityVault public liquidityVault;
    IMarketStorage public marketStorage;

    constructor (ILiquidityVault _liquidityVault, IMarketStorage _marketStorage) RoleValidation(roleStorage) {
        liquidityVault = _liquidityVault;
        marketStorage = _marketStorage;
    }

    /// @dev Caller needs StateKeeper role
    /// track all markets in a subgraph
    /// perform off-chain computation to total up the net PNL and net open interest of all markets combined
    /// update the state of the liquidity vault with the new values
    function updateState(int256 _netPnL, uint256 _openInterest) external nonReentrant onlyStateKeeper {
        liquidityVault.updateState(_netPnL, _openInterest);
    }

    /// @dev Update the market allocations for an array of markets
    /// Can be called multiple times if becomes to expensive to update all markets at once
    function updateAllocations(bytes32[] memory _marketKeys) external nonReentrant onlyStateKeeper {
        uint256 length = _marketKeys.length;
        for(uint256 i=0; i < length; ++i) {
            marketStorage.updateMarketAllocation(_marketKeys[i]);
        }
    }


}