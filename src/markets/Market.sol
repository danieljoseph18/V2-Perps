// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IMarketToken} from "./interfaces/IMarketToken.sol";
import {IMarketStorage} from "./interfaces/IMarketStorage.sol";
import {MarketStructs} from "./MarketStructs.sol";
import {ILiquidityVault} from "./interfaces/ILiquidityVault.sol";

/// funding rate calculation = dr/dt = c * skew (credit to https://blog.synthetix.io/synthetix-perps-dynamic-funding-rates/)
/// NEED TO EXTRAPOLATE OUT DECIMAL PRECISION INTO 1 VAR
contract Market {
    using SafeERC20 for IERC20;
    using MarketStructs for MarketStructs.Market;
    using MarketStructs for MarketStructs.Position;

    // represents a market
    // allows users to trade in and out
    // holds funds for users
    // initialized with a market token
    address public indexToken;
    address public stablecoin;
    address public liquidityVault;
    address public marketStorage;

    uint256 public lastFundingUpdateTime; // last time funding was updated
    uint256 public lastBorrowUpdateTime; // last time borrowing fee was updated
    // positive rate = longs pay shorts, negative rate = shorts pay longs
    int256 public fundingRate; // Stored as a fixed-point number (e.g., 0.01% == 1000)
    uint256 public skewScale = 1e7; // Skew scale in USDC
    uint256 public maxFundingVelocity = 3000000; // 300% represented as fixed-point (300% == 3000000)
    uint256 public fundingInterval = 8 hours; // Update interval in seconds
    uint256 public maxFundingRate = 5000; // 5% represented as fixed-point (5% == 5e3)

    uint256 public longCumulativeFundingRate; // how much longs have owed shorts
    uint256 public shortCumulativeFundingRate; // how much shorts have owed longs

    // Borrow factor scaled by 1e10
    uint256 public borrowingFactor = 34722; // = 0.0000034722% per second = 0.3% per day mean
    uint256 public borrowingExponent = 1;
    // Flag for skipping borrowing fee for the smaller side
    bool public feeForSmallerSide;
    uint256 public cumulativeBorrowFee;
    uint256 public borrowingRate; // borrow fee per second

    uint256 public priceImpactExponent = 1; 
    uint256 public priceImpactFactor = 1; // 0.0001%
    
    // tracks deposits separately from margin collateral
    mapping(address => uint256) public poolAmounts;
    mapping(address => uint256) public marginAmounts;

    // might need to update to an initialize function instead of constructor
    constructor(address _indexToken, address _stablecoin, address _marketStorage, address _liquidityVault) {
        indexToken = _indexToken;
        stablecoin = _stablecoin;
        marketStorage = _marketStorage;
        liquidityVault = _liquidityVault;
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


    function getOpenInterest(bool _isLong) public view returns (uint256) {
        return _calculateOpenInterest(_isLong);
    }

    function getTotalOpenInterest() public view returns (uint256) {
        return _calculateOpenInterest(true) + _calculateOpenInterest(false);
    }

    // returns total trade open interest in stablecoins
    function _calculateOpenInterest(bool _isLong) internal view returns (uint256) {
        // If long, return the long open interest
        // If short, return the short open interest
        bytes32 key = getMarketKey();
        return _isLong ? IMarketStorage(marketStorage).collatTokenLongOpenInterest(key) : IMarketStorage(marketStorage).collatTokenShortOpenInterest(key);
    }

    // returns the open interest in tokens of the index token
    // basically how many collateral tokens have been exchanged for index tokens
    function _calculateIndexOpenInterest(bool _isLong) internal view returns (uint256) {
        bytes32 key = getMarketKey();
        return _isLong ? IMarketStorage(marketStorage).indexTokenLongOpenInterest(key) : IMarketStorage(marketStorage).indexTokenShortOpenInterest(key);
    }

    /////////////
    // Funding //
    /////////////

    function upkeepNeeded() public view returns (bool) {
        // check if funding rate needs to be updated
        return block.timestamp >= lastFundingUpdateTime + fundingInterval;
    }

    function updateFundingRate() public {
        bool _upkeepNeeded = upkeepNeeded();
        if (_upkeepNeeded) {
            _updateFundingRate();
        }
    }

    // only privileged roles can call
    function setFundingConfig(uint256 _fundingInterval, uint256 _maxFundingVelocity, uint256 _skewScale, uint256 _maxFundingRate) public {
        // check if msg.sender is owner
        fundingInterval = _fundingInterval;
        maxFundingVelocity = _maxFundingVelocity;
        skewScale = _skewScale;
        maxFundingRate = _maxFundingRate;
    }

    function _updateFundingRate() internal {
        uint256 longOI = _calculateOpenInterest(true);
        uint256 shortOI = _calculateOpenInterest(false);
        int256 skew = int256(longOI) - int256(shortOI);
        uint256 fundingRateVelocity = _calculateFundingRateVelocity(skew);

        uint256 timeElapsed = block.timestamp - lastFundingUpdateTime;
        uint256 deltaRate = (fundingRateVelocity * timeElapsed) / (1 days);

        if (longOI > shortOI) {
            // if funding rate will be > 5%, set it to 5%
            fundingRate + int256(deltaRate) > int256(maxFundingRate) ? fundingRate = int256(maxFundingRate) :fundingRate += int256(deltaRate);
            longCumulativeFundingRate += uint256(fundingRate);
        } else if (shortOI > longOI) {
            // if funding rate will be < -5%, set it to -5%
            fundingRate - int256(deltaRate) < -int256(maxFundingRate) ? fundingRate = -int256(maxFundingRate) : fundingRate -= int256(deltaRate);
            shortCumulativeFundingRate += uint256(fundingRate);
        }

        lastFundingUpdateTime = block.timestamp;
    }

    function _calculateFundingRateVelocity(int256 _skew) internal view returns (uint256) {
        uint256 c = maxFundingVelocity / skewScale; // will underflow (3 mil < 10 mil)
        // have to multiply maxFundingVelocity by a scalar (maybe 10_000)
        // c = 0.3% = 3000
        if(_skew < 0) {
            return c * uint256(-_skew);
        }
        return c * uint256(_skew); // 450 == 0.045%
    }

    // returns percentage of position size that is paid as funding fees
    // formula: feesOwed = ((cumulative - entry) - current) + ((delta t / funding interval) * current)
    // position short = negative, position long = positive
    // since open, track funding owed by longs and shorts
    // return their fees minus the opposite side
    // returned value is scaled by 1e5, this needs to be descaled after fees accounted for
    function _calculateFundingFees(MarketStructs.Position memory _position) internal view returns (int256) {
        uint256 entryLongCumulative = _position.entryLongCumulativeFunding;
        uint256 entryShortCumulative = _position.entryShortCumulativeFunding;
        uint256 currentLongCumulative = longCumulativeFundingRate;
        uint256 currentShortCumulative = shortCumulativeFundingRate; 

        uint256 longAccumulatedFunding = currentLongCumulative - entryLongCumulative; 
        uint256 shortAccumulatedFunding = currentShortCumulative - entryShortCumulative;

        uint256 timeSinceUpdate = (block.timestamp - lastFundingUpdateTime) * 1e5; // scaled by 1e5 to ensure top heavy fraction

        // subtract current funding rate
        // need to account for fact current funding Rate can be positive
        uint256 longFeesOwed = (longAccumulatedFunding - uint256(fundingRate)) + ((timeSinceUpdate / fundingInterval) * uint256(fundingRate));
        uint256 shortFeesOwed = (shortAccumulatedFunding - uint256(fundingRate)) + ((timeSinceUpdate / fundingInterval) * uint256(fundingRate));

        // +ve value = fees owed, -ve value = fees earned
        // IMPORTANT: De-scale the return value by 1e5
        return _position.isLong ? int256(longFeesOwed) - int256(shortFeesOwed) : int256(shortFeesOwed) - int256(longFeesOwed);
    }

    // RETURNS PERCENTAGE, NEEDS TO BE SCALED BY SIZE
    // MAKE SURE PERCENTAGE IS THE SAME PRECISION AS FUNDING FEE
    function getFundingFees(MarketStructs.Position memory _position) public view returns (int256) {
        return _calculateFundingFees(_position);
    }

    ////////////////////
    // BORROWING FEES //
    ////////////////////

    // Function to update borrowing parameters (consider appropriate access control)
    function setBorrowingConfig(uint256 _borrowingFactor, uint256 _borrowingExponent, bool _feeForSmallerSide) public {
        borrowingFactor = _borrowingFactor;
        borrowingExponent = _borrowingExponent;
        feeForSmallerSide = _feeForSmallerSide;
    }

    // Function to calculate borrowing fees per second
    function _updateBorrowingRate(bool _isLong) public {
        uint256 openInterest = getOpenInterest(_isLong);
        uint256 poolBalance = poolAmounts[stablecoin];  // Amount of USDC in pool (not exact USD value)

        int256 pendingPnL = getNetPnL(_isLong);
        
        int256 feeBase = int256(openInterest) + pendingPnL;
        uint256 fee = borrowingFactor * (uint256(feeBase) ** borrowingExponent) / poolBalance;

        // update cumulative fees with current borrowing rate
        cumulativeBorrowFee += borrowingRate * (block.timestamp - lastBorrowUpdateTime);
        // update last update time
        lastBorrowUpdateTime = block.timestamp;
        // update borrowing rate
        // borrowing factor scaled by 1e5, need to de-scale
        borrowingRate = fee;
    }

    // Get the borrowing fees owed for a particular position
    // MAKE SURE PERCENTAGE IS THE SAME PRECISION AS FUNDING FEE
    function getBorrowingFees(MarketStructs.Position memory _position) public view returns (uint256) {
        return cumulativeBorrowFee - _position.entryCumulativeBorrowFee;

    }

    /////////
    // PNL //
    /////////


    // USD worth - cumulative USD paid
    function _calculatePnL(MarketStructs.Position memory _position) internal view returns (int256) {
        uint256 positionValue = _position.positionSize * getPrice(indexToken);
        uint256 entryValue = _position.positionSize * _position.averagePricePerToken;
        return int256(positionValue) - int256(entryValue);
    }

    function getPnL(MarketStructs.Position memory _position) public view returns (int256) {
        return _calculatePnL(_position);
    }

    function getNetPnL(bool _isLong) public view returns (int256) {
        return _getNetPnL(_isLong);
    }

    // returns the difference between the worth of index token open interest and collateral token
    function _getNetPnL(bool _isLong) internal view returns (int256) {
        uint256 openInterest = _calculateOpenInterest(_isLong) * getPrice(stablecoin);
        uint256 indexOpenInterest = _calculateIndexOpenInterest(_isLong) * getPrice(indexToken);
        return _isLong ? int256(indexOpenInterest) - int256(openInterest) : int256(openInterest) - int256(indexOpenInterest);
    }

    //////////////////
    // PRICE IMPACT //
    //////////////////

    function _calculatePriceImpact(MarketStructs.Position memory _position) internal view returns (uint256) {

        uint256 longOI = _calculateOpenInterest(true);
        uint256 shortOI = _calculateOpenInterest(false);
        uint256 skewBefore = longOI > shortOI ? longOI - shortOI : shortOI - longOI;

        _position.isLong ? longOI += _position.positionSize : shortOI += _position.positionSize;

        uint256 skewAfter = longOI > shortOI ? longOI - shortOI : shortOI - longOI;

        // Formula: priceImpact = (usd Diff ^ exponent * factor) - (usd Diff After ^ exponent * factor)
        return ((skewBefore ** priceImpactExponent) * priceImpactFactor) - ((skewAfter ** priceImpactExponent) * priceImpactFactor);
    }

    function getPriceImpact(MarketStructs.Position memory _position) public view returns (uint256) {
        return _calculatePriceImpact(_position);
    }

    // only callable by market config contract
    function setPriceImpactConfig(uint256 _priceImpactFactor, uint256 _priceImpactExponent) external {
        priceImpactFactor = _priceImpactFactor;
        priceImpactExponent = _priceImpactExponent;
    }

    /////////////////
    // ALLOCATION //
    ////////////////

    function getMarketAllocation() external view returns (uint256) {
        bytes32 key = getMarketKey();
        return ILiquidityVault(liquidityVault).getMarketAllocation(key);
    }

}