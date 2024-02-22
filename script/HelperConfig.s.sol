// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {Script} from "forge-std/Script.sol";
import {MockUSDC} from "../test/mocks/MockUSDC.sol";
import {MockPriceFeed} from "../test/mocks/MockPriceFeed.sol";
import {IPriceFeed} from "../src/oracle/interfaces/IPriceFeed.sol";
import {WETH} from "../src/tokens/WETH.sol";
import {Oracle} from "../src/oracle/Oracle.sol";

contract HelperConfig is Script {
    NetworkConfig public activeNetworkConfig;

    struct NetworkConfig {
        IPriceFeed priceFeed;
        address weth;
        address usdc;
        bytes32 ethPriceId;
        bytes32 usdcPriceId;
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
        MockUSDC mockUSDC = new MockUSDC();
        WETH weth = new WETH();
        bytes32 ethPriceId = keccak256(abi.encode("ETH/USD"));
        bytes32 usdcPriceId = keccak256(abi.encode("USDC/USD"));
        // Create a mock price feed and return
        Oracle.Asset memory wethAsset = Oracle.Asset({
            isValid: true,
            chainlinkPriceFeed: address(0),
            priceId: ethPriceId,
            baseUnit: 1e18,
            heartbeatDuration: 1 minutes,
            maxPriceDeviation: 0.01e18,
            priceSpread: 0.1e18,
            priceProvider: Oracle.PriceProvider.PYTH,
            assetType: Oracle.AssetType.CRYPTO
        });
        Oracle.Asset memory usdcAsset = Oracle.Asset({
            isValid: true,
            chainlinkPriceFeed: address(0),
            priceId: usdcPriceId,
            baseUnit: 1e6,
            heartbeatDuration: 1 minutes,
            maxPriceDeviation: 0.01e18,
            priceSpread: 0.1e18,
            priceProvider: Oracle.PriceProvider.PYTH,
            assetType: Oracle.AssetType.CRYPTO
        });
        MockPriceFeed mockPriceFeed = new MockPriceFeed(10, 1, address(weth), address(mockUSDC), wethAsset, usdcAsset);

        anvilConfig = NetworkConfig({
            priceFeed: IPriceFeed(address(mockPriceFeed)),
            weth: address(weth),
            usdc: address(mockUSDC),
            ethPriceId: ethPriceId,
            usdcPriceId: usdcPriceId
        });
    }
}
