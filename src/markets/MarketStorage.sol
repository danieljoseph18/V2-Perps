// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// Contract stores all data for markets
// need to store the markets themselves
// need to be able to fetch a list of all markets
import {MarketStructs} from "./MarketStructs.sol";
import {RoleValidation} from "../access/RoleValidation.sol";
import {ILiquidityVault} from "./interfaces/ILiquidityVault.sol";
import {IMarket} from "./interfaces/IMarket.sol";

contract MarketStorage is RoleValidation {
    using MarketStructs for MarketStructs.Market;
    using MarketStructs for MarketStructs.Position;

    ILiquidityVault public liquidityVault;

    bytes32[] public keys;
    mapping(bytes32 _marketKey => MarketStructs.Market) public markets;

    // reps liquidity allocated to each market in USDC
    // OI is capped to % of allocation
    // whenever a trade is opened, check it won't put the OI over the allocation
    // cap = marketAllocation(market) * 100% / overCollateralizationPercentage
    // Need a minimum allocation or users won't be able to trade new markets
    // Or we set allocation based on expected demand before trading commences
    mapping(bytes32 _marketKey => uint256 _allocation) public marketAllocations;

    // tracked by a bytes 32 key
    mapping(bytes32 _positionKey => MarketStructs.Position) public positions;

    // tracks globally allowed stablecoins
    mapping(address _stablecoin => bool _isWhitelisted) public isStable;

    mapping(bytes32 _marketKey => uint256 _openInterest) public collatTokenLongOpenInterest; // OI of collat token long
    mapping(bytes32 _marketKey => uint256 _openInterest) public collatTokenShortOpenInterest;
    mapping(bytes32 _marketKey => uint256 _openInterest) public indexTokenLongOpenInterest; // OI of index token long
    mapping(bytes32 _marketKey => uint256 _openInterest) public indexTokenShortOpenInterest;

    uint256 public overCollateralizationPercentage; // 150000 = 150% ratio => 1.5x collateral
    uint256 public constant PERCENTAGE_PRECISION = 1e10; // 1e12 = 100%

    constructor(ILiquidityVault _liquidityVault) RoleValidation(roleStorage) {
        liquidityVault = _liquidityVault;
        overCollateralizationPercentage = 15e11; // 150%
    }

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

    /// @dev only GlobalMarketConfig
    function updateOverCollateralizationPercentage(uint256 _percentage) external onlyConfigurator {
        overCollateralizationPercentage = _percentage;
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

    /////////////////
    // ALLOCATIONS //
    /////////////////

    /*
        numerator = total OI
        denominator = OI of market minus overcollateralization
        e.g if overCollateralization = 150% / 3/2 => (OI of Market x 2/3) = denominator
        divisor = numerator / denominator (e.g 7 = 1/7 of the AUM)
     */

    /// @dev Update the allocation for a single market
    /// @param _marketKey The key of the market to update
    /// Note Create Vault Updater contract to update the state of the Vault for this function
    function updateMarketAllocation(bytes32 _marketKey) external onlyStateUpdater {
        require(markets[_marketKey].market != address(0), "Market does not exist");

        uint256 totalOpenInterest = liquidityVault.getNetOpenInterest(); // Total OI across all markets
        uint256 marketOpenInterest = IMarket(markets[_marketKey].market).getTotalOpenInterest(); // OI for this market

        if (totalOpenInterest == 0 || marketOpenInterest == 0) {
            marketAllocations[_marketKey] = 0;
            return;
        }

        uint256 adjustedMarketOI = (marketOpenInterest * PERCENTAGE_PRECISION) / (overCollateralizationPercentage); // Adjust OI based on collateralization

        uint256 percentageAllocation = totalOpenInterest / adjustedMarketOI;

        uint256 newAllocation = liquidityVault.getAum() / percentageAllocation; // Calculate new allocation

        marketAllocations[_marketKey] = newAllocation; // Update mapping
    }
}
