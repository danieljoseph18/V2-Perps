// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Oracle} from "../src/oracle/Oracle.sol";

interface IHelperConfig {
    struct NetworkConfig {
        address weth;
        address usdc;
        bytes32 ethPriceId;
        bytes32 usdcPriceId;
        bool mockFeed;
        address sequencerUptimeFeed;
    }

    function getActiveNetworkConfig() external view returns (NetworkConfig memory);
}
