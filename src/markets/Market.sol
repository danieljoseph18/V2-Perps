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
import { SD59x18, sd, unwrap, pow } from "@prb/math/SD59x18.sol";
import { UD60x18, ud, unwrap } from "@prb/math/UD60x18.sol";

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
    address public stablecoin;
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
        address _stablecoin,
        IMarketStorage _marketStorage,
        ILiquidityVault _liquidityVault,
        ITradeStorage _tradeStorage
    ) RoleValidation(roleStorage) {
        indexToken = _indexToken;
        stablecoin = _stablecoin;
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
        return keccak256(abi.encodePacked(indexToken, stablecoin));
    }

    ///////////////////
    // OPEN INTEREST //
    ///////////////////

    function getCollateralOpenInterest(bool _isLong) public view returns (uint256) {
        return _calculateCollateralOpenInterest(_isLong);
    }

    function getIndexOpenInterest(bool _isLong) public view returns (uint256) {
        return _calculateIndexOpenInterest(_isLong);
    }

    function getCollateralOpenInterestUSD(bool _isLong) public view returns (uint256) {
        uint256 collateralOpenInterest = _calculateCollateralOpenInterest(_isLong);
        return collateralOpenInterest * getPrice(stablecoin);
    }

    function getIndexOpenInterestUSD(bool _isLong) public view returns (uint256) {
        uint256 indexOpenInterest = _calculateIndexOpenInterest(_isLong);
        uint256 indexPrice = getPrice(indexToken);
        return indexOpenInterest * indexPrice;
    }

    function getTotalCollateralOpenInterest() public view returns (uint256) {
        return _calculateCollateralOpenInterest(true) + _calculateCollateralOpenInterest(false);
    }

    function getTotalIndexOpenInterest() public view returns (uint256) {
        return _calculateIndexOpenInterest(true) + _calculateIndexOpenInterest(false);
    }

    function getTotalCollateralOpenInterestUSD() public view returns (uint256) {
        return getCollateralOpenInterestUSD(true) + getCollateralOpenInterestUSD(false);
    }

    function getTotalIndexOpenInterestUSD() public view returns (uint256) {
        return getIndexOpenInterestUSD(true) + getIndexOpenInterestUSD(false);
    }

    // returns total trade open interest in stablecoins
    function _calculateCollateralOpenInterest(bool _isLong) internal view returns (uint256) {
        // If long, return the long open interest
        // If short, return the short open interest
        bytes32 key = getMarketKey();
        return
            _isLong ? marketStorage.collatTokenLongOpenInterest(key) : marketStorage.collatTokenShortOpenInterest(key);
    }

    // returns the open interest in tokens of the index token
    // basically how many collateral tokens have been exchanged for index tokens
    function _calculateIndexOpenInterest(bool _isLong) internal view returns (uint256) {
        bytes32 key = getMarketKey();
        return _isLong ? marketStorage.indexTokenLongOpenInterest(key) : marketStorage.indexTokenShortOpenInterest(key);
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
        uint256 longOI = getIndexOpenInterestUSD(true);
        uint256 shortOI = getIndexOpenInterestUSD(false);
        _isLong ? longOI += _positionSize : shortOI += _positionSize;
        int256 skew = unwrap(sd(longOI.toInt256()) - sd(shortOI.toInt256())); // 500 USD skew = 500e18
        int256 velocity = _calculateFundingRateVelocity(skew); // int scaled by 1e18

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
        } else if (fundingRate - deltaRate < minFundingRate){
            fundingRate = -maxFundingRate;
        } else {
            fundingRate += deltaRate;
        }
        fundingRateVelocity = velocity;
        lastFundingUpdateTime = block.timestamp;
    }

    // c == percentage e.g 3e18 (300%)/ liquidity e.g 10_000_000e18

    function _calculateFundingRateVelocity(int256 _skew) internal view returns (int256) {
        uint256 c = unwrap(ud(maxFundingVelocity).div(ud(skewScale))); // will underflow (3 mil < 10 mil)
        SD59x18 skew = sd(_skew); // skew of 1 = 1e18
        // scaled by 1e18
        // c = 3/10000 = 0.0003 * 100 =  0.3% = 3e14
        return c.toInt256() * unwrap(skew);
    }

    // returns percentage of position size that is paid as funding fees
    /// Note Gets the total funding fees by a position, doesn't account for realised funding fees
    /// Review Could this be gamed by adjusting the position size?
    // Only calculates what the user owes, not what they could be owed
    // Update so it returns what a short would owe and what a long would owe
    function _calculateFundingFees(MarketStructs.Position memory _position) internal view returns (uint256, uint256) {
        uint256 longLastFunding = _position.fundingParams.lastLongCumulativeFunding;
        uint256 shortLastFunding = _position.fundingParams.lastShortCumulativeFunding;

        uint256 longAccumulatedFunding = longCumulativeFundingFees - longLastFunding;
        uint256 shortAccumulatedFunding = shortCumulativeFundingFees - shortLastFunding;

        uint256 timeSinceUpdate = block.timestamp - lastFundingUpdateTime; // might need to scale by 1e18

        // is the current funding rate +ve or -ve ?
        // if +ve, need to add accumulated funding to long, if -ve need to add to short
        if (fundingRate > 0) {
            longAccumulatedFunding += (timeSinceUpdate * fundingRate.toUint256());
        } else {
            shortAccumulatedFunding += (timeSinceUpdate * (-fundingRate).toUint256());
        }

        return (longAccumulatedFunding, shortAccumulatedFunding);
    }

    function getFundingFees(MarketStructs.Position memory _position) external view returns (uint256, uint256) {
        return _calculateFundingFees(_position);
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
        uint256 openInterest = getIndexOpenInterestUSD(_isLong); // OI USD
        uint256 poolBalance = getPoolBalanceUSD(); // Pool balance in USD

        int256 pendingPnL = getNetPnL(_isLong); // PNL USD

        uint256 borrowingRate = _isLong ? longBorrowingRate : shortBorrowingRate;

        SD59x18 feeBase = _isLong ? sd(openInterest.toInt256()) + sd(pendingPnL) : sd(openInterest.toInt256());
        UD60x18 fee = ud(borrowingFactor) * (ud(unwrap(feeBase).toUint256()).pow(ud(borrowingExponent))) / ud(poolBalance);

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

    // Get the borrowing fees owed for a particular position
    function getBorrowingFees(MarketStructs.Position memory _position) public view returns (uint256) {
        return _position.isLong
            ? longCumulativeBorrowFee - _position.borrowParams.entryLongCumulativeBorrowFee
            : shortCumulativeBorrowFee - _position.borrowParams.entryShortCumulativeBorrowFee;
    }

    /////////
    // PNL //
    /////////

    // USD worth : cumulative USD paid
    // needs to take into account longs and shorts
    // if long, entry - position = pnl, if short, position - entry = pnl
    function _calculatePnL(MarketStructs.Position memory _position) internal view returns (int256) {
        uint256 positionValue = _position.positionSize * getPrice(indexToken);
        uint256 entryValue = _position.positionSize * _position.averagePricePerToken;
        return
            _position.isLong ? entryValue.toInt256() - positionValue.toInt256() : positionValue.toInt256() - entryValue.toInt256();
    }

    function getPnL(MarketStructs.Position memory _position) public view returns (int256) {
        return _calculatePnL(_position);
    }

    function getNetPnL(bool _isLong) public view returns (int256) {
        return _getNetPnL(_isLong);
    }

    // returns the difference between the worth of index token open interest and collateral token
    // NEED TO SCALE TO 1e18 DECIMALS
    function _getNetPnL(bool _isLong) internal view returns (int256) {
        uint256 indexValue = getIndexOpenInterestUSD(_isLong);
        uint256 entryValue = _getTotalEntryValue(_isLong);

        return _isLong ? indexValue.toInt256() - entryValue.toInt256() : entryValue.toInt256() - indexValue.toInt256();
    }

    // check this is updated correctly in the executor
    function updateCumulativePricePerToken(uint256 _price, bool _isIncrease, bool _isLong) external onlyExecutor {
        if (_isLong) {
            _isIncrease ? longCumulativePricePerToken += _price : longCumulativePricePerToken -= _price;
        } else {
            _isIncrease ? shortCumulativePricePerToken += _price : shortCumulativePricePerToken -= _price;
        }
    }

    function _getTotalEntryValue(bool _isLong) internal view returns (uint256) {
        // get the number of active positions => to do this need to add way to enumerate the open positions in TradeStorage
        bytes32 marketKey = getMarketKey();
        uint256 positionCount = tradeStorage.openPositionKeys(marketKey, _isLong).length;
        // averageEntryPrice = cumulativePricePaid / no positions
        uint256 cumulativePricePerToken = _isLong ? longCumulativePricePerToken : shortCumulativePricePerToken;
        UD60x18 averageEntryPrice = ud(cumulativePricePerToken).div(ud(positionCount));
        // uint256 averageEntryPrice = cumulativePricePerToken / positionCount;
        // entryValue = averageEntryPrice * total OI
        return unwrap(averageEntryPrice) * _calculateIndexOpenInterest(_isLong);
    }

    //////////////////
    // PRICE IMPACT //
    //////////////////

    // Returns Price impact as a percentage of the position size
    function _calculatePriceImpact(
        MarketStructs.PositionRequest memory _positionRequest, 
        uint256 _signedBlockPrice
    ) 
        internal
        view
        returns (int256)
    {
        uint256 longOI = getIndexOpenInterestUSD(true);
        uint256 shortOI = getIndexOpenInterestUSD(false);

        SD59x18 skewBefore = longOI > shortOI ? sd(longOI.toInt256() - shortOI.toInt256()) : sd(shortOI.toInt256() - longOI.toInt256());

        uint256 sizeDeltaUSD = _positionRequest.sizeDelta * _signedBlockPrice;

        if (_positionRequest.isIncrease) {
            _positionRequest.isLong ? longOI += sizeDeltaUSD : shortOI += sizeDeltaUSD;
        } else {
            _positionRequest.isLong ? longOI -= sizeDeltaUSD : shortOI -= sizeDeltaUSD;
        }

        SD59x18 skewAfter = longOI > shortOI ? sd(longOI.toInt256() - shortOI.toInt256()) : sd(shortOI.toInt256() - longOI.toInt256());

        SD59x18 exponent = sd(priceImpactExponent.toInt256());
        SD59x18 factor = sd(priceImpactFactor.toInt256());

        SD59x18 priceImpact = (skewBefore.pow(exponent)).mul(factor) - (skewAfter.pow(exponent)).mul(factor);

        if (unwrap(priceImpact) > MAX_PRICE_IMPACT) priceImpact = sd(MAX_PRICE_IMPACT);

        return unwrap(priceImpact.mul(sd(100)).div(sd(sizeDeltaUSD.toInt256())));
    }

    function getPriceImpact(MarketStructs.PositionRequest memory _positionRequest, uint256 _signedBlockPrice)
        public
        view
        returns (int256)
    {
        return _calculatePriceImpact(_positionRequest, _signedBlockPrice);
    }

    /// @dev Only GlobalMarketConfig
    function setPriceImpactConfig(uint256 _priceImpactFactor, uint256 _priceImpactExponent) external onlyConfigurator {
        priceImpactFactor = _priceImpactFactor;
        priceImpactExponent = _priceImpactExponent;
    }

    /////////////////
    // ALLOCATION //
    ////////////////

    function getPoolBalance() public view returns (uint256) {
        bytes32 key = getMarketKey();
        return liquidityVault.getMarketAllocation(key);
    }

    function getPoolBalanceUSD() public view returns (uint256) {
        return getPoolBalance() * getPrice(stablecoin);
    }

    /////////////
    // GETTERS //
    /////////////

    function getMarketParameters() external view returns (uint256, uint256, uint256, uint256) {
        return
            (longCumulativeFundingFees, shortCumulativeFundingFees, longCumulativeBorrowFee, shortCumulativeBorrowFee);
    }
}
