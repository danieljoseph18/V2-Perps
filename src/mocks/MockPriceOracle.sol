// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

contract MockPriceOracle {
    function getPrice() external pure returns (uint256) {
        return 1e18;
    }
}
