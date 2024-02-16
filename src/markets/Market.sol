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

import {IMarket} from "./interfaces/IMarket.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {RoleValidation} from "../access/RoleValidation.sol";
import {Funding} from "../libraries/Funding.sol";
import {Borrowing} from "../libraries/Borrowing.sol";
import {Pricing} from "../libraries/Pricing.sol";
import {ReentrancyGuard} from "@solmate/utils/ReentrancyGuard.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {UD60x18, ud, unwrap} from "@prb/math/UD60x18.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {IPriceFeed} from "../oracle/interfaces/IPriceFeed.sol";
import {Oracle} from "../oracle/Oracle.sol";
import {MarketUtils} from "./MarketUtils.sol";
import {ILiquidityVault} from "../liquidity/interfaces/ILiquidityVault.sol";

// @audit - CRITICAL -> Profit needs to be paid from a market's allocation
contract Market is IMarket, ReentrancyGuard, RoleValidation {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using SignedMath for int256;

    uint256 public constant SCALING_FACTOR = 1e18;

    IPriceFeed public priceFeed;
    ILiquidityVault public liquidityVault;

    address public indexToken;

    bool private isInitialised;

    ///////////////////////////////////////////////////////
    // CONFIG: All Constants Used in Market Calculations //
    ///////////////////////////////////////////////////////

    Config private config;

    ///////////////////////////////////////////////////
    // FUNDING: Updateable Funding-Related variables //
    ///////////////////////////////////////////////////

    uint48 public lastFundingUpdate;
    // positive rate = longs pay shorts, negative rate = shorts pay longs
    int256 public fundingRate; // RATE PER SECOND Stored as a fixed-point number 1 = 1e18
    int256 public fundingRateVelocity; // VELOCITY PER SECOND
    uint256 public longCumulativeFundingFees; // how much longs have owed shorts per token, 18 decimals
    uint256 public shortCumulativeFundingFees; // how much shorts have owed longs per token, 18 decimals

    ///////////////////////////////////////////////////////
    // BORROWING: Updateable Borrowing-Related variables //
    ///////////////////////////////////////////////////////

    uint48 public lastBorrowUpdate;
    uint256 public longBorrowingRate; // borrow fee per second for longs per second (0.0001e18 = 0.01%)
    uint256 public longCumulativeBorrowFees;
    uint256 public shortBorrowingRate; // borrow fee per second for shorts per second
    uint256 public shortCumulativeBorrowFees;

    //////////////////////////////////////////////////////
    // OPEN INTEREST: Open Interest Data for the Market //
    //////////////////////////////////////////////////////

    uint256 public longOpenInterest; // in index tokens
    uint256 public shortOpenInterest; // in index tokens

    /////////////////////////////////////////////////////
    // ALLOCATION: For Allocating Liquidity to Markets //
    /////////////////////////////////////////////////////

    // Percentage the same for Long / Short tokens due to goal of balanced markets
    uint256 public percentageAllocation; // 2 D.P: 10000 = 100%

    //////////////////////////////////////////////////
    // PNL: Values for Calculating PNL of Positions //
    //////////////////////////////////////////////////

    uint256 public longTotalWAEP; // long total weighted average entry price
    uint256 public shortTotalWAEP; // short total weighted average entry price
    uint256 public longSizeSumUSD; // Σ All Position Sizes USD Long
    uint256 public shortSizeSumUSD; // Σ All Position Sizes USD Short

    /////////////////////////////////////////////////////////////////
    // Price Impact: Used to calculate the price impact of a trade //
    /////////////////////////////////////////////////////////////////

    // Virtual Pool for Price Impact Calculations
    uint256 public longImpactPoolUsd;
    uint256 public shortImpactPoolUsd;

    constructor(address _priceFeed, address _liquidityVault, address _indexToken, address _roleStorage)
        RoleValidation(_roleStorage)
    {
        indexToken = _indexToken;
        priceFeed = IPriceFeed(_priceFeed);
        liquidityVault = ILiquidityVault(_liquidityVault);
    }

    /// @dev All values need 18 decimals => e.g 0.0003e18 = 0.03%
    /// @dev Can only be called by MarketFactory
    /// @dev Must be Called before contract is interacted with
    function initialise(Config memory _config) external onlyMarketMaker {
        require(!isInitialised, "Market: already initialised");
        config = _config;
        isInitialised = true;
        emit MarketInitialised(_config);
    }

    function updateConfig(Config memory _config) external onlyConfigurator {
        config = _config;
        emit MarketConfigUpdated(_config);
    }

    function updateAdlState(bool _isFlaggedForAdl, bool _isLong) external onlyAdlController {
        _isLong ? config.adl.flaggedLong = _isFlaggedForAdl : config.adl.flaggedShort = _isFlaggedForAdl;
        emit AdlStateUpdated(_isFlaggedForAdl);
    }

    /// @dev Called for every position entry / exit
    // Rate can be lagging if lack of updates to positions
    // @audit -> Should only be called for execution, not requests
    // Pricing data must be accurate
    function updateFundingRate() external nonReentrant {
        // If time elapsed = 0, return
        uint48 lastUpdate = lastFundingUpdate;
        if (block.timestamp == lastUpdate) return;

        // Replace with Funding.calculateDelta
        int256 skew = longOpenInterest.toInt256() - shortOpenInterest.toInt256();

        // Calculate time since last funding update
        uint256 timeElapsed = block.timestamp - lastUpdate;

        // Update Cumulative Fees
        (longCumulativeFundingFees, shortCumulativeFundingFees) = Funding.getTotalAccumulatedFees(this);

        // Add the previous velocity to the funding rate
        int256 deltaRate = fundingRateVelocity * timeElapsed.toInt256();
        // if funding rate addition puts it above / below limit, set to limit
        if (fundingRate + deltaRate >= config.funding.maxRate) {
            fundingRate = config.funding.maxRate;
        } else if (fundingRate + deltaRate <= config.funding.minRate) {
            fundingRate = config.funding.minRate;
        } else {
            fundingRate += deltaRate;
        }

        // Calculate the new velocity
        fundingRateVelocity = Funding.calculateVelocity(this, skew);
        lastFundingUpdate = block.timestamp.toUint48();

        emit FundingUpdated(fundingRate, fundingRateVelocity, longCumulativeFundingFees, shortCumulativeFundingFees);
    }

    // Function to calculate borrowing fees per second
    /*
        borrowing factor * (open interest in usd) ^ (borrowing exponent factor) / (pool usd)
     */
    /// @dev Call every time OI is updated (trade open / close)
    // Needs fix -> Should be for both sides
    function updateBorrowingRate(uint256 _indexPrice, uint256 _longTokenPrice, uint256 _shortTokenPrice, bool _isLong)
        external
        nonReentrant
        onlyTradeStorage
    {
        // If time elapsed = 0, return
        uint256 lastUpdate = lastBorrowUpdate;
        if (block.timestamp == lastUpdate) return;

        uint256 indexBaseUnit = Oracle.getBaseUnit(priceFeed, indexToken);
        uint256 longBaseUnit = Oracle.getLongBaseUnit(priceFeed);
        uint256 shortBaseUnit = Oracle.getShortBaseUnit(priceFeed);

        // Calculate the new Borrowing Rate
        uint256 openInterestUSD = _isLong
            ? MarketUtils.getOpenInterestUsd(this, _indexPrice, indexBaseUnit, true)
            : MarketUtils.getOpenInterestUsd(this, _indexPrice, indexBaseUnit, false);
        uint256 poolBalance = MarketUtils.getTotalPoolBalanceUSD(
            this, liquidityVault, _longTokenPrice, _shortTokenPrice, longBaseUnit, shortBaseUnit
        );

        uint256 rate = unwrap(
            (ud(config.borrowing.factor).mul(ud(openInterestUSD).powu(config.borrowing.exponent))).div(ud(poolBalance))
        );
        // update cumulative fees with current borrowing rate
        if (_isLong) {
            longCumulativeBorrowFees += unwrap(ud(longBorrowingRate).mul(ud(block.timestamp).div(ud(lastBorrowUpdate))));
            longBorrowingRate = rate;
        } else {
            shortCumulativeBorrowFees +=
                unwrap(ud(shortBorrowingRate).mul(ud(block.timestamp).div(ud(lastBorrowUpdate))));
            shortBorrowingRate = rate;
        }
        lastBorrowUpdate = uint48(block.timestamp);
        // update borrowing rate
        emit BorrowingUpdated(_isLong, rate);
    }

    /// @dev Updates Weighted Average Entry Price => Used to Track PNL For a Market
    function updateTotalWAEP(uint256 _price, int256 _sizeDeltaUsd, bool _isLong) external onlyProcessor {
        if (_price == 0) return;
        if (_sizeDeltaUsd == 0) return;
        if (_isLong) {
            longTotalWAEP =
                Pricing.calculateWeightedAverageEntryPrice(longTotalWAEP, longSizeSumUSD, _sizeDeltaUsd, _price);
            _sizeDeltaUsd > 0 ? longSizeSumUSD += _sizeDeltaUsd.abs() : longSizeSumUSD -= _sizeDeltaUsd.abs();
        } else {
            shortTotalWAEP =
                Pricing.calculateWeightedAverageEntryPrice(shortTotalWAEP, shortSizeSumUSD, _sizeDeltaUsd, _price);
            _sizeDeltaUsd > 0 ? shortSizeSumUSD += _sizeDeltaUsd.abs() : shortSizeSumUSD -= _sizeDeltaUsd.abs();
        }
        emit TotalWAEPUpdated(longTotalWAEP, shortTotalWAEP);
    }

    /// @dev Only Order Processor
    function updateOpenInterest(uint256 _indexTokenAmount, bool _isLong, bool _shouldAdd) external onlyProcessor {
        if (_shouldAdd) {
            _isLong ? longOpenInterest += _indexTokenAmount : shortOpenInterest += _indexTokenAmount;
        } else {
            _isLong ? longOpenInterest -= _indexTokenAmount : shortOpenInterest -= _indexTokenAmount;
        }
        emit OpenInterestUpdated(longOpenInterest, shortOpenInterest);
    }

    function updateImpactPool(int256 _priceImpactUsd, bool _isLong) external onlyProcessor {
        uint256 absImpact = _priceImpactUsd.abs();
        if (_isLong) {
            _priceImpactUsd > 0 ? longImpactPoolUsd += absImpact : longImpactPoolUsd -= absImpact;
        } else {
            _priceImpactUsd > 0 ? shortImpactPoolUsd += absImpact : shortImpactPoolUsd -= absImpact;
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
     * @dev -> Need to store allocations for long and shorts
     */
    function updateAllocation(uint256 _percentageAllocation) external onlyStateUpdater {
        percentageAllocation = _percentageAllocation;
        emit AllocationUpdated(address(this), _percentageAllocation);
    }

    /////////////
    // GETTERS //
    /////////////

    function getCumulativeFees()
        external
        view
        returns (
            uint256 _longCumulativeFundingFees,
            uint256 _shortCumulativeFundingFees,
            uint256 _longCumulativeBorrowFees,
            uint256 _shortCumulativeBorrowFees
        )
    {
        return
            (longCumulativeFundingFees, shortCumulativeFundingFees, longCumulativeBorrowFees, shortCumulativeBorrowFees);
    }

    function getConfig() external view returns (Config memory) {
        return config;
    }

    function getBorrowingConfig() external view returns (BorrowingConfig memory) {
        return config.borrowing;
    }

    function getFundingConfig() external view returns (FundingConfig memory) {
        return config.funding;
    }

    function getImpactConfig() external view returns (ImpactConfig memory) {
        return config.impact;
    }

    function getAdlConfig() external view returns (AdlConfig memory) {
        return config.adl;
    }

    function getReserveFactor() external view returns (uint256) {
        return config.reserveFactor;
    }

    function getMaxLeverage() external view returns (uint32) {
        return config.maxLeverage;
    }

    function getMaxPnlFactor() external view returns (uint256) {
        return config.adl.maxPnlFactor;
    }
}
