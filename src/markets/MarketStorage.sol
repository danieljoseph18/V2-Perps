// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

// Contract stores all data for markets
// need to store the markets themselves
// need to be able to fetch a list of all markets
import {MarketStructs} from "./MarketStructs.sol";
import {RoleValidation} from "../access/RoleValidation.sol";
import {ILiquidityVault} from "./interfaces/ILiquidityVault.sol";
import {IMarket} from "./interfaces/IMarket.sol";

/// @dev Needs MarketStorage Role
contract MarketStorage is RoleValidation {
    using MarketStructs for MarketStructs.Market;
    using MarketStructs for MarketStructs.Position;

    ILiquidityVault public liquidityVault;

    mapping(bytes32 _marketKey => MarketStructs.Market) public markets;
    mapping(bytes32 _marketKey => uint256 _allocation) public marketAllocations;
    mapping(bytes32 _marketKey => uint256 _maxOI) public maxOpenInterests;
    mapping(bytes32 _marketKey => uint256 _openInterest) public collatTokenLongOpenInterest; // OI of collat token long
    mapping(bytes32 _marketKey => uint256 _openInterest) public collatTokenShortOpenInterest;
    mapping(bytes32 _marketKey => uint256 _openInterest) public indexTokenLongOpenInterest; // OI of index token long
    mapping(bytes32 _marketKey => uint256 _openInterest) public indexTokenShortOpenInterest;

    bytes32[] public marketKeys;

    event OpenInterestUpdated(
        bytes32 indexed _marketKey,
        uint256 _collateralTokenAmount,
        uint256 _indexTokenAmount,
        bool _isLong,
        bool _isAddition
    );
    event OverCollateralizationRatioUpdated(uint256 _percentage);
    event MarketStateUpdated(bytes32 indexed _marketKey, uint256 indexed _newAllocation, uint256 _maxOI);

    error MarketStorage_MarketAlreadyExists();
    error MarketStorage_NonExistentMarket();

    /// Note move init number to initialise function
    constructor(address _liquidityVault, address _roleStorage) RoleValidation(_roleStorage) {
        liquidityVault = ILiquidityVault(_liquidityVault);
    }

    /// @dev Only MarketFactory
    function storeMarket(MarketStructs.Market memory _market) external onlyMarketMaker {
        if (markets[_market.marketKey].market != address(0)) revert MarketStorage_MarketAlreadyExists();
        // Store the market in the contract's storage
        marketKeys.push(_market.marketKey);
        markets[_market.marketKey] = _market;
    }

    /// @dev Only Executor
    function updateOpenInterest(
        bytes32 _marketKey,
        uint256 _collateralTokenAmount,
        uint256 _indexTokenAmount,
        bool _isLong,
        bool _shouldAdd
    ) external onlyExecutor {
        if (_shouldAdd) {
            if (_isLong) {
                collatTokenLongOpenInterest[_marketKey] += _collateralTokenAmount;
                indexTokenLongOpenInterest[_marketKey] += _indexTokenAmount;
            } else {
                collatTokenShortOpenInterest[_marketKey] += _collateralTokenAmount;
                indexTokenShortOpenInterest[_marketKey] += _indexTokenAmount;
            }
        } else {
            if (_isLong) {
                collatTokenLongOpenInterest[_marketKey] -= _collateralTokenAmount;
                indexTokenLongOpenInterest[_marketKey] -= _indexTokenAmount;
            } else {
                collatTokenShortOpenInterest[_marketKey] -= _collateralTokenAmount;
                indexTokenShortOpenInterest[_marketKey] -= _indexTokenAmount;
            }
        }
        emit OpenInterestUpdated(_marketKey, _collateralTokenAmount, _indexTokenAmount, _isLong, _shouldAdd);
    }

    function getMarket(bytes32 _key) external view returns (MarketStructs.Market memory) {
        return markets[_key];
    }

    function getMarketFromIndexToken(address _indexToken) external view returns (MarketStructs.Market memory) {
        bytes32 _key = keccak256(abi.encodePacked(_indexToken));
        return markets[_key];
    }

    function getTotalIndexOpenInterest(address _indexToken) external view returns (uint256 _totalOI) {
        bytes32 _key = keccak256(abi.encodePacked(_indexToken));
        return indexTokenLongOpenInterest[_key] + indexTokenShortOpenInterest[_key];
    }
    /// @dev Maximum amount of liquidity allocated to markets

    function updateState(bytes32 _marketKey, uint256 _newAllocation, uint256 _maxOI) external onlyStateUpdater {
        if (markets[_marketKey].market == address(0)) revert MarketStorage_NonExistentMarket();
        if (_newAllocation != 0) {
            marketAllocations[_marketKey] = _newAllocation;
        }
        if (_maxOI != 0) {
            maxOpenInterests[_marketKey] = _maxOI;
        }
        emit MarketStateUpdated(_marketKey, _newAllocation, _maxOI);
    }
}
