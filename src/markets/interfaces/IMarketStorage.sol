// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IMarketStorage {
    struct Market {
        address indexToken;
        address longToken;
        address shortToken;
        address marketToken;
        address market;
    }

    struct Position {
        bytes32 market;
        address indexToken;
        address user;
        uint256 collateralAmount;
        uint256 indexAmount;
        bool isLong; 
        int256 realisedPnl;
        int256 fundingFees;
        uint256 entryFundingRate;
        uint256 entryTime;
        uint256 entryBlock;
    }

    function storeMarket(Market memory _market) external;
    function deleteMarket(bytes32 _key) external;
    function getMarket(bytes32 _key) external view returns (Market memory);
    function getAllMarkets() external view returns (Market[] memory);
    function addOpenInterest(bytes32 _key, uint256 _size, bool _isLong) external;
    function subtractOpenInterest(bytes32 _key, uint256 _size, bool _isLong) external;

    function keys(uint256 index) external view returns (bytes32);
    function markets(bytes32 _key) external view returns (Market memory);
    function positions(bytes32 _key) external view returns (Position memory);
    function collatTokenLongOpenInterest(bytes32 _key) external view returns (uint256);
    function collatTokenShortOpenInterest(bytes32 _key) external view returns (uint256);
    function indexTokenLongOpenInterest(bytes32 _key) external view returns (uint256);
    function indexTokenShortOpenInterest(bytes32 _key) external view returns (uint256);
}
