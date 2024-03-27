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

        Oracle.Asset memory wethAsset = Oracle.Asset({
            chainlinkPriceFeed: 0x694AA1769357215DE4FAC081bf1f309aDC325306,
            priceId: ethPriceId,
            baseUnit: 1e18,
            heartbeatDuration: 1 minutes,
            maxPriceDeviation: 0.01e18,
            primaryStrategy: Oracle.PrimaryStrategy.PYTH,
            secondaryStrategy: Oracle.SecondaryStrategy.CHAINLINK,
            pool: Oracle.UniswapPool({
                token0: address(weth),
                token1: address(mockUsdc),
                poolAddress: address(0),
                poolType: Oracle.PoolType.V3
            })
        });

        Oracle.Asset memory usdcAsset = Oracle.Asset({
            chainlinkPriceFeed: 0xA2F78ab2355fe2f984D808B5CeE7FD0A93D5270E,
            priceId: usdcPriceId,
            baseUnit: 1e6,
            heartbeatDuration: 1 minutes,
            maxPriceDeviation: 0.01e18,
            primaryStrategy: Oracle.PrimaryStrategy.PYTH,
            secondaryStrategy: Oracle.SecondaryStrategy.CHAINLINK,
            pool: Oracle.UniswapPool({
                token0: address(mockUsdc),
                token1: address(weth),
                poolAddress: address(0),
                poolType: Oracle.PoolType.V3
            })
        });

        activeNetworkConfig.weth = address(weth);
        activeNetworkConfig.usdc = address(mockUsdc);
        activeNetworkConfig.ethPriceId = ethPriceId;
        activeNetworkConfig.usdcPriceId = usdcPriceId;
        activeNetworkConfig.wethAsset = wethAsset;
        activeNetworkConfig.usdcAsset = usdcAsset;
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
        /**
         * [true,0x0000000000000000000000000000000000000000,0xbaf2dfadf73bb5597dae55258a19b57d5117bbb6753b578ae11715c86cfda1ef,1000000000000000000,60,10000000000000000,100000000000000000,0,0,[0x5A86858aA3b595FD6663c2296741eF4cd8BC4d01, 0x93f8dddd876c7dBE3323723500e83E202A7C96CC, 0x0000000000000000000000000000000000000000, 0]]
         * )
         */
        Oracle.Asset memory wethAsset = Oracle.Asset({
            chainlinkPriceFeed: address(0),
            priceId: ethPriceId,
            baseUnit: 1e18,
            heartbeatDuration: 1 minutes,
            maxPriceDeviation: 0.01e18,
            primaryStrategy: Oracle.PrimaryStrategy.PYTH,
            secondaryStrategy: Oracle.SecondaryStrategy.NONE,
            pool: Oracle.UniswapPool({
                token0: address(weth),
                token1: address(mockUsdc),
                poolAddress: address(0),
                poolType: Oracle.PoolType.V3
            })
        });
        /**
         * [true,0x0000000000000000000000000000000000000000,0xcbfe203d5ee402604baaeb548f2857e5556bbaa4ae7c0ccbed0b091f2544dccc,1000000,60,10000000000000000,100000000000000000,0,0,[0x5A86858aA3b595FD6663c2296741eF4cd8BC4d01,0x93f8dddd876c7dBE3323723500e83E202A7C96CC,0x0000000000000000000000000000000000000000,0]]
         */
        Oracle.Asset memory usdcAsset = Oracle.Asset({
            chainlinkPriceFeed: address(0),
            priceId: usdcPriceId,
            baseUnit: 1e6,
            heartbeatDuration: 1 minutes,
            maxPriceDeviation: 0.01e18,
            primaryStrategy: Oracle.PrimaryStrategy.PYTH,
            secondaryStrategy: Oracle.SecondaryStrategy.NONE,
            pool: Oracle.UniswapPool({
                token0: address(mockUsdc),
                token1: address(weth),
                poolAddress: address(0),
                poolType: Oracle.PoolType.V3
            })
        });

        activeNetworkConfig.weth = address(weth);
        activeNetworkConfig.usdc = address(mockUsdc);
        activeNetworkConfig.ethPriceId = ethPriceId;
        activeNetworkConfig.usdcPriceId = usdcPriceId;
        activeNetworkConfig.wethAsset = wethAsset;
        activeNetworkConfig.usdcAsset = usdcAsset;
        activeNetworkConfig.mockFeed = true;
        activeNetworkConfig.sequencerUptimeFeed = address(0);

        anvilConfig = activeNetworkConfig;
    }
}
