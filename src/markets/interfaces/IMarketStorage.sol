// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MarketStructs} from "../MarketStructs.sol";

interface IMarketStorage {
    function storeMarket(MarketStructs.Market memory _market) external;
    function isWhitelistedToken(address _token) external view returns (bool);
    function deleteMarket(bytes32 _key) external;
    function getMarket(bytes32 _key) external view returns (MarketStructs.Market memory);
    function getMarketFromIndexToken(address _indexToken) external view returns (MarketStructs.Market memory);
    function getAllMarkets() external view returns (MarketStructs.Market[] memory);
    function updateOpenInterest(
        bytes32 _key,
        uint256 _collateralTokenAmount,
        uint256 _indexTokenAmount,
        bool _isLong,
        bool _shouldAdd
    ) external;

    function marketKeys() external view returns (bytes32[] memory);
    function marketAllocations(bytes32 _key) external view returns (uint256);
    function markets(bytes32 _key) external view returns (MarketStructs.Market memory);
    function positions(bytes32 _key) external view returns (MarketStructs.Position memory);
    function collatTokenLongOpenInterest(bytes32 _key) external view returns (uint256);
    function collatTokenShortOpenInterest(bytes32 _key) external view returns (uint256);
    function indexTokenLongOpenInterest(bytes32 _key) external view returns (uint256);
    function indexTokenShortOpenInterest(bytes32 _key) external view returns (uint256);
    function updateMarketAllocation(bytes32 _marketKey, uint256 _newAllocation, uint256 _maxOI) external;
    function setIsWhitelisted(address _token, bool _isWhitelisted) external;
    function overCollateralizationRatio() external view returns (uint256);
}
