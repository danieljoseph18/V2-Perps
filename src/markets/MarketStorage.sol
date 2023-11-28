// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

// Contract stores all data for markets
// need to store the markets themselves
// need to be able to fetch a list of all markets
import {MarketStructs} from "./MarketStructs.sol";
import {RoleValidation} from "../access/RoleValidation.sol";
import {ILiquidityVault} from "./interfaces/ILiquidityVault.sol";
import {IMarket} from "./interfaces/IMarket.sol";
import {UD60x18, ud, unwrap} from "@prb/math/UD60x18.sol";

contract MarketStorage is RoleValidation {
    using MarketStructs for MarketStructs.Market;
    using MarketStructs for MarketStructs.Position;

    ILiquidityVault public liquidityVault;

    mapping(bytes32 _marketKey => MarketStructs.Market) public markets;
    // Need a minimum allocation or users won't be able to trade new markets
    // Or we set allocation based on expected demand before trading commences
    mapping(bytes32 _marketKey => uint256 _allocation) public marketAllocations;
    mapping(bytes32 _marketKey => uint256 _maxOI) public maxOpenInterests;
    mapping(bytes32 _marketKey => uint256 _openInterest) public collatTokenLongOpenInterest; // OI of collat token long
    mapping(bytes32 _marketKey => uint256 _openInterest) public collatTokenShortOpenInterest;
    mapping(bytes32 _marketKey => uint256 _openInterest) public indexTokenLongOpenInterest; // OI of index token long
    mapping(bytes32 _marketKey => uint256 _openInterest) public indexTokenShortOpenInterest;

    bytes32[] public marketKeys;
    uint256 public overCollateralizationRatio;

    event OpenInterestUpdated(
        bytes32 indexed _marketKey,
        uint256 _collateralTokenAmount,
        uint256 _indexTokenAmount,
        bool _isLong,
        bool _isAddition
    );
    event OverCollateralizationRatioUpdated(uint256 _percentage);
    event WhitelistedTokenUpdated(address _token, bool _isWhitelisted);
    event MarketAllocationUpdated(bytes32 indexed _marketKey, uint256 indexed _newAllocation, uint256 _maxOI);

    error MarketStorage_MarketAlreadyExists();
    error MarketStorage_NonExistentMarket();

    /// Note move init number to initialize function
    constructor(ILiquidityVault _liquidityVault) RoleValidation(roleStorage) {
        liquidityVault = _liquidityVault;
    }

    /// @dev 18 Decimals e.g 1.5e18 = 1.5 = 150%
    /// @dev Must be Called before contract is interacted with
    function initialize(uint256 _overCollateralizationRatio) external onlyAdmin {
        overCollateralizationRatio = _overCollateralizationRatio;
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

    /// @dev only GlobalMarketConfig
    function updateOverCollateralizationRatio(uint256 _ratio) external onlyConfigurator {
        overCollateralizationRatio = _ratio;
        emit OverCollateralizationRatioUpdated(_ratio);
    }

    function getMarket(bytes32 _key) external view returns (MarketStructs.Market memory) {
        return markets[_key];
    }

    function getMarketFromIndexToken(address _indexToken) external view returns (MarketStructs.Market memory) {
        bytes32 _key = keccak256(abi.encodePacked(_indexToken));
        return markets[_key];
    }

    /*
        numerator = total OI
        denominator = OI of market minus overcollateralization
        e.g if overCollateralization = 150% / 3/2 => (OI of Market x 2/3) = denominator
        divisor = numerator / denominator (e.g 7 = 1/7 of the AUM)
     */

    /// @dev Update the allocation for a single market
    /// @param _marketKey The key of the market to update
    /// Note Create Vault Updater contract to update the state of the Vault for this function
    /// Review after completion of market params (funding, borrowing, price impact)
    /* 
        Idea: When a user creates a large trade request that will put the market's open interest
        above the total allocation, the allocation should be increased to accomodate for the trade.
        This will enable large trades on newer assets.
        To do this, add a market allocation step in trade requests.
        Market allocation should also include decreasing markets with low liquidity to free up
        resources in other areas.
        This of the allocation system as a resource distribution system, where markets are the
        computers requesting a share of the resources, the liquidity vault is the CPU
        and the allocation is the amount of CPU power allocated to each market.
        Allocation should be a function of market complexity, not just open interest as this
        could be represented by 1 or 2 traders. Other factors such as the number of traders,
        average size of position, recency of trades, average time of trades, average pnl
         should be considered. If a market is losing a lot (PNL heavily skewed negative) it can
         be allocated more resources as this would be more profitable for LPs.
    */
    /// @dev Repeat execution kept separate to future proof against gas constraints
    function updateMarketAllocation(bytes32 _marketKey, uint256 _newAllocation, uint256 _maxOI)
        external
        onlyStateUpdater
    {
        if (markets[_marketKey].market == address(0)) revert MarketStorage_NonExistentMarket();
        marketAllocations[_marketKey] = _newAllocation;
        maxOpenInterests[_marketKey] = _maxOI;
        emit MarketAllocationUpdated(_marketKey, _newAllocation, _maxOI);
    }
}
