// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {IMarket} from "../../markets/interfaces/IMarket.sol";

interface IDataOracle {
    // Function to get net PnL for a specific market

    function getNetPnl(IMarket _market, uint256 _blockNumber) external view returns (int256 netPnl);

    // Function to get cumulative net PnL for all markets
    function getCumulativeNetPnl(uint256 _blockNumber) external view returns (int256 totalPnl);

    // Function to get base units for a token
    function getBaseUnits(address _token) external view returns (uint256);

    // Function to set base units for a token
    function setBaseUnit(address _token, uint256 _baseUnit) external;

    // Function to request data for a block
    function requestBlockData(uint256 _blockNumber) external;

    function blockData(uint256 _blockNumber)
        external
        view
        returns (
            bool isValid,
            uint256 blockNumber,
            uint256 blockTimestamp,
            uint256 cumulativeNetPnl, // Across all markets
            uint256 longMarketTokenPrice,
            uint256 shortMarketTokenPrice
        );

    function LONG_BASE_UNIT() external view returns (uint256);

    function SHORT_BASE_UNIT() external view returns (uint256);
}
