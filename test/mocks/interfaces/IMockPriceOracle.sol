// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

interface IMockPriceOracle {
    function getPrice() external pure returns (uint256);
}
