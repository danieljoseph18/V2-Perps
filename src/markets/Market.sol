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
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SD59x18, sd, unwrap, pow} from "@prb/math/SD59x18.sol";
import {UD60x18, ud, unwrap} from "@prb/math/UD60x18.sol";
import {FundingCalculator} from "../positions/FundingCalculator.sol";
import {BorrowingCalculator} from "../positions/BorrowingCalculator.sol";
import {PricingCalculator} from "../positions/PricingCalculator.sol";
import {IPriceOracle} from "../oracle/interfaces/IPriceOracle.sol";
import {IWUSDC} from "../token/interfaces/IWUSDC.sol";

/// funding rate calculation = dr/dt = c * skew (credit to https://sips.synthetix.io/sips/sip-279/)
contract Market is RoleValidation {
    using SafeERC20 for IERC20;
    using MarketStructs for MarketStructs.Market;
    using MarketStructs for MarketStructs.Position;
    using SafeCast for uint256;
    using SafeCast for int256;

    int256 public constant MAX_PRICE_IMPACT = 33e18; // 33%

    address public indexToken;
    ILiquidityVault public liquidityVault;
    IMarketStorage public marketStorage;
    ITradeStorage public tradeStorage;
    IPriceOracle public priceOracle;
    IWUSDC public immutable WUSDC;

    bool isInitialized;

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

    error Market_AlreadyInitialized();

    constructor(
        address _indexToken,
        IMarketStorage _marketStorage,
        ILiquidityVault _liquidityVault,
        ITradeStorage _tradeStorage,
        IPriceOracle _priceOracle,
        IWUSDC _wusdc
    ) RoleValidation(roleStorage) {
        indexToken = _indexToken;
        marketStorage = _marketStorage;
        liquidityVault = _liquidityVault;
        tradeStorage = _tradeStorage;
        priceOracle = _priceOracle;
        WUSDC = _wusdc;
    }

    /// @dev All values need 18 decimals => e.g 0.0003e18 = 0.03%
    /// @dev Can only be called by MarketFactory
    /// @dev Must be Called before contract is interacted with
    function initialize(
        uint256 _maxFundingVelocity, // 0.0003e18 = 0.03%
        uint256 _skewScale, // 1_000_000e18 Skew scale in USDC (1_000_000)
        int256 _maxFundingRate, // 500e18  5% represented as fixed-point
        int256 _minFundingRate, // -500e18
        uint256 _borrowingFactor, // 0.000000035e18 = 0.0000035% per second
        uint256 _borrowingExponent, // Not 18 decimals => 1:1
        bool _feeForSmallerSide, // Flag for skipping borrowing fee for the smaller side
        uint256 _priceImpactFactor, // 0.000001e18 = 0.0001%
        uint256 _priceImpactExponent // Not 18 decimals => 1:1
    ) external onlyMarketMaker {
        if (isInitialized) revert Market_AlreadyInitialized();
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

    /// @dev 1 USD = 1e18
    /// Note should be called for every position entry / exit
    function updateFundingRate(int256 _positionSizeUSD, bool _isLong) external onlyExecutor {
        uint256 longOI = PricingCalculator.calculateIndexOpenInterestUSD(
            address(marketStorage), address(this), getMarketKey(), indexToken, true
        );
        uint256 shortOI = PricingCalculator.calculateIndexOpenInterestUSD(
            address(marketStorage), address(this), getMarketKey(), indexToken, false
        );
        // If Increase ... Else Decrease
        if (_positionSizeUSD >= 0) {
            _isLong ? longOI += _positionSizeUSD.toUint256() : shortOI += _positionSizeUSD.toUint256();
        } else {
            _isLong ? longOI -= (-_positionSizeUSD).toUint256() : shortOI -= (-_positionSizeUSD).toUint256();
        }
        int256 skew = unwrap(sd(longOI.toInt256()) - sd(shortOI.toInt256())); // 500 USD skew = 500e18

        // Calculate time since last funding update
        uint256 timeElapsed = block.timestamp - lastFundingUpdateTime;

        // Update Cumulative Fees
        if (fundingRate > 0) {
            longCumulativeFundingFees += (fundingRate.toUint256() * timeElapsed); // if funding rate has 18 decimals, rate per token = rate
        } else if (fundingRate < 0) {
            shortCumulativeFundingFees += ((-fundingRate).toUint256() * timeElapsed);
        }

        // Add the previous velocity to the funding rate
        int256 deltaRate = unwrap((sd(fundingRateVelocity)).mul(sd(timeElapsed.toInt256())));
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
        uint256 openInterest = PricingCalculator.calculateIndexOpenInterestUSD(
            address(marketStorage), address(this), getMarketKey(), indexToken, _isLong
        ); // OI USD
        uint256 poolBalance = PricingCalculator.getPoolBalanceUSD(
            address(liquidityVault), getMarketKey(), address(priceOracle), address(WUSDC.USDC())
        ); // Pool balance in USD

        UD60x18 feeBase = ud(openInterest);
        UD60x18 rate = (ud(borrowingFactor).mul(ud(unwrap(feeBase)).pow(ud(borrowingExponent)))).div(ud(poolBalance));

        // update cumulative fees with current borrowing rate
        uint256 borrowingRate;
        if (_isLong) {
            borrowingRate = longBorrowingRate;
            longCumulativeBorrowFee += borrowingRate * (block.timestamp - lastBorrowUpdateTime);
            longBorrowingRate = unwrap(rate);
        } else {
            borrowingRate = shortBorrowingRate;
            shortCumulativeBorrowFee += borrowingRate * (block.timestamp - lastBorrowUpdateTime);
            shortBorrowingRate = unwrap(rate);
        }
        // update last update time
        lastBorrowUpdateTime = block.timestamp;
        // update borrowing rate
        emit BorrowingRateUpdated(_isLong, unwrap(rate));
    }

    // check this is updated correctly in the executor
    /// @dev Updates Weighted Average Entry Price => Used to Track PNL For a Market
    function updateTotalWAEP(uint256 _price, int256 _sizeDeltaUsd, bool _isLong) external onlyExecutor {
        if (_isLong) {
            longTotalWAEP = PricingCalculator.calculateWeightedAverageEntryPrice(
                longTotalWAEP, longSizeSumUSD, _sizeDeltaUsd, _price
            );
            _sizeDeltaUsd > 0
                ? longSizeSumUSD += _sizeDeltaUsd.toUint256()
                : longSizeSumUSD -= (-_sizeDeltaUsd).toUint256();
        } else {
            shortTotalWAEP = PricingCalculator.calculateWeightedAverageEntryPrice(
                shortTotalWAEP, shortSizeSumUSD, _sizeDeltaUsd, _price
            );
            _sizeDeltaUsd > 0
                ? shortSizeSumUSD += _sizeDeltaUsd.toUint256()
                : shortSizeSumUSD -= (-_sizeDeltaUsd).toUint256();
        }
        emit TotalWAEPUpdated(longTotalWAEP, shortTotalWAEP);
    }

    function getMarketParameters() external view returns (uint256, uint256, uint256, uint256) {
        return
            (longCumulativeFundingFees, shortCumulativeFundingFees, longCumulativeBorrowFee, shortCumulativeBorrowFee);
    }

    function getPrice(address _token) public view returns (uint256) {
        // perform safety checks
        return _getPrice(_token);
    }

    function getMarketKey() public view returns (bytes32) {
        return keccak256(abi.encodePacked(indexToken));
    }

    function _getPrice(address _token) internal view returns (uint256) {
        // call the oracle contract and return the price of the token
    }
}
