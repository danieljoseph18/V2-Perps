// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MarketStructs} from "../MarketStructs.sol";

interface IMarketStorage {
    function storeMarket(MarketStructs.Market memory _market) external;
    function setIsStable(address _stablecoin, bool _isStable) external;
    function deleteMarket(bytes32 _key) external;
    function getMarket(bytes32 _key) external view returns (MarketStructs.Market memory);
    function getMarketFromIndexToken(address _indexToken, address _stablecoin)
        external
        view
        returns (MarketStructs.Market memory);
    function getAllMarkets() external view returns (MarketStructs.Market[] memory);
    function updateOpenInterest(
        bytes32 _key,
        uint256 _collateralTokenAmount,
        uint256 _indexTokenAmount,
        bool _isLong,
        bool _shouldAdd
    ) external;

    function keys(uint256 index) external view returns (bytes32);
    function markets(bytes32 _key) external view returns (MarketStructs.Market memory);
    function positions(bytes32 _key) external view returns (MarketStructs.Position memory);
    function collatTokenLongOpenInterest(bytes32 _key) external view returns (uint256);
    function collatTokenShortOpenInterest(bytes32 _key) external view returns (uint256);
    function indexTokenLongOpenInterest(bytes32 _key) external view returns (uint256);
    function indexTokenShortOpenInterest(bytes32 _key) external view returns (uint256);
}
