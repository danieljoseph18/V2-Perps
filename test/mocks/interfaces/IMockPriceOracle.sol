// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

interface IMockPriceOracle {
    function getPrice() external pure returns (uint256);
}
