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

import {RoleValidation} from "../access/RoleValidation.sol";
import {ILiquidityVault} from "../liquidity/interfaces/ILiquidityVault.sol";
import {ReentrancyGuard} from "@solmate/utils/ReentrancyGuard.sol";
import {MarketHelper} from "./MarketHelper.sol";
import {IDataOracle} from "../oracle/interfaces/IDataOracle.sol";
import {IPriceOracle} from "../oracle/interfaces/IPriceOracle.sol";
import {Funding} from "../libraries/Funding.sol";
import {Pricing} from "../libraries/Pricing.sol";
import {Market} from "../structs/Market.sol";

/// @dev Needs MarketMaker Role
contract MarketMaker is RoleValidation, ReentrancyGuard {
    ILiquidityVault liquidityVault;
    IDataOracle public dataOracle;
    IPriceOracle public priceOracle;

    mapping(bytes32 _marketKey => Market.Data) public markets;
    // Do we make this an Enumerable Set?
    bytes32[] public marketKeys;

    bool private isInitialised;

    uint8 constant MAX_RISK_FACTOR = 100;
    uint8 constant MIN_RISK_FACTOR = 1;

    event OpenInterestUpdated(
        bytes32 indexed _marketKey,
        uint256 indexed _collateralTokenAmount,
        uint256 indexed _indexTokenAmount,
        bool _isLong,
        bool _isAddition
    );
    event MarketStateUpdated(bytes32 indexed _marketKey, uint256 indexed _newAllocation, uint256 indexed _maxOI);

    constructor(address _liquidityVault, address _roleStorage) RoleValidation(_roleStorage) {
        liquidityVault = ILiquidityVault(_liquidityVault);
    }

    function initialise(address _dataOracle, address _priceOracle) external onlyAdmin {
        require(!isInitialised, "MS: Already Initialised");
        dataOracle = IDataOracle(_dataOracle);
        priceOracle = IPriceOracle(_priceOracle);
    }

    /// @dev Only MarketFactory
    function createNewMarket(address _indexToken, address _priceFeed, uint8 _riskFactor, uint256 _baseUnit)
        external
        onlyAdmin
        returns (Market.Data memory marketInfo)
    {
        require(_indexToken != address(0) && _priceFeed != address(0), "MF: Zero Address");
        require(_baseUnit == 1e18 || _baseUnit == 1e8 || _baseUnit == 1e6, "MF: Invalid Base Unit");
        require(_riskFactor <= MAX_RISK_FACTOR && _riskFactor >= MIN_RISK_FACTOR, "MF: Invalid Risk Factor");
        // Check if market already exists
        bytes32 marketKey = keccak256(abi.encode(_indexToken));
        require(!markets[marketKey].exists, "MS: Market Exists");
        // Set Up Price Oracle
        priceOracle.updatePriceSource(_indexToken, _priceFeed);
        // Set Up Data Oracle
        dataOracle.setBaseUnit(_indexToken, _baseUnit);
        // Create market and initialise defaults
        uint32 time = uint32(block.timestamp);

        marketInfo = Market.Data({
            exists: true,
            marketKey: marketKey,
            indexToken: _indexToken,
            riskFactor: _riskFactor,
            config: Market.Config({
                maxFundingVelocity: 0.00000035e18,
                skewScale: 1_000_000e18,
                maxFundingRate: 0.0000000035e18,
                minFundingRate: -0.0000000035e18,
                borrowingFactor: 0.000000035e18,
                borrowingExponent: 1,
                feeForSmallerSide: false,
                priceImpactFactor: 0.0000001e18,
                priceImpactExponent: 2
            }),
            funding: Market.Funding({
                lastFundingUpdateTime: time,
                fundingRate: 0,
                fundingRateVelocity: 0,
                longCumulativeFundingFees: 0,
                shortCumulativeFundingFees: 0
            }),
            borrowing: Market.Borrowing({
                lastBorrowUpdateTime: time,
                longCumulativeBorrowFees: 0,
                shortCumulativeBorrowFees: 0,
                longBorrowingRatePerSecond: 0,
                shortBorrowingRatePerSecond: 0
            }),
            pricing: Market.Pricing({
                longTotalWAEP: 0,
                shortTotalWAEP: 0,
                longSizeSumUSD: 0,
                shortSizeSumUSD: 0,
                longOpenInterest: 0,
                shortOpenInterest: 0,
                maxOpenInterestUSD: 0
            })
        });
        marketKeys.push(marketKey);
        markets[marketKey] = marketInfo;
    }

    /////////////
    // Markets //
    /////////////

    /// @dev Only Executor
    function updateOpenInterest(bytes32 _marketKey, uint256 _indexTokenAmount, bool _isLong, bool _shouldAdd)
        external
        onlyExecutor
    {
        require(markets[_marketKey].exists, "MS: Market Doesn't Exist");
        Market.Pricing storage marketPricing = markets[_marketKey].pricing;
        if (_shouldAdd) {
            if (_isLong) {
                marketPricing.longOpenInterest += _indexTokenAmount;
            } else {
                marketPricing.shortOpenInterest += _indexTokenAmount;
            }
        } else {
            if (_isLong) {
                marketPricing.longOpenInterest -= _indexTokenAmount;
            } else {
                marketPricing.shortOpenInterest -= _indexTokenAmount;
            }
        }
    }

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
    ) external onlyConfigurator {
        Market.Config storage marketConfig = markets[_marketKey].config;
        marketConfig.maxFundingVelocity = _maxFundingVelocity;
        marketConfig.skewScale = _skewScale;
        marketConfig.maxFundingRate = _maxFundingRate;
        marketConfig.minFundingRate = _minFundingRate;
        marketConfig.borrowingFactor = _borrowingFactor;
        marketConfig.borrowingExponent = _borrowingExponent;
        marketConfig.feeForSmallerSide = _feeForSmallerSide;
        marketConfig.priceImpactFactor = _priceImpactFactor;
        marketConfig.priceImpactExponent = _priceImpactExponent;
    }

    /// @dev Called for every position entry / exit
    /// Rate can be lagging if lack of updates to positions
    function updateFundingRate(bytes32 _marketKey, address _indexToken) external nonReentrant {
        // If time elapsed = 0, return
        Market.Funding storage marketFunding = markets[_marketKey].funding;
        Market.Config memory marketConfig = markets[_marketKey].config;
        uint32 lastUpdate = marketFunding.lastFundingUpdateTime;
        if (block.timestamp == lastUpdate) return;

        uint256 longOI = MarketHelper.getIndexOpenInterestUSD(
            address(this), address(dataOracle), address(priceOracle), _indexToken, true
        );
        uint256 shortOI = MarketHelper.getIndexOpenInterestUSD(
            address(this), address(dataOracle), address(priceOracle), _indexToken, false
        );

        int256 skew = int256(longOI) - int256(shortOI);

        // Calculate time since last funding update
        uint256 timeElapsed = block.timestamp - lastUpdate;

        // Update Cumulative Fees
        (marketFunding.longCumulativeFundingFees, marketFunding.shortCumulativeFundingFees) =
            Funding.getTotalAccumulatedFees(address(this), _marketKey);

        // Add the previous velocity to the funding rate
        int256 deltaRate = marketFunding.fundingRateVelocity * int256(timeElapsed);
        // if funding rate addition puts it above / below limit, set to limit
        if (marketFunding.fundingRate + deltaRate >= marketConfig.maxFundingRate) {
            marketFunding.fundingRate = marketConfig.maxFundingRate;
        } else if (marketFunding.fundingRate + deltaRate <= marketConfig.minFundingRate) {
            marketFunding.fundingRate = marketConfig.minFundingRate;
        } else {
            marketFunding.fundingRate += deltaRate;
        }

        // Calculate the new velocity
        marketFunding.fundingRateVelocity = Funding.calculateVelocity(address(this), _marketKey, skew);
        marketFunding.lastFundingUpdateTime = uint32(block.timestamp);
    }

    // Function to calculate borrowing fees per second
    /*
        borrowing factor * (open interest in usd) ^ (borrowing exponent factor) / (pool usd)
     */
    /// @dev Call every time OI is updated (trade open / close)
    function updateBorrowingRate(bytes32 _marketKey, address _indexToken, bool _isLong) external nonReentrant {
        Market.Borrowing storage marketBorrowing = markets[_marketKey].borrowing;
        Market.Config memory marketConfig = markets[_marketKey].config;
        // If time elapsed = 0, return
        uint256 lastUpdate = marketBorrowing.lastBorrowUpdateTime;
        if (block.timestamp == lastUpdate) return;

        // Calculate the new Borrowing Rate
        uint256 openInterest = MarketHelper.getIndexOpenInterestUSD(
            address(this), address(dataOracle), address(priceOracle), _indexToken, _isLong
        );
        uint256 poolBalance = MarketHelper.getPoolBalanceUSD(address(this), _marketKey, address(priceOracle));

        uint256 rate = (marketConfig.borrowingFactor * (openInterest ** marketConfig.borrowingExponent)) / poolBalance;

        // update cumulative fees with current borrowing rate
        if (_isLong) {
            marketBorrowing.longCumulativeBorrowFees +=
                (marketBorrowing.longBorrowingRatePerSecond * (block.timestamp - marketBorrowing.lastBorrowUpdateTime));
            marketBorrowing.longBorrowingRatePerSecond = rate;
        } else {
            marketBorrowing.shortCumulativeBorrowFees +=
                (marketBorrowing.shortBorrowingRatePerSecond * (block.timestamp - marketBorrowing.lastBorrowUpdateTime));
            marketBorrowing.shortBorrowingRatePerSecond = rate;
        }
        marketBorrowing.lastBorrowUpdateTime = uint32(block.timestamp);
    }

    /// @dev Updates Weighted Average Entry Price => Used to Track PNL For a Market
    function updateTotalWAEP(bytes32 _marketKey, uint256 _price, int256 _sizeDeltaUsd, bool _isLong)
        external
        onlyExecutor
    {
        if (_price == 0) return;
        if (_sizeDeltaUsd == 0) return;
        Market.Pricing storage marketPricing = markets[_marketKey].pricing;
        if (_isLong) {
            marketPricing.longTotalWAEP = Pricing.calculateWeightedAverageEntryPrice(
                marketPricing.longTotalWAEP, marketPricing.longSizeSumUSD, _sizeDeltaUsd, _price
            );
            _sizeDeltaUsd > 0
                ? marketPricing.longSizeSumUSD += uint256(_sizeDeltaUsd)
                : marketPricing.longSizeSumUSD -= uint256(-_sizeDeltaUsd);
        } else {
            marketPricing.shortTotalWAEP = Pricing.calculateWeightedAverageEntryPrice(
                marketPricing.shortTotalWAEP, marketPricing.shortSizeSumUSD, _sizeDeltaUsd, _price
            );
            _sizeDeltaUsd > 0
                ? marketPricing.shortSizeSumUSD += uint256(_sizeDeltaUsd)
                : marketPricing.shortSizeSumUSD -= uint256(-_sizeDeltaUsd);
        }
    }

    /////////////////
    // Allocations //
    /////////////////

    /**
     * Markets will be allocated liquidity based on risk score + open interest (demand)
     * Higher risk markets will get reduced allocations
     * Markets with higher demand will get higher allocations
     * Allocations will be stored as maxOpenInterestUSD
     * @dev -> Don't use a for loop here.
     */
    function updateAllocations(uint256[] calldata _maxOpenInterestsUsd) external onlyStateUpdater {
        uint256 len = marketKeys.length;
        require(len == _maxOpenInterestsUsd.length, "MS: Invalid Input");
        for (uint256 i = 0; i < len;) {
            bytes32 _key = marketKeys[i];
            markets[_key].pricing.maxOpenInterestUSD = _maxOpenInterestsUsd[i];
            emit MarketStateUpdated(_key, _maxOpenInterestsUsd[i], _maxOpenInterestsUsd[i]);
            unchecked {
                ++i;
            }
        }
    }

    /////////////
    // Getters //
    /////////////

    function getMarketParameters(bytes32 _marketKey)
        external
        view
        returns (
            uint256 longCumulativeFundingFees,
            uint256 shortCumulativeFundingFees,
            uint256 longCumulativeBorrowFees,
            uint256 shortCumulativeBorrowFees
        )
    {
        Market.Data memory market = markets[_marketKey];
        (longCumulativeFundingFees, shortCumulativeFundingFees, longCumulativeBorrowFees, shortCumulativeBorrowFees) = (
            market.funding.longCumulativeFundingFees,
            market.funding.shortCumulativeFundingFees,
            market.borrowing.longCumulativeBorrowFees,
            market.borrowing.shortCumulativeBorrowFees
        );
    }

    function getMarketKey(address _indexToken) public pure returns (bytes32) {
        return keccak256(abi.encode(_indexToken));
    }
}
