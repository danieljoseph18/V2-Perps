// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "../../markets/MarketStructs.sol";

interface IDataOracle {
    // Emitted when markets are set
    event MarketsSet(MarketStructs.Market[] markets);

    // Emitted when markets are cleared
    event MarketsCleared();

    // Function to set markets
    function setMarkets(MarketStructs.Market[] memory _markets) external;

    // Function to clear markets
    function clearMarkets() external;

    // Function to get net PnL for a specific market
    function getNetPnl(MarketStructs.Market memory _market) external view returns (int256);

    // Function to get cumulative net PnL for all markets
    function getCumulativeNetPnl() external view returns (int256 totalPnl);
}
