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

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IMarketToken} from "./interfaces/IMarketToken.sol";
import {IMarketStorage} from "./interfaces/IMarketStorage.sol";
import {RoleValidation} from "../access/RoleValidation.sol";
import {Funding} from "../libraries/Funding.sol";
import {Borrowing} from "../libraries/Borrowing.sol";
import {Pricing} from "../libraries/Pricing.sol";
import {MarketHelper} from "./MarketHelper.sol";
import {IPriceOracle} from "../oracle/interfaces/IPriceOracle.sol";
import {IDataOracle} from "../oracle/interfaces/IDataOracle.sol";
import {IWUSDC} from "../token/interfaces/IWUSDC.sol";
import {ReentrancyGuard} from "@solmate/utils/ReentrancyGuard.sol";

/// funding rate calculation = dr/dt = c * skew (credit to https://sips.synthetix.io/sips/sip-279/)
contract Market is ReentrancyGuard, RoleValidation {
    using SafeERC20 for IERC20;

    uint256 public constant SCALING_FACTOR = 1e18;

    address public indexToken;
    IMarketStorage public marketStorage;
    IPriceOracle public priceOracle;
    IDataOracle public dataOracle;
    IWUSDC public immutable WUSDC;

    bool private isInitialised;

    uint32 public lastFundingUpdateTime; // last time funding was updated
    uint32 public lastBorrowUpdateTime; // last time borrowing fee was updated
    // positive rate = longs pay shorts, negative rate = shorts pay longs
    int256 public fundingRate; // RATE PER SECOND Stored as a fixed-point number 1 = 1e18
    int256 public fundingRateVelocity; // VELOCITY PER SECOND
    // Determines sensitivity to market skew -> Higher Value = Less Sensitive
    uint256 public skewScale;
    uint256 public maxFundingVelocity;
    int256 public maxFundingRate;
    int256 public minFundingRate;

    uint256 public longCumulativeFundingFees; // how much longs have owed shorts per token, 18 decimals
    uint256 public shortCumulativeFundingFees; // how much shorts have owed longs per token, 18 decimals

    uint256 public borrowingFactor;
    uint256 public borrowingExponent;
    // Flag for skipping borrowing fee for the smaller side
    bool public feeForSmallerSide;
    uint256 public longCumulativeBorrowFees;
    uint256 public shortCumulativeBorrowFees;
    uint256 public longBorrowingRatePerSecond; // borrow fee per second for longs per second (0.0001e18 = 0.01%)
    uint256 public shortBorrowingRatePerSecond; // borrow fee per second for shorts per second

    uint256 public priceImpactExponent;
    uint256 public priceImpactFactor;

    uint256 public longTotalWAEP; // long total weighted average entry price
    uint256 public shortTotalWAEP; // short total weighted average entry price
    uint256 public longSizeSumUSD; // Σ All Position Sizes USD Long
    uint256 public shortSizeSumUSD; // Σ All Position Sizes USD Short

    event MarketFundingConfigUpdated(
        uint256 indexed _maxFundingVelocity, uint256 indexed _skewScale, int256 _maxFundingRate, int256 _minFundingRate
    );
    event FundingConfigUpdated(
        int256 indexed _fundingRate,
        int256 indexed _fundingRateVelocity,
        uint256 _longCumulativeFundingFees,
        uint256 _shortCumulativeFundingFees
    );
    event BorrowingConfigUpdated(
        uint256 indexed _borrowingFactor, uint256 indexed _borrowingExponent, bool indexed _feeForSmallerSide
    );
    event BorrowingRateUpdated(bool indexed _isLong, uint256 indexed _borrowingRate);
    event TotalWAEPUpdated(uint256 indexed _longTotalWAEP, uint256 indexed _shortTotalWAEP);
    event PriceImpactConfigUpdated(uint256 indexed _priceImpactFactor, uint256 indexed _priceImpactExponent);
    event MarketInitialized(
        uint256 _maxFundingVelocity,
        uint256 indexed _skewScale,
        int256 _maxFundingRate,
        int256 _minFundingRate,
        uint256 indexed _borrowingFactor,
        uint256 _borrowingExponent,
        bool _feeForSmallerSide,
        uint256 indexed _priceImpactFactor,
        uint256 _priceImpactExponent
    );

    error Market_AlreadyInitialised();

    constructor(
        address _indexToken,
        address _marketStorage,
        address _priceOracle,
        address _dataOracle,
        address _wusdc,
        address _roleStorage
    ) RoleValidation(_roleStorage) {
        indexToken = _indexToken;
        marketStorage = IMarketStorage(_marketStorage);
        priceOracle = IPriceOracle(_priceOracle);
        dataOracle = IDataOracle(_dataOracle);
        WUSDC = IWUSDC(_wusdc);
    }

    /// @dev All values need 18 decimals => e.g 0.0003e18 = 0.03%
    /// @dev Can only be called by MarketFactory
    /// @dev Must be Called before contract is interacted with
    function initialise(
        uint256 _maxFundingVelocity,
        uint256 _skewScale,
        int256 _maxFundingRate,
        int256 _minFundingRate,
        uint256 _borrowingFactor,
        uint256 _borrowingExponent, // Integer e.g 1
        bool _feeForSmallerSide, // Flag for Skipping Fee for Smaller Side
        uint256 _priceImpactFactor,
        uint256 _priceImpactExponent // Integer e.g 2
    ) external onlyMarketMaker {
        if (isInitialised) revert Market_AlreadyInitialised();
        maxFundingVelocity = _maxFundingVelocity;
        skewScale = _skewScale;
        maxFundingRate = _maxFundingRate;
        minFundingRate = _minFundingRate;
        borrowingFactor = _borrowingFactor;
        borrowingExponent = _borrowingExponent;
        feeForSmallerSide = _feeForSmallerSide;
        priceImpactFactor = _priceImpactFactor;
        priceImpactExponent = _priceImpactExponent;
        isInitialised = true;
        emit MarketInitialized(
            _maxFundingVelocity,
            _skewScale,
            _maxFundingRate,
            _minFundingRate,
            _borrowingFactor,
            _borrowingExponent,
            _feeForSmallerSide,
            _priceImpactFactor,
            _priceImpactExponent
        );
    }

    // Function to update borrowing parameters (consider appropriate access control)
    /// @dev Only GlobalMarketConfig
    function setBorrowingConfig(uint256 _borrowingFactor, uint256 _borrowingExponent, bool _feeForSmallerSide)
        external
        onlyConfigurator
    {
        borrowingFactor = _borrowingFactor;
        borrowingExponent = _borrowingExponent;
        feeForSmallerSide = _feeForSmallerSide;
        emit BorrowingConfigUpdated(_borrowingFactor, _borrowingExponent, _feeForSmallerSide);
    }

    /// @dev Only GlobalMarketConfig
    function setFundingConfig(
        uint256 _maxFundingVelocity,
        uint256 _skewScale,
        int256 _maxFundingRate,
        int256 _minFundingRate
    ) external onlyConfigurator {
        maxFundingVelocity = _maxFundingVelocity;
        skewScale = _skewScale;
        maxFundingRate = _maxFundingRate;
        minFundingRate = _minFundingRate;
        emit MarketFundingConfigUpdated(_maxFundingVelocity, _skewScale, _maxFundingRate, _minFundingRate);
    }

    /// @dev Only GlobalMarketConfig
    function setPriceImpactConfig(uint256 _priceImpactFactor, uint256 _priceImpactExponent) external onlyConfigurator {
        priceImpactFactor = _priceImpactFactor;
        priceImpactExponent = _priceImpactExponent;
        emit PriceImpactConfigUpdated(_priceImpactFactor, _priceImpactExponent);
    }

    /// @dev Called for every position entry / exit
    /// Rate can be lagging if lack of updates to positions
    function updateFundingRate() external nonReentrant {
        // If time elapsed = 0, return
        uint32 lastUpdate = lastFundingUpdateTime;
        if (block.timestamp == lastUpdate) return;

        uint256 longOI = MarketHelper.getIndexOpenInterestUSD(
            address(marketStorage), address(dataOracle), address(priceOracle), indexToken, true
        );
        uint256 shortOI = MarketHelper.getIndexOpenInterestUSD(
            address(marketStorage), address(dataOracle), address(priceOracle), indexToken, false
        );

        int256 skew = int256(longOI) - int256(shortOI);

        // Calculate time since last funding update
        uint256 timeElapsed = block.timestamp - lastUpdate;

        // Update Cumulative Fees
        (longCumulativeFundingFees, shortCumulativeFundingFees) = Funding.getTotalAccumulatedFees(address(this));

        // Add the previous velocity to the funding rate
        int256 deltaRate = fundingRateVelocity * int256(timeElapsed);
        // if funding rate addition puts it above / below limit, set to limit
        if (fundingRate + deltaRate >= maxFundingRate) {
            fundingRate = maxFundingRate;
        } else if (fundingRate + deltaRate <= minFundingRate) {
            fundingRate = minFundingRate;
        } else {
            fundingRate += deltaRate;
        }

        // Calculate the new velocity
        fundingRateVelocity = Funding.calculateVelocity(address(this), skew);
        lastFundingUpdateTime = uint32(block.timestamp);

        emit FundingConfigUpdated(
            fundingRate, fundingRateVelocity, longCumulativeFundingFees, shortCumulativeFundingFees
        );
    }

    // Function to calculate borrowing fees per second
    /*
        borrowing factor * (open interest in usd) ^ (borrowing exponent factor) / (pool usd)
     */
    /// @dev Call every time OI is updated (trade open / close)
    function updateBorrowingRate(bool _isLong) external nonReentrant {
        // If time elapsed = 0, return
        uint256 lastUpdate = lastBorrowUpdateTime;
        if (block.timestamp == lastUpdate) return;

        // Calculate the new Borrowing Rate
        uint256 openInterest = MarketHelper.getIndexOpenInterestUSD(
            address(marketStorage), address(dataOracle), address(priceOracle), indexToken, _isLong
        );
        uint256 poolBalance =
            MarketHelper.getPoolBalanceUSD(address(marketStorage), getMarketKey(), address(priceOracle));

        uint256 rate = (borrowingFactor * (openInterest ** borrowingExponent)) / poolBalance;

        // update cumulative fees with current borrowing rate
        if (_isLong) {
            longCumulativeBorrowFees += (longBorrowingRatePerSecond * (block.timestamp - lastBorrowUpdateTime));
            longBorrowingRatePerSecond = rate;
        } else {
            shortCumulativeBorrowFees += (shortBorrowingRatePerSecond * (block.timestamp - lastBorrowUpdateTime));
            shortBorrowingRatePerSecond = rate;
        }
        lastBorrowUpdateTime = uint32(block.timestamp);
        // update borrowing rate
        emit BorrowingRateUpdated(_isLong, rate);
    }

    /// @dev Updates Weighted Average Entry Price => Used to Track PNL For a Market
    function updateTotalWAEP(uint256 _price, int256 _sizeDeltaUsd, bool _isLong) external onlyExecutor {
        if (_price == 0) return;
        if (_sizeDeltaUsd == 0) return;
        if (_isLong) {
            longTotalWAEP =
                Pricing.calculateWeightedAverageEntryPrice(longTotalWAEP, longSizeSumUSD, _sizeDeltaUsd, _price);
            _sizeDeltaUsd > 0 ? longSizeSumUSD += uint256(_sizeDeltaUsd) : longSizeSumUSD -= uint256(-_sizeDeltaUsd);
        } else {
            shortTotalWAEP =
                Pricing.calculateWeightedAverageEntryPrice(shortTotalWAEP, shortSizeSumUSD, _sizeDeltaUsd, _price);
            _sizeDeltaUsd > 0 ? shortSizeSumUSD += uint256(_sizeDeltaUsd) : shortSizeSumUSD -= uint256(-_sizeDeltaUsd);
        }
        emit TotalWAEPUpdated(longTotalWAEP, shortTotalWAEP);
    }

    function getMarketParameters() external view returns (uint256, uint256, uint256, uint256) {
        return
            (longCumulativeFundingFees, shortCumulativeFundingFees, longCumulativeBorrowFees, shortCumulativeBorrowFees);
    }

    function getMarketKey() public view returns (bytes32) {
        return keccak256(abi.encode(indexToken));
    }
}
