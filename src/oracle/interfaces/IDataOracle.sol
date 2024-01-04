// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import "../../libraries/Types.sol";

interface IDataOracle {
    // Emitted when markets are set
    event MarketsSet(Types.Market[] markets);

    // Emitted when markets are cleared
    event MarketsCleared();

    // Function to set markets
    function setMarkets(Types.Market[] memory _markets) external;

    // Function to clear markets
    function clearMarkets() external;

    // Function to get net PnL for a specific market
    function getNetPnl(Types.Market memory _market) external view returns (int256);

    // Function to get cumulative net PnL for all markets
    function getCumulativeNetPnl() external view returns (int256 totalPnl);

    // Function to get base units for a token
    function getBaseUnits(address _token) external view returns (uint256);

    // Function to set base units for a token
    function setBaseUnit(address _token, uint256 _baseUnit) external;
}
