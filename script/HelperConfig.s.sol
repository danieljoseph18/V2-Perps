// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Script} from "forge-std/Script.sol";
import {MockUSDC} from "../test/mocks/MockUSDC.sol";
import {IPriceFeed} from "../src/oracle/interfaces/IPriceFeed.sol";
import {WETH} from "../src/tokens/WETH.sol";
import {Oracle} from "../src/oracle/Oracle.sol";
import {IHelperConfig} from "./IHelperConfig.s.sol";

contract HelperConfig is IHelperConfig, Script {
    NetworkConfig private activeNetworkConfig;

    uint256 public constant DEFAULT_ANVIL_PRIVATE_KEY =
        0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    constructor() {
        if (block.chainid == 11155111) {
            activeNetworkConfig = getSepoliaConfig();
        } else if (block.chainid == 8453) {
            activeNetworkConfig = getBaseConfig();
        } else {
            activeNetworkConfig = getOrCreateAnvilConfig();
        }
    }

    function getSepoliaConfig() public returns (NetworkConfig memory sepoliaConfig) {
        // Need to configurate Price Feed for Sepolia and return
        MockUSDC mockUsdc = new MockUSDC();
        WETH weth = new WETH();
        bytes32 ethPriceId = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;
        bytes32 usdcPriceId = 0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a;

        activeNetworkConfig.weth = address(weth);
        activeNetworkConfig.usdc = address(mockUsdc);
        activeNetworkConfig.ethPriceId = ethPriceId;
        activeNetworkConfig.usdcPriceId = usdcPriceId;
        activeNetworkConfig.mockFeed = true;
        activeNetworkConfig.sequencerUptimeFeed = address(0);

        sepoliaConfig = activeNetworkConfig;
    }

    function getActiveNetworkConfig() public view returns (NetworkConfig memory) {
        return activeNetworkConfig;
    }

    function getBaseConfig() public view returns (NetworkConfig memory baseConfig) {
        // Need to configurate Price Feed for Base and return
    }

    function getOrCreateAnvilConfig() public returns (NetworkConfig memory anvilConfig) {
        MockUSDC mockUsdc = new MockUSDC();
        WETH weth = new WETH();
        bytes32 ethPriceId = keccak256(abi.encode("ETH/USD"));
        bytes32 usdcPriceId = keccak256(abi.encode("USDC/USD"));
        // Create a mock price feed and return

        activeNetworkConfig.weth = address(weth);
        activeNetworkConfig.usdc = address(mockUsdc);
        activeNetworkConfig.ethPriceId = ethPriceId;
        activeNetworkConfig.usdcPriceId = usdcPriceId;
        activeNetworkConfig.mockFeed = true;
        activeNetworkConfig.sequencerUptimeFeed = address(0);

        anvilConfig = activeNetworkConfig;
    }
}
