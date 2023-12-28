// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {Script} from "forge-std/Script.sol";
import {MockUSDC} from "../test/mocks/MockUSDC.sol";
import {MockPriceOracle} from "../test/mocks/MockPriceOracle.sol";

contract HelperConfig is Script {
    NetworkConfig public activeNetworkConfig;

    struct NetworkConfig {
        address priceOracle;
        address usdc;
        uint256 deployerKey;
    }

    uint256 public constant DEFAULT_ANVIL_PRIVATE_KEY =
        0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    constructor() {
        if (block.chainid == 11155111) {
            activeNetworkConfig = getSepoliaConfig();
        } else {
            activeNetworkConfig = getOrCreateAnvilConfig();
        }
    }

    function getSepoliaConfig() public view returns (NetworkConfig memory sepoliaConfig) {
        sepoliaConfig = NetworkConfig({
            priceOracle: 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d,
            usdc: 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d,
            deployerKey: vm.envUint("PRIVATE_KEY")
        });
    }

    function getOrCreateAnvilConfig() public returns (NetworkConfig memory anvilConfig) {
        MockUSDC usdc = new MockUSDC(1_000_000_000000);
        MockPriceOracle priceOracle = new MockPriceOracle();
        anvilConfig = NetworkConfig({
            priceOracle: address(priceOracle),
            usdc: address(usdc),
            deployerKey: DEFAULT_ANVIL_PRIVATE_KEY
        });
    }
}
