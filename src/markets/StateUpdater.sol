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
import {ITradeStorage} from "../positions/interfaces/ITradeStorage.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PricingCalculator} from "../positions/PricingCalculator.sol";
import {UD60x18, ud, unwrap} from "@prb/math/UD60x18.sol";
/// @dev needs StateUpdater Role
/// Note When arrays are too large, the contract could break as loops would exceed block gas limit
/// When this happens, state is to be updated with use of Off-chain computation or an alternative solution

contract StateUpdater is RoleValidation, ReentrancyGuard {
    ILiquidityVault public liquidityVault;
    IMarketStorage public marketStorage;
    ITradeStorage public tradeStorage;

    error StateUpdater_AllocationExceedsAum();

    constructor(ILiquidityVault _liquidityVault, IMarketStorage _marketStorage, ITradeStorage _tradeStorage)
        RoleValidation(roleStorage)
    {
        liquidityVault = _liquidityVault;
        marketStorage = _marketStorage;
        tradeStorage = _tradeStorage;
    }

    /// @dev Caller needs StateKeeper role
    /// track all markets in a subgraph
    /// perform off-chain computation to total up the net PNL and net open interest of all markets combined
    /// update the state of the liquidity vault with the new values
    function updateState() external nonReentrant onlyStateKeeper {
        bytes32[] memory _marketKeys = marketStorage.marketKeys();
        uint256 len = _marketKeys.length;
        int256 netPnL;
        uint256 openInterest;
        for (uint256 i = 0; i < len;) {
            address market = marketStorage.getMarket(_marketKeys[i]).market;
            int256 marketPnL = PricingCalculator.getNetPnL(
                market, address(marketStorage), _marketKeys[i], true
            ) + PricingCalculator.getNetPnL(market, address(marketStorage), _marketKeys[i], false);
            netPnL += marketPnL;
            uint256 marketOpenInterest = PricingCalculator.calculateTotalIndexOpenInterestUSD(
                address(marketStorage), market, _marketKeys[i], IMarket(market).indexToken()
            );
            openInterest += marketOpenInterest;
            unchecked {
                ++i;
            }
        }
        liquidityVault.updateState(netPnL, openInterest);
    }

    /// @dev Update the market allocations for an array of markets
    /// Can be called multiple times if becomes to expensive to update all markets at once
    // Get total AUM in liquidity
    // Get total OI across all markets
    // Get OI for individual market
    // calculate percentage of total OI that market represents
    // multiply percentage by AUM to get percentage of tokens to allocate to the market
    // set the max open interest to tokens to allocate / overcollateralization ratio
    function updateAllocations() external nonReentrant onlyStateKeeper {
        bytes32[] memory _marketKeys = marketStorage.marketKeys();
        uint256 len = _marketKeys.length;
        uint256 aum = liquidityVault.poolAmounts(liquidityVault.collateralToken());
        uint256 allocatedAssets;
        uint256 totalOI = liquidityVault.getNetOpenInterest();
        for (uint256 i = 0; i < len;) {
            address market = marketStorage.getMarket(_marketKeys[i]).market;
            uint256 marketOI = PricingCalculator.calculateTotalIndexOpenInterestUSD(
                address(marketStorage), market, _marketKeys[i], IMarket(market).indexToken()
            );
            UD60x18 divisor = ud(marketOI).div(ud(totalOI));
            uint256 allocationInTokens = unwrap(ud(aum).mul(divisor));
            allocatedAssets += allocationInTokens;
            uint256 maxOpenInterest = unwrap(ud(allocationInTokens).div(ud(marketStorage.overCollateralizationRatio())));
            marketStorage.updateMarketAllocation(_marketKeys[i], allocationInTokens, maxOpenInterest);
            unchecked {
                ++i;
            }
        }
        if (allocatedAssets > aum) revert StateUpdater_AllocationExceedsAum();
    }
}
