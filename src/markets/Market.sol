// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IMarketToken} from "./interfaces/IMarketToken.sol";
import {IMarketStorage} from "./interfaces/IMarketStorage.sol";
import {MarketStructs} from "./MarketStructs.sol";

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
    address public marketToken;
    address public marketStorage;

    uint256 public lastUpdateTime; // last time funding rate was updated
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

    uint256 public priceImpactExponent = 1; 
    uint256 public priceImpactFactor = 1; // 0.0001%
    
    // tracks deposits separately from margin collateral
    mapping(address => uint256) public poolAmounts;
    mapping(address => uint256) public marginAmounts;

    // might need to update to an initialize function instead of constructor
    constructor(address _indexToken, address _stablecoin, address _marketToken, address _marketStorage) {
        indexToken = _indexToken;
        stablecoin = _stablecoin;
        marketToken = _marketToken;
        marketStorage = _marketStorage;
        (longCumulativeFundingRate, shortCumulativeFundingRate) = (0,0);
    }

    /////////////
    // PRICING //
    /////////////


    // must factor in worth of all tokens deposited, pending PnL, pending borrow fees
    // price per 1 token (1e18 decimals)
    function getMarketTokenPrice() public view returns (uint256) {
        // amount of market tokens function of AUM in USD
        // market token price = (worth of market pool) / total supply
        // could overflow, need to use scaling factor, will hover around 0.9 - 1.1
        return getAum() / IERC20(marketToken).totalSupply();
    }

    function getAum() public view returns (uint256 aum) {
        // get the AUM of the market in USD
        // must factor in worth of all tokens deposited, pending PnL, pending borrow fees
        // liquidity in USD
        uint256 liquidity = (poolAmounts[stablecoin] * getPrice(stablecoin));
        aum = liquidity;
        int256 pendingPnL = _getNetPnL(true) + _getNetPnL(false); 
        uint256 borrowingFees;
        pendingPnL > 0 ? aum += uint256(pendingPnL) : aum -= uint256(pendingPnL);
        return aum - borrowingFees;
    }

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
        return block.timestamp >= lastUpdateTime + fundingInterval;
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

        uint256 timeElapsed = block.timestamp - lastUpdateTime;
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

        lastUpdateTime = block.timestamp;
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

        uint256 timeSinceUpdate = (block.timestamp - lastUpdateTime) * 1e5; // scaled by 1e5 to ensure top heavy fraction

        // subtract current funding rate
        // need to account for fact current funding Rate can be positive
        uint256 longFeesOwed = (longAccumulatedFunding - uint256(fundingRate)) + ((timeSinceUpdate / fundingInterval) * uint256(fundingRate));
        uint256 shortFeesOwed = (shortAccumulatedFunding - uint256(fundingRate)) + ((timeSinceUpdate / fundingInterval) * uint256(fundingRate));

        // IMPORTANT: De-scale the return value by 1e5
        return _position.isLong ? int256(longFeesOwed) - int256(shortFeesOwed) : int256(shortFeesOwed) - int256(longFeesOwed);
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

    // Function to calculate borrowing fees
    function calculateBorrowingFees(bool _isLong) public view returns (uint256) {
        uint256 openInterest = getOpenInterest(_isLong);
        uint256 poolBalance = poolAmounts[stablecoin];  // Amount of USDC in pool (not exact USD value)

        int256 pendingPnL = getNetPnL(_isLong);
        
        int256 feeBase = int256(openInterest) + pendingPnL;
        uint256 fee = borrowingFactor * (uint256(feeBase) ** borrowingExponent) / poolBalance;

        // If no fee for smaller side
        if(!feeForSmallerSide) {
            uint256 counterPartyOI = getOpenInterest(!_isLong);
            // if their side's OI < other sides OI, they're smaller side
            if(openInterest < counterPartyOI) {
                return 0;
            }
        }
        // borrowing factor scaled by 1e5, need to de-scale
        return fee;
    }

    /////////
    // PNL //
    /////////


    // Position size x value - position size x entry value
    function _calculatePnL(MarketStructs.Position memory _position) internal view returns (int256) {
        uint256 positionValue = _position.positionSize * getPrice(indexToken);
        uint256 entryValue = _position.positionSize * _position.entryPrice;
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

    ///////////////
    // LIQUIDITY //
    ///////////////

    function addLiquidity(uint256 _amount, address _tokenIn) external {
        _addLiquidity(msg.sender, _amount, _tokenIn);
    }

    // 2 functions: removeLiq and removeLiqFrom (another acc)
    // both call internal function
    function removeLiquidity(uint256 _marketTokenAmount, address _tokenOut) external {
        _removeLiquidity(msg.sender, _marketTokenAmount, _tokenOut);
    }

    // allows users to delegate permissions from ledger to hot wallet
    function addLiquidityForAccount(address _account, uint256 _amount, address _tokenIn) public {
        // check if msg.sender is approved to add liquidity for _account
        _addLiquidity(_account, _amount, _tokenIn);
    }

    // allows users to delegate permissions from ledger to hot wallet
    function removeLiquidityForAccount(address _account, uint256 _marketTokenAmount, address _tokenOut) public {
        // check if msg.sender is approved to remove liquidity for _account
        _removeLiquidity(_account, _marketTokenAmount, _tokenOut);
    }

    // subtract fees, many additional safety checks needed
    function _addLiquidity(address _account, uint256 _amount, address _tokenIn) internal {
        require(_amount > 0, "Invalid amount");
        require(_tokenIn == stablecoin, "Invalid token");


        poolAmounts[_tokenIn] += _amount;
        // add liquidity to the market
        IERC20(_tokenIn).safeTransferFrom(_account, address(this), _amount);
        // mint market tokens for the user
        uint256 mintAmount = (_amount * getPrice(_tokenIn)) / getMarketTokenPrice();
        
        IMarketToken(marketToken).mint(_account, mintAmount);
    }

    // subtract fees, many additional safety checks needed
    function _removeLiquidity(address _account, uint256 _marketTokenAmount, address _tokenOut) internal {
        require(_marketTokenAmount > 0, "Invalid amount");
        require(_tokenOut == stablecoin, "Invalid token");


        // remove liquidity from the market
        uint256 marketTokenValue = _marketTokenAmount * getMarketTokenPrice();

        uint256 tokenAmount = marketTokenValue / getPrice(_tokenOut);

        poolAmounts[_tokenOut] -= tokenAmount;

        IMarketToken(marketToken).burn(_account, _marketTokenAmount);
        
        IERC20(_tokenOut).safeTransfer(_account, tokenAmount);
    }



}