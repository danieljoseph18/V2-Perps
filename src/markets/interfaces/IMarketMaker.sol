// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {Market} from "../../structs/Market.sol";

interface IMarketMaker {
    function storeMarket(Market.Data memory _market) external;
    function maxOpenInterests(bytes32 _marketKey) external view returns (uint256);
    function updateOpenInterest(
        bytes32 _marketKey,
        uint256 _collateralTokenAmount,
        uint256 _indexTokenAmount,
        bool _isLong,
        bool _shouldAdd
    ) external;
    function initialise(address _dataOracle, address _priceOracle) external;
    function marketKeys() external view returns (bytes32[] memory);
    function marketAllocations(bytes32 _key) external view returns (uint256);
    function markets(bytes32 _key) external view returns (Market.Data memory);
    function collatTokenLongOpenInterest(bytes32 _key) external view returns (uint256);
    function collatTokenShortOpenInterest(bytes32 _key) external view returns (uint256);
    function indexTokenLongOpenInterest(bytes32 _key) external view returns (uint256);
    function indexTokenShortOpenInterest(bytes32 _key) external view returns (uint256);
    function setIsWhitelisted(address _token, bool _isWhitelisted) external;
    function setMarketConfig(
        bytes32 _marketKey,
        uint256 _maxFundingVelocity,
        uint256 _skewScale,
        int256 _maxFundingRate,
        int256 _minFundingRate,
        uint256 _borrowingFactor,
        uint256 _borrowingExponent,
        bool _feeForSmallerSide,
        uint256 _priceImpactFactor,
        uint256 _priceImpactExponent
    ) external;
    function updateFundingRate(bytes32 _marketKey) external;
    function updateBorrowingRate(bytes32 _marketKey, bool _isLong) external;
    function updateTotalWAEP(bytes32 _marketKey, uint256 _price, int256 _sizeDeltaUsd, bool _isLong) external;
    function getMarketParameters(bytes32 _marketKey) external view returns (uint256, uint256, uint256, uint256);
    function getMarketKey() external view returns (bytes32);
    function updateAllocations(uint256[] calldata _maxOpenInterestsUsd) external;
    function createNewMarket(address _indexToken, uint8 _riskScore) external returns (Market.Data memory marketInfo);
}
