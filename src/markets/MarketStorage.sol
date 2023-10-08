// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// Contract stores all data for markets
// need to store the markets themselves
// need to be able to fetch a list of all markets
import {MarketStructs} from "./MarketStructs.sol";
import {RoleValidation} from "../access/RoleValidation.sol";

contract MarketStorage is RoleValidation {
    using MarketStructs for MarketStructs.Market;
    using MarketStructs for MarketStructs.Position;

    bytes32[] public keys;
    mapping(bytes32 _marketKey => MarketStructs.Market) public markets;

    // tracked by a bytes 32 key
    mapping(bytes32 _positionKey => MarketStructs.Position) public positions;

    // tracks globally allowed stablecoins
    mapping(address _stablecoin => bool _isWhitelisted) public isStable;

    mapping(bytes32 _marketKey => uint256 _openInterest) public collatTokenLongOpenInterest; // OI of collat token long
    mapping(bytes32 _marketKey => uint256 _openInterest) public collatTokenShortOpenInterest;
    mapping(bytes32 _marketKey => uint256 _openInterest) public indexTokenLongOpenInterest; // OI of index token long
    mapping(bytes32 _marketKey => uint256 _openInterest) public indexTokenShortOpenInterest;

    constructor() RoleValidation(roleStorage) {}

    /// @dev Only MarketFactory
    function storeMarket(MarketStructs.Market memory _market) external onlyMarketMaker {
        bytes32 _key = keccak256(abi.encodePacked(_market.indexToken, _market.stablecoin));
        require(markets[_key].market == address(0), "Market already exists");
        // Store the market in the contract's storage
        keys.push(_key);
        markets[_key] = _market;
    }

    /// @dev Only GlobalMarketConfig
    function setIsStable(address _stablecoin, bool _isStable) external onlyConfigurator {
        isStable[_stablecoin] = _isStable;
    }

    // should only be callable by permissioned roles STORAGE_ADMIN
    // adds value in tokens and usd to track Pnl
    // should never be callable by an EOA
    // long + decrease = subtract, short + decrease = add, long + increase = add, short + increase = subtract
    // Tracks total open interest across all markets ??????????????????????????
    /// @dev Only Executor
    function updateOpenInterest(
        bytes32 _marketKey,
        uint256 _collateralTokenAmount,
        uint256 _indexTokenAmount,
        bool _isLong,
        bool _shouldAdd
    ) external onlyExecutor {
        if (_shouldAdd) {
            // add to open interest
            _isLong
                ? collatTokenLongOpenInterest[_marketKey] += _collateralTokenAmount
                : collatTokenShortOpenInterest[_marketKey] += _collateralTokenAmount;
            _isLong
                ? indexTokenLongOpenInterest[_marketKey] += _indexTokenAmount
                : indexTokenShortOpenInterest[_marketKey] += _indexTokenAmount;
        } else {
            // subtract from open interest
            _isLong
                ? collatTokenLongOpenInterest[_marketKey] -= _collateralTokenAmount
                : collatTokenShortOpenInterest[_marketKey] -= _collateralTokenAmount;
            _isLong
                ? indexTokenLongOpenInterest[_marketKey] -= _indexTokenAmount
                : indexTokenShortOpenInterest[_marketKey] -= _indexTokenAmount;
        }
    }

    function getMarket(bytes32 _key) external view returns (MarketStructs.Market memory) {
        // Return the information for the market associated with the key
        return markets[_key];
    }

    function getMarketFromIndexToken(address _indexToken, address _stablecoin)
        external
        view
        returns (MarketStructs.Market memory)
    {
        bytes32 _key = keccak256(abi.encodePacked(_indexToken, _stablecoin));
        return markets[_key];
    }

    function getAllMarkets() external view returns (MarketStructs.Market[] memory) {
        // Return all markets
        MarketStructs.Market[] memory _markets = new MarketStructs.Market[](keys.length);
        for (uint256 i = 0; i < keys.length; i++) {
            _markets[i] = markets[keys[i]];
        }
        return _markets;
    }
}
