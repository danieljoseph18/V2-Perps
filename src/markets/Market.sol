// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IMarketToken} from "./interfaces/IMarketToken.sol";
import {IMarketStorage} from "./interfaces/IMarketStorage.sol";
import {MarketStructs} from "./MarketStructs.sol";
import {ILiquidityVault} from "./interfaces/ILiquidityVault.sol";
import {RoleValidation} from "../access/RoleValidation.sol";
import {ITradeStorage} from "../positions/interfaces/ITradeStorage.sol";
import {FundingCalculator} from "../positions/FundingCalculator.sol";
import {BorrowingCalculator} from "../positions/BorrowingCalculator.sol";
import {PricingCalculator} from "../positions/PricingCalculator.sol";
import {MarketHelper} from "./MarketHelper.sol";
import {IPriceOracle} from "../oracle/interfaces/IPriceOracle.sol";
import {IDataOracle} from "../oracle/interfaces/IDataOracle.sol";
import {IWUSDC} from "../token/interfaces/IWUSDC.sol";

/// funding rate calculation = dr/dt = c * skew (credit to https://sips.synthetix.io/sips/sip-279/)
contract Market is RoleValidation {
    using SafeERC20 for IERC20;
    using MarketStructs for MarketStructs.Market;
    using MarketStructs for MarketStructs.Position;

    int256 public constant MAX_PRICE_IMPACT = 0.33e18; // 33%
    uint256 public constant SCALING_FACTOR = 1e18;

    address public indexToken;
    ILiquidityVault public liquidityVault;
    IMarketStorage public marketStorage;
    ITradeStorage public tradeStorage;
    IPriceOracle public priceOracle;
    IDataOracle public dataOracle;
    IWUSDC public immutable WUSDC;

    bool isInitialised;

    uint256 public lastFundingUpdateTime; // last time funding was updated
    uint256 public lastBorrowUpdateTime; // last time borrowing fee was updated
    // positive rate = longs pay shorts, negative rate = shorts pay longs
    int256 public fundingRate; // RATE PER SECOND Stored as a fixed-point number 1 = 1e18
    int256 public fundingRateVelocity; // VELOCITY PER SECOND
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
    uint256 public longCumulativeBorrowFee;
    uint256 public shortCumulativeBorrowFee;
    uint256 public longBorrowingRate; // borrow fee per second for longs per second (0.0001e18 = 0.01%)
    uint256 public shortBorrowingRate; // borrow fee per second for shorts per second

    uint256 public priceImpactExponent;
    uint256 public priceImpactFactor;

    uint256 public longTotalWAEP; // long total weighted average entry price
    uint256 public shortTotalWAEP; // short total weighted average entry price
    uint256 public longSizeSumUSD; // Used to calculate WAEP
    uint256 public shortSizeSumUSD; // Used to calculate WAEP

    event MarketFundingConfigUpdated(
        uint256 _maxFundingVelocity, uint256 _skewScale, int256 _maxFundingRate, int256 _minFundingRate
    );
    event FundingRateUpdated(int256 _fundingRate, int256 _fundingRateVelocity);
    event BorrowingConfigUpdated(uint256 _borrowingFactor, uint256 _borrowingExponent, bool _feeForSmallerSide);
    event BorrowingRateUpdated(bool _isLong, uint256 _borrowingRate);
    event TotalWAEPUpdated(uint256 _longTotalWAEP, uint256 _shortTotalWAEP);
    event PriceImpactConfigUpdated(uint256 _priceImpactFactor, uint256 _priceImpactExponent);

    error Market_AlreadyInitialised();

    constructor(
        address _indexToken,
        address _marketStorage,
        address _liquidityVault,
        address _tradeStorage,
        address _priceOracle,
        address _dataOracle,
        address _wusdc,
        address _roleStorage
    ) RoleValidation(_roleStorage) {
        indexToken = _indexToken;
        marketStorage = IMarketStorage(_marketStorage);
        liquidityVault = ILiquidityVault(_liquidityVault);
        tradeStorage = ITradeStorage(_tradeStorage);
        priceOracle = IPriceOracle(_priceOracle);
        dataOracle = IDataOracle(_dataOracle);
        WUSDC = IWUSDC(_wusdc);
    }

    /// @dev All values need 18 decimals => e.g 0.0003e18 = 0.03%
    /// @dev Can only be called by MarketFactory
    /// @dev Must be Called before contract is interacted with
    function initialise(
        uint256 _maxFundingVelocity, // 0.0003e18 = 0.03%
        uint256 _skewScale, // 1_000_000e18 Skew scale in USDC (1_000_000)
        int256 _maxFundingRate, // 500e16  5% represented as fixed-point
        int256 _minFundingRate, // -500e16
        uint256 _borrowingFactor, // 0.000000035e18 = 0.0000035% per second
        uint256 _borrowingExponent, // Not 18 decimals => 1:1
        bool _feeForSmallerSide, // Flag for skipping borrowing fee for the smaller side
        uint256 _priceImpactFactor, // 0.000001e18 = 0.0001%
        uint256 _priceImpactExponent // Not 18 decimals => 1:1
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

    /**
     * function getIndexOpenInterestUSD(
     *     address _marketStorage,
     *     address _dataOracle,
     *     address _priceOracle,
     *     address _indexToken,
     *     bool _isLong
     * )
     */

    /// @dev 1 USD = 1e18
    /// Note should be called for every position entry / exit
    function updateFundingRate(int256 _positionSizeUSD, bool _isLong) external onlyExecutor {
        uint256 longOI = MarketHelper.getIndexOpenInterestUSD(
            address(marketStorage), address(dataOracle), address(priceOracle), indexToken, true
        );
        uint256 shortOI = MarketHelper.getIndexOpenInterestUSD(
            address(marketStorage), address(dataOracle), address(priceOracle), indexToken, false
        );
        // If Increase ... Else Decrease
        if (_positionSizeUSD >= 0) {
            _isLong ? longOI += uint256(_positionSizeUSD) : shortOI += uint256(_positionSizeUSD);
        } else {
            _isLong ? longOI -= uint256(-_positionSizeUSD) : shortOI -= uint256(-_positionSizeUSD);
        }
        int256 skew = int256(longOI) - int256(shortOI); // 500 USD skew = 500e30 (USD scaled by 30)

        // Calculate time since last funding update
        uint256 timeElapsed = block.timestamp - lastFundingUpdateTime;

        // Update Cumulative Fees
        if (fundingRate > 0) {
            longCumulativeFundingFees += uint256(fundingRate) * timeElapsed; // if funding rate has 18 decimals, rate per token = rate
        } else if (fundingRate < 0) {
            shortCumulativeFundingFees += (uint256(-fundingRate) * timeElapsed);
        }

        // Add the previous velocity to the funding rate
        int256 deltaRate = fundingRateVelocity * int256(timeElapsed);
        // if funding rate addition puts it above / below limit, set to limit
        if (fundingRate + deltaRate > maxFundingRate) {
            fundingRate = maxFundingRate;
        } else if (fundingRate + deltaRate < minFundingRate) {
            fundingRate = minFundingRate;
        } else {
            fundingRate += deltaRate;
        }

        // Calculate the new velocity
        int256 velocity = FundingCalculator.calculateFundingRateVelocity(address(this), skew); // int scaled by 1e18

        fundingRateVelocity = velocity;
        lastFundingUpdateTime = block.timestamp;
        emit FundingRateUpdated(fundingRate, fundingRateVelocity);
    }

    // Function to calculate borrowing fees per second
    /// @dev uses GMX Synth borrow rate calculation
    /*
        borrowing factor * (open interest in usd) ^ (borrowing exponent factor) / (pool usd)
     */
    /// @dev Call every time OI is updated (trade open / close)
    function updateBorrowingRate(bool _isLong) external onlyExecutor {
        uint256 openInterest = MarketHelper.getIndexOpenInterestUSD(
            address(marketStorage), address(dataOracle), address(priceOracle), indexToken, true
        ); // OI USD
        uint256 poolBalance = MarketHelper.getPoolBalanceUSD(
            address(marketStorage), getMarketKey(), address(priceOracle), address(WUSDC.USDC())
        ); // Pool balance in USD

        uint256 rate = (borrowingFactor * (openInterest ** borrowingExponent)) / poolBalance;
        // update cumulative fees with current borrowing rate
        uint256 borrowingRate;
        if (_isLong) {
            borrowingRate = longBorrowingRate;
            longCumulativeBorrowFee += borrowingRate * (block.timestamp - lastBorrowUpdateTime);
            longBorrowingRate = rate;
        } else {
            borrowingRate = shortBorrowingRate;
            shortCumulativeBorrowFee += borrowingRate * (block.timestamp - lastBorrowUpdateTime);
            shortBorrowingRate = rate;
        }
        // update last update time
        lastBorrowUpdateTime = block.timestamp;
        // update borrowing rate
        emit BorrowingRateUpdated(_isLong, rate);
    }

    /// @dev Updates Weighted Average Entry Price => Used to Track PNL For a Market
    function updateTotalWAEP(uint256 _price, int256 _sizeDeltaUsd, bool _isLong) external onlyExecutor {
        if (_isLong) {
            longTotalWAEP = PricingCalculator.calculateWeightedAverageEntryPrice(
                longTotalWAEP, longSizeSumUSD, _sizeDeltaUsd, _price
            );
            _sizeDeltaUsd > 0 ? longSizeSumUSD += uint256(_sizeDeltaUsd) : longSizeSumUSD -= uint256(-_sizeDeltaUsd);
        } else {
            shortTotalWAEP = PricingCalculator.calculateWeightedAverageEntryPrice(
                shortTotalWAEP, shortSizeSumUSD, _sizeDeltaUsd, _price
            );
            _sizeDeltaUsd > 0 ? shortSizeSumUSD += uint256(_sizeDeltaUsd) : shortSizeSumUSD -= uint256(-_sizeDeltaUsd);
        }
        emit TotalWAEPUpdated(longTotalWAEP, shortTotalWAEP);
    }

    function getMarketParameters() external view returns (uint256, uint256, uint256, uint256) {
        return
            (longCumulativeFundingFees, shortCumulativeFundingFees, longCumulativeBorrowFee, shortCumulativeBorrowFee);
    }

    function getMarketKey() public view returns (bytes32) {
        return keccak256(abi.encodePacked(indexToken));
    }
}
