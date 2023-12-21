// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.22;

import {MarketStructs} from "../MarketStructs.sol";

interface IMarketStorage {
    function storeMarket(MarketStructs.Market memory _market) external;
    function maxOpenInterests(bytes32 _marketKey) external view returns (uint256);
    function updateOpenInterest(
        bytes32 _marketKey,
        uint256 _collateralTokenAmount,
        uint256 _indexTokenAmount,
        bool _isLong,
        bool _shouldAdd
    ) external;

    function marketKeys() external view returns (bytes32[] memory);
    function marketAllocations(bytes32 _key) external view returns (uint256);
    function markets(bytes32 _key) external view returns (MarketStructs.Market memory);
    function collatTokenLongOpenInterest(bytes32 _key) external view returns (uint256);
    function collatTokenShortOpenInterest(bytes32 _key) external view returns (uint256);
    function indexTokenLongOpenInterest(bytes32 _key) external view returns (uint256);
    function indexTokenShortOpenInterest(bytes32 _key) external view returns (uint256);
    function updateState(bytes32 _marketKey, uint256 _newAllocation, uint256 _maxOI) external;
    function setIsWhitelisted(address _token, bool _isWhitelisted) external;
}
