// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {Script} from "forge-std/Script.sol";
import {MockUSDC} from "../test/mocks/MockUSDC.sol";
import {MockPriceFeed} from "../test/mocks/MockPriceFeed.sol";
import {IPriceFeed} from "../src/oracle/interfaces/IPriceFeed.sol";
import {WETH} from "../src/tokens/WETH.sol";

contract HelperConfig is Script {
    NetworkConfig public activeNetworkConfig;

    struct NetworkConfig {
        IPriceFeed priceFeed;
        address weth;
        address usdc;
    }

    uint256 public constant DEFAULT_ANVIL_PRIVATE_KEY =
        0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    constructor() {
        if (block.chainid == 84532) {
            activeNetworkConfig = getBaseSepoliaConfig();
        } else if (block.chainid == 8453) {
            activeNetworkConfig = getBaseConfig();
        } else {
            activeNetworkConfig = getOrCreateAnvilConfig();
        }
    }

    function getBaseSepoliaConfig() public view returns (NetworkConfig memory sepoliaConfig) {
        // Need to configurate Price Feed for Sepolia and return
    }

    function getBaseConfig() public view returns (NetworkConfig memory baseConfig) {
        // Need to configurate Price Feed for Base and return
    }

    function getOrCreateAnvilConfig() public returns (NetworkConfig memory anvilConfig) {
        // Create a mock price feed and return
        MockPriceFeed mockPriceFeed = new MockPriceFeed(10, 1);
        MockUSDC mockUSDC = new MockUSDC();
        WETH weth = new WETH();

        anvilConfig =
            NetworkConfig({priceFeed: IPriceFeed(address(mockPriceFeed)), weth: address(weth), usdc: address(mockUSDC)});
    }
}
