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

import {RoleValidation} from "../access/RoleValidation.sol";
import {IMarket} from "./interfaces/IMarket.sol";
import {IMarketMaker} from "./interfaces/IMarketMaker.sol";

/// @dev needs StateUpdater Role
contract StateUpdater is RoleValidation {
    uint256 public constant BITMASK_16 = type(uint256).max >> (256 - 16);
    uint256 public constant TOTAL_ALLOCATION = 10000;

    IMarketMaker public marketMaker;

    address[] public markets;

    constructor(IMarketMaker _marketMaker, address _roleStorage) RoleValidation(_roleStorage) {
        marketMaker = _marketMaker;
    }

    function syncMarkets() external onlyAdmin {
        // fetch the markets from marketMaker
        // update the markets array
        markets = marketMaker.getMarkets();
    }

    // Each allocation is a number between 0 and 10000 -> can fit in 16 bits
    // We can fit 16 allocations in a single uint256
    // len must == len of markets
    // order must == order of markets
    // pass in the allocations as bits
    // majority of validation will be done off-chain
    // simply need to update the computed values on-chain
    // @audit - test with max length (10,000)
    function setAllocationsWithBits(uint256[] calldata _allocations) external onlyStateKeeper {
        uint256 marketLen = markets.length;

        uint256 total = 0;
        uint256 allocationIndex = 0;

        for (uint256 i = 0; i < _allocations.length; ++i) {
            for (uint256 bitIndex = 0; bitIndex < 16; ++bitIndex) {
                if (allocationIndex >= marketLen) {
                    break;
                }

                // Calculate the bit position for the current allocation
                uint256 startBit = 240 - (bitIndex * 16);
                uint256 allocation = (_allocations[i] >> startBit) & BITMASK_16;
                total += allocation;

                // Ensure that the allocationIndex does not exceed the bounds of the markets array
                if (allocationIndex < markets.length) {
                    IMarket(markets[allocationIndex]).updateAllocation(allocation);
                    ++allocationIndex;
                }
            }
        }

        require(total == TOTAL_ALLOCATION, "StateUpdater: Invalid Cumulative Allocation");
    }
}
