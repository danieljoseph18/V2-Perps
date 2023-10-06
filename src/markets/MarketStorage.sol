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
    mapping(bytes32 => MarketStructs.Market) public markets;

    // tracked by a bytes 32 key 
    mapping(bytes32 => MarketStructs.Position) public positions;

    // tracks globally allowed stablecoins
    mapping(address => bool) public isStable;

    // maps key of market to open interest
    mapping(bytes32 => uint256) public collatTokenLongOpenInterest; // OI of collat token long
    mapping(bytes32 => uint256) public collatTokenShortOpenInterest;
    mapping(bytes32 => uint256) public indexTokenLongOpenInterest; // OI of index token long
    mapping(bytes32 => uint256) public indexTokenShortOpenInterest;


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
    function setIsStable(address _stablecoin) external onlyConfigurator {
        isStable[_stablecoin] = true;
    }

    // should only be callable by permissioned roles STORAGE_ADMIN
    // adds value in tokens and usd to track Pnl
    // should never be callable by an EOA
    // long + decrease = subtract, short + decrease = add, long + increase = add, short + increase = subtract
    /// @dev Only Executor
    function updateOpenInterest(bytes32 _key, uint256 _collateralTokenAmount, uint256 _indexTokenAmount, bool _isLong, bool _shouldAdd) external onlyExecutor {
        if(_shouldAdd) {
            // add to open interest
            _isLong ? collatTokenLongOpenInterest[_key] += _collateralTokenAmount : collatTokenShortOpenInterest[_key] += _collateralTokenAmount;
            _isLong ? indexTokenLongOpenInterest[_key] += _indexTokenAmount : indexTokenShortOpenInterest[_key] += _indexTokenAmount;
        } else {
            // subtract from open interest
            _isLong ? collatTokenLongOpenInterest[_key] -= _collateralTokenAmount : collatTokenShortOpenInterest[_key] -= _collateralTokenAmount;
            _isLong ? indexTokenLongOpenInterest[_key] -= _indexTokenAmount : indexTokenShortOpenInterest[_key] -= _indexTokenAmount;
        }
    }

    function getMarket(bytes32 _key) external view returns (MarketStructs.Market memory) {
        // Return the information for the market associated with the key
        return markets[_key];
    }

    function getMarketFromIndexToken(address _indexToken, address _stablecoin) external view returns (MarketStructs.Market memory) {
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