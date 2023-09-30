// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// Contract stores all data for markets
// need to store the markets themselves
// need to be able to fetch a list of all markets
import {MarketStructs} from "./MarketStructs.sol";

contract MarketStorage {
    using MarketStructs for MarketStructs.Market;
    using MarketStructs for MarketStructs.Position;


    bytes32[] public keys;
    mapping(bytes32 => MarketStructs.Market) public markets;

    // tracked by a bytes 32 key 
    mapping(bytes32 => MarketStructs.Position) public positions;

    // maps key of market to open interest
    mapping(bytes32 => uint256) public collatTokenLongOpenInterest; // OI of collat token long
    mapping(bytes32 => uint256) public collatTokenShortOpenInterest;
    mapping(bytes32 => uint256) public indexTokenLongOpenInterest; // OI of index token long
    mapping(bytes32 => uint256) public indexTokenShortOpenInterest;


    constructor() {
    }

    // should only be callable by permissioned roles STORAGE_ADMIN
    function storeMarket(MarketStructs.Market memory _market) external {
        bytes32 _key = keccak256(abi.encodePacked(_market.indexToken, _market.stablecoin));
        require(markets[_key].market == address(0), "Market already exists");
        // Store the market in the contract's storage
        keys.push(_key);
        markets[_key] = _market;
    }

    // should only be callable by permissioned roles STORAGE_ADMIN
    // adds value in tokens and usd to track Pnl
    // should never be callable by an EOA
    function addOpenInterest(bytes32 _key, uint256 _collateralTokenAmount, uint256 _indexTokenAmount, bool _isLong) external {
        // add to open interest
        _isLong ? collatTokenLongOpenInterest[_key] += _collateralTokenAmount : collatTokenShortOpenInterest[_key] += _collateralTokenAmount;
        _isLong ? indexTokenLongOpenInterest[_key] += _indexTokenAmount : indexTokenShortOpenInterest[_key] += _indexTokenAmount;
    }

    // should only be callable by permissioned roles STORAGE_ADMIN
    // subtracts value in tokens of collateral (USDC) and index token
    function subtractOpenInterest(bytes32 _key, uint256 _collateralTokenAmount, uint256 _indexTokenAmount, bool _isLong) external {
        // subtract from open interest
        _isLong ? collatTokenLongOpenInterest[_key] -= _collateralTokenAmount : collatTokenShortOpenInterest[_key] -= _collateralTokenAmount;
        _isLong ? indexTokenLongOpenInterest[_key] -= _indexTokenAmount : indexTokenShortOpenInterest[_key] -= _indexTokenAmount;
    }

    function getMarket(bytes32 _key) external view returns (MarketStructs.Market memory) {
        // Return the information for the market associated with the key
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