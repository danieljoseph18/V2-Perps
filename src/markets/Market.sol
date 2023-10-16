// SPDX-License-Identifier: MIT
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
import {PnLCalculator} from "../positions/PnLCalculator.sol";

/// funding rate calculation = dr/dt = c * skew (credit to https://sips.synthetix.io/sips/sip-279/)
/// Note Need to Add Allocation Flagging on interaction
contract Market is RoleValidation {
    using SafeERC20 for IERC20;
    using MarketStructs for MarketStructs.Market;
    using MarketStructs for MarketStructs.Position;
    using SafeCast for uint256;
    using SafeCast for int256;

    int256 public constant MAX_PRICE_IMPACT = 33e18; // 33%

    // represents a market
    // allows users to trade in and out
    // holds funds for users
    // initialized with a market token
    address public indexToken;
    address public collateralToken;
    ILiquidityVault public liquidityVault;
    IMarketStorage public marketStorage;
    ITradeStorage public tradeStorage;

    uint256 public lastFundingUpdateTime; // last time funding was updated
    uint256 public lastBorrowUpdateTime; // last time borrowing fee was updated
    // positive rate = longs pay shorts, negative rate = shorts pay longs
    int256 public fundingRate; // RATE PER SECOND Stored as a fixed-point number 1 = 1e18
    int256 public fundingRateVelocity; // VELOCITY PER SECOND
    uint256 public skewScale = 1_000_000e18; // Skew scale in USDC (1_000_000)
    uint256 public maxFundingVelocity = 0.03e18; // 0.03% represented as fixed-point
    int256 public maxFundingRate = 5e18; // 5% represented as fixed-point
    int256 public minFundingRate = -5e18; // -5% fixed point

    uint256 public longCumulativeFundingFees; // how much longs have owed shorts per token, 18 decimals
    uint256 public shortCumulativeFundingFees; // how much shorts have owed longs per token, 18 decimals

    uint256 public borrowingFactor = 0.0000035e18; // = 0.0000035% per second
    uint256 public borrowingExponent = 1e18; // 1.00...
    // Flag for skipping borrowing fee for the smaller side
    bool public feeForSmallerSide;
    uint256 public longCumulativeBorrowFee;
    uint256 public shortCumulativeBorrowFee;
    uint256 public longBorrowingRate; // borrow fee per second for longs per second (0.0001e18 = 0.01%)
    uint256 public shortBorrowingRate; // borrow fee per second for shorts per second

    uint256 public priceImpactExponent = 1e18;
    uint256 public priceImpactFactor = 0.0001e18; // 0.0001%

    uint256 public longCumulativePricePerToken; // long cumulative price paid for all index tokens in OI
    uint256 public shortCumulativePricePerToken; // short cumulative price paid for all index tokens in OI

    uint256 public lastAllocation; // last time allocation was updated

    // might need to update to an initialize function instead of constructor
    constructor(
        address _indexToken,
        address _collateralToken,
        IMarketStorage _marketStorage,
        ILiquidityVault _liquidityVault,
        ITradeStorage _tradeStorage
    ) RoleValidation(roleStorage) {
        indexToken = _indexToken;
        collateralToken = _collateralToken;
        marketStorage = _marketStorage;
        liquidityVault = _liquidityVault;
        tradeStorage = _tradeStorage;
    }

    /////////////
    // PRICING //
    /////////////

    function getPrice(address _token) public view returns (uint256) {
        // perform safety checks
        return _getPrice(_token);
    }

    function _getPrice(address _token) internal view returns (uint256) {
        // call the oracle contract and return the price of the token
    }

    function getMarketKey() public view returns (bytes32) {
        return keccak256(abi.encodePacked(indexToken, collateralToken));
    }

    /////////////
    // Funding //
    /////////////

    /// @dev Only GlobalMarketConfig
    function setFundingConfig(
        uint256 _maxFundingVelocity,
        uint256 _skewScale,
        int256 _maxFundingRate,
        int256 _minFundingRate
    ) public onlyConfigurator {
        maxFundingVelocity = _maxFundingVelocity;
        skewScale = _skewScale;
        maxFundingRate = _maxFundingRate;
        minFundingRate = _minFundingRate;
    }

    function _updateFundingRate(uint256 _positionSize, bool _isLong) internal {
        uint256 longOI = PnLCalculator.calculateIndexOpenInterestUSD(
            address(marketStorage), address(this), getMarketKey(), collateralToken, true
        );
        uint256 shortOI = PnLCalculator.calculateIndexOpenInterestUSD(
            address(marketStorage), address(this), getMarketKey(), collateralToken, false
        );
        _isLong ? longOI += _positionSize : shortOI += _positionSize;
        int256 skew = unwrap(sd(longOI.toInt256()) - sd(shortOI.toInt256())); // 500 USD skew = 500e18
        int256 velocity = FundingCalculator.calculateFundingRateVelocity(address(this), skew); // int scaled by 1e18

        // Calculate time since last funding update
        uint256 timeElapsed = unwrap(ud(block.timestamp) - ud(lastFundingUpdateTime));
        // Add the previous velocity to the funding rate
        int256 deltaRate = unwrap((sd(fundingRateVelocity)).mul(sd(timeElapsed.toInt256())).div(sd(1 days)));

        // Update Cumulative Fees
        if (fundingRate > 0) {
            longCumulativeFundingFees += (fundingRate.toUint256() * timeElapsed); // if funding rate has 18 decimals, rate per token = rate
        } else if (fundingRate < 0) {
            shortCumulativeFundingFees += ((-fundingRate).toUint256() * timeElapsed);
        }

        // if funding rate addition puts it above / below limit, set to limit
        if (fundingRate + deltaRate > maxFundingRate) {
            fundingRate = maxFundingRate;
        } else if (fundingRate - deltaRate < minFundingRate) {
            fundingRate = -maxFundingRate;
        } else {
            fundingRate += deltaRate;
        }
        fundingRateVelocity = velocity;
        lastFundingUpdateTime = block.timestamp;
    }

    ////////////////////
    // BORROWING FEES //
    ////////////////////

    // Function to update borrowing parameters (consider appropriate access control)
    /// @dev Only GlobalMarketConfig
    function setBorrowingConfig(uint256 _borrowingFactor, uint256 _borrowingExponent, bool _feeForSmallerSide)
        external
        onlyConfigurator
    {
        borrowingFactor = _borrowingFactor;
        borrowingExponent = _borrowingExponent;
        feeForSmallerSide = _feeForSmallerSide;
    }

    // Function to calculate borrowing fees per second
    /// @dev uses GMX Synth borrow rate calculation
    function updateBorrowingRate(bool _isLong) external {
        uint256 openInterest = PnLCalculator.calculateIndexOpenInterestUSD(
            address(marketStorage), address(this), getMarketKey(), collateralToken, _isLong
        ); // OI USD
        uint256 poolBalance =
            PnLCalculator.getPoolBalanceUSD(address(liquidityVault), getMarketKey(), address(this), collateralToken); // Pool balance in USD

        int256 pendingPnL = PnLCalculator.getNetPnL(
            address(this), address(tradeStorage), address(marketStorage), getMarketKey(), _isLong
        ); // PNL USD

        uint256 borrowingRate = _isLong ? longBorrowingRate : shortBorrowingRate;

        SD59x18 feeBase = _isLong ? sd(openInterest.toInt256()) + sd(pendingPnL) : sd(openInterest.toInt256());
        UD60x18 fee =
            ud(borrowingFactor) * (ud(unwrap(feeBase).toUint256()).pow(ud(borrowingExponent))) / ud(poolBalance);

        // update cumulative fees with current borrowing rate
        if (_isLong) {
            longCumulativeBorrowFee += borrowingRate * (block.timestamp - lastBorrowUpdateTime);
        } else {
            shortCumulativeBorrowFee += borrowingRate * (block.timestamp - lastBorrowUpdateTime);
        }
        // update last update time
        lastBorrowUpdateTime = block.timestamp;
        // update borrowing rate
        _isLong ? longBorrowingRate = unwrap(fee) : shortBorrowingRate = unwrap(fee);
    }

    /////////
    // PNL //
    /////////

    // check this is updated correctly in the executor
    function updateCumulativePricePerToken(uint256 _price, bool _isIncrease, bool _isLong) external onlyExecutor {
        if (_isLong) {
            _isIncrease ? longCumulativePricePerToken += _price : longCumulativePricePerToken -= _price;
        } else {
            _isIncrease ? shortCumulativePricePerToken += _price : shortCumulativePricePerToken -= _price;
        }
    }

    //////////////////
    // PRICE IMPACT //
    //////////////////

    /// @dev Only GlobalMarketConfig
    function setPriceImpactConfig(uint256 _priceImpactFactor, uint256 _priceImpactExponent) external onlyConfigurator {
        priceImpactFactor = _priceImpactFactor;
        priceImpactExponent = _priceImpactExponent;
    }

    /////////////
    // GETTERS //
    /////////////

    function getMarketParameters() external view returns (uint256, uint256, uint256, uint256) {
        return
            (longCumulativeFundingFees, shortCumulativeFundingFees, longCumulativeBorrowFee, shortCumulativeBorrowFee);
    }
}
