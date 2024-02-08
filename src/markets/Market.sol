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
import {IPriceOracle} from "../oracle/interfaces/IPriceOracle.sol";
import {IDataOracle} from "../oracle/interfaces/IDataOracle.sol";
import {ReentrancyGuard} from "@solmate/utils/ReentrancyGuard.sol";
import {MarketUtils} from "./MarketUtils.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {UD60x18, ud, unwrap} from "@prb/math/UD60x18.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";

// @audit - CRITICAL -> Profit needs to be paid from a market's allocation
contract Market is IMarket, ReentrancyGuard, RoleValidation {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using SignedMath for int256;

    uint256 public constant SCALING_FACTOR = 1e18;

    address public indexToken;
    IPriceOracle priceOracle;
    IDataOracle dataOracle;

    bool private isInitialised;

    ///////////////////////////////////////////////////////
    // CONFIG: All Constants Used in Market Calculations //
    ///////////////////////////////////////////////////////

    uint256 public maxFundingVelocity;
    uint256 public skewScale; // Sensitivity to Market Skew
    int256 public maxFundingRate;
    int256 public minFundingRate;
    uint256 public borrowingFactor;
    uint256 public borrowingExponent;
    uint256 public priceImpactExponent;
    uint256 public priceImpactFactor;
    uint256 public maxPnlFactor;
    uint256 public targetPnlFactor; // PNL Factor to aim for in ADLs
    bool public feeForSmallerSide; // Flag for Skipping Fee for Smaller Side
    bool public adlFlaggedLong; // Flag for ADL Long
    bool public adlFlaggedShort; // Flag for ADL Short

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

    uint256 public longTokenAllocation;
    uint256 public shortTokenAllocation;

    //////////////////////////////////////////////////
    // PNL: Values for Calculating PNL of Positions //
    //////////////////////////////////////////////////

    uint256 public longTotalWAEP; // long total weighted average entry price
    uint256 public shortTotalWAEP; // short total weighted average entry price
    uint256 public longSizeSumUSD; // Σ All Position Sizes USD Long
    uint256 public shortSizeSumUSD; // Σ All Position Sizes USD Short

    constructor(IPriceOracle _priceOracle, IDataOracle _dataOracle, address _indexToken, address _roleStorage)
        RoleValidation(_roleStorage)
    {
        indexToken = _indexToken;
        priceOracle = _priceOracle;
        dataOracle = _dataOracle;
    }

    /// @dev All values need 18 decimals => e.g 0.0003e18 = 0.03%
    /// @dev Can only be called by MarketFactory
    /// @dev Must be Called before contract is interacted with
    function initialise(Config memory _config) external onlyMarketMaker {
        require(!isInitialised, "Market: already initialised");
        maxFundingVelocity = _config.maxFundingVelocity;
        skewScale = _config.skewScale;
        maxFundingRate = _config.maxFundingRate;
        minFundingRate = _config.minFundingRate;
        borrowingFactor = _config.borrowingFactor;
        borrowingExponent = _config.borrowingExponent;
        priceImpactFactor = _config.priceImpactFactor;
        priceImpactExponent = _config.priceImpactExponent;
        maxPnlFactor = _config.maxPnlFactor;
        targetPnlFactor = _config.targetPnlFactor;
        feeForSmallerSide = _config.feeForSmallerSide;
        adlFlaggedLong = _config.adlFlaggedLong;
        adlFlaggedShort = _config.adlFlaggedShort;
        isInitialised = true;
        emit MarketInitialised(
            _config.maxFundingVelocity,
            _config.skewScale,
            _config.maxFundingRate,
            _config.minFundingRate,
            _config.borrowingFactor,
            _config.borrowingExponent,
            _config.feeForSmallerSide,
            _config.priceImpactFactor,
            _config.priceImpactExponent,
            _config.maxPnlFactor,
            _config.targetPnlFactor
        );
    }

    function updateConfig(Config memory _config) external onlyConfigurator {
        maxFundingVelocity = _config.maxFundingVelocity;
        skewScale = _config.skewScale;
        maxFundingRate = _config.maxFundingRate;
        minFundingRate = _config.minFundingRate;
        borrowingFactor = _config.borrowingFactor;
        borrowingExponent = _config.borrowingExponent;
        priceImpactFactor = _config.priceImpactFactor;
        priceImpactExponent = _config.priceImpactExponent;
        maxPnlFactor = _config.maxPnlFactor;
        targetPnlFactor = _config.targetPnlFactor;
        feeForSmallerSide = _config.feeForSmallerSide;
        adlFlaggedLong = _config.adlFlaggedLong;
        adlFlaggedShort = _config.adlFlaggedShort;
        emit MarketConfigUpdated(
            _config.maxFundingVelocity,
            _config.skewScale,
            _config.maxFundingRate,
            _config.minFundingRate,
            _config.borrowingFactor,
            _config.borrowingExponent,
            _config.feeForSmallerSide,
            _config.priceImpactFactor,
            _config.priceImpactExponent,
            _config.maxPnlFactor,
            _config.targetPnlFactor
        );
    }

    function updateAdlState(bool _isFlaggedForAdl, bool _isLong) external onlyAdlController {
        _isLong ? adlFlaggedLong = _isFlaggedForAdl : adlFlaggedShort = _isFlaggedForAdl;
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
        if (fundingRate + deltaRate >= maxFundingRate) {
            fundingRate = maxFundingRate;
        } else if (fundingRate + deltaRate <= minFundingRate) {
            fundingRate = minFundingRate;
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

        uint256 indexBaseUnit = dataOracle.getBaseUnits(indexToken);
        uint256 longBaseUnit = dataOracle.LONG_BASE_UNIT();
        uint256 shortBaseUnit = dataOracle.SHORT_BASE_UNIT();

        // Calculate the new Borrowing Rate
        uint256 openInterestUSD = _isLong
            ? MarketUtils.getLongOpenInterestUSD(this, _indexPrice, indexBaseUnit)
            : MarketUtils.getShortOpenInterestUSD(this, _indexPrice, indexBaseUnit);
        uint256 poolBalance =
            MarketUtils.getPoolBalanceUSD(this, _longTokenPrice, _shortTokenPrice, longBaseUnit, shortBaseUnit);

        uint256 rate =
            unwrap((ud(borrowingFactor).mul(ud(openInterestUSD).powu(borrowingExponent))).div(ud(poolBalance)));
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
    function updateTotalWAEP(uint256 _price, int256 _sizeDeltaUsd, bool _isLong) external onlyExecutor {
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

    /// @dev Only Executor
    function updateOpenInterest(uint256 _indexTokenAmount, bool _isLong, bool _shouldAdd) external onlyExecutor {
        if (_shouldAdd) {
            _isLong ? longOpenInterest += _indexTokenAmount : shortOpenInterest += _indexTokenAmount;
        } else {
            _isLong ? longOpenInterest -= _indexTokenAmount : shortOpenInterest -= _indexTokenAmount;
        }
        emit OpenInterestUpdated(longOpenInterest, shortOpenInterest);
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
    function updateAllocation(uint256 _longTokenAllocation, uint256 _shortTokenAllocation) external onlyStateUpdater {
        longTokenAllocation = _longTokenAllocation;
        shortTokenAllocation = _shortTokenAllocation;
        emit AllocationUpdated(address(this), _longTokenAllocation, _shortTokenAllocation);
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
}
