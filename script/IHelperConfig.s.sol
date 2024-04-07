// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Oracle} from "../src/oracle/Oracle.sol";

interface IHelperConfig {
    struct NetworkConfig {
        address weth;
        address usdc;
        address link;
        address uniV3SwapRouter;
        address uniV3Factory;
        uint64 subId;
        bytes32 donId;
        address chainlinkRouter;
        bool mockFeed;
        address sequencerUptimeFeed;
    }

    function getActiveNetworkConfig() external view returns (NetworkConfig memory);
}
