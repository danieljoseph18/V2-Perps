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
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IMarket} from "./interfaces/IMarket.sol";

/// @dev needs StateUpdater Role
contract StateUpdater is RoleValidation {
    using EnumerableSet for EnumerableSet.AddressSet;

    uint256 public constant BITMASK_16 = type(uint256).max >> (256 - 16);
    uint256 public constant TOTAL_ALLOCATION = 10000;

    IMarket[] private markets;

    constructor(address _roleStorage) RoleValidation(_roleStorage) {}

    function setMarkets(IMarket[] calldata _markets) external onlyAdmin {
        markets = _markets;
    }

    function addMarket(IMarket _market) external onlyAdmin {
        markets.push(_market);
    }

    function removeMarket(IMarket _market, uint256 _index) external onlyAdmin {
        require(markets[_index] == _market, "StateUpdater: Invalid index");
        markets[_index] = markets[markets.length - 1];
        markets.pop();
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
                    markets[allocationIndex].updateAllocation(allocation);
                    ++allocationIndex;
                }
            }
        }

        require(total == TOTAL_ALLOCATION, "StateUpdater: Invalid Cumulative Allocation");
    }

    function getMarkets() external view returns (IMarket[] memory) {
        return markets;
    }
}
