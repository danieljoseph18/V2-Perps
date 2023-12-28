//  ,----,------------------------------,------.
//   | ## |                              |    - |
//   | ## |                              |    - |
//   |    |------------------------------|    - |
//   |    ||............................||      |
//   |    ||,-                        -.||      |
//   |    ||___                      ___||    ##|
//   |    ||---`--------------------'---||      |
//   `--mb'|_|______________________==__|`------'

//    ____  ____  ___ _   _ _____ _____ ____
//   |  _ \|  _ \|_ _| \ | |_   _|___ /|  _ \
//   | |_) | |_) || ||  \| | | |   |_ \| |_) |
//   |  __/|  _ < | || |\  | | |  ___) |  _ <
//   |_|   |_| \_\___|_| \_| |_| |____/|_| \_\

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {MarketStructs} from "./MarketStructs.sol";
import {RoleValidation} from "../access/RoleValidation.sol";
import {ILiquidityVault} from "./interfaces/ILiquidityVault.sol";
import {IMarket} from "./interfaces/IMarket.sol";

/// @dev Needs MarketStorage Role
contract MarketStorage is RoleValidation {
    using MarketStructs for MarketStructs.Market;
    using MarketStructs for MarketStructs.Position;

    ILiquidityVault liquidityVault;

    mapping(bytes32 _marketKey => MarketStructs.Market) public markets;
    mapping(bytes32 _marketKey => uint256 _allocation) public marketAllocations;
    mapping(bytes32 _marketKey => uint256 _maxOI) public maxOpenInterests; // Max OI in Index Tokens
    mapping(bytes32 _marketKey => uint256 _openInterest) public collatTokenLongOpenInterest; // OI of collat token long
    mapping(bytes32 _marketKey => uint256 _openInterest) public collatTokenShortOpenInterest;
    mapping(bytes32 _marketKey => uint256 _openInterest) public indexTokenLongOpenInterest; // OI of index token long
    mapping(bytes32 _marketKey => uint256 _openInterest) public indexTokenShortOpenInterest;

    bytes32[] public marketKeys;

    event OpenInterestUpdated(
        bytes32 indexed _marketKey,
        uint256 indexed _collateralTokenAmount,
        uint256 indexed _indexTokenAmount,
        bool _isLong,
        bool _isAddition
    );
    event MarketStateUpdated(bytes32 indexed _marketKey, uint256 indexed _newAllocation, uint256 indexed _maxOI);

    error MarketStorage_MarketAlreadyExists();
    error MarketStorage_NonExistentMarket();

    constructor(address _liquidityVault, address _roleStorage) RoleValidation(_roleStorage) {
        liquidityVault = ILiquidityVault(_liquidityVault);
    }

    /// @dev Only MarketFactory
    function storeMarket(MarketStructs.Market memory _market) external onlyMarketMaker {
        if (markets[_market.marketKey].market != address(0)) revert MarketStorage_MarketAlreadyExists();
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
        if (markets[_marketKey].market == address(0)) revert MarketStorage_NonExistentMarket();
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

    /// @dev Maximum amount of liquidity allocated to markets
    /// @param _maxOI Max Open Interest in Index Tokens
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
