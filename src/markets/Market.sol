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

/// funding rate calculation = dr/dt = c * skew (credit to https://blog.synthetix.io/synthetix-perps-dynamic-funding-rates/)
/// NEED TO EXTRAPOLATE OUT DECIMAL PRECISION INTO 1 VAR
contract Market is RoleValidation {
    using SafeERC20 for IERC20;
    using MarketStructs for MarketStructs.Market;
    using MarketStructs for MarketStructs.Position;

    uint256 public constant MAX_FUNDING_INTERVAL = 24 hours;
    uint256 public constant PERCENTAGE_PRECISION = 1e10; // 1e12 == 100%
    uint256 public constant FLOAT_PRECISION = 1e30;
    uint256 public constant MAX_PRICE_IMPACT = 33e10; // 33%

    // represents a market
    // allows users to trade in and out
    // holds funds for users
    // initialized with a market token
    address public indexToken;
    address public stablecoin;
    address public liquidityVault;
    IMarketStorage public marketStorage;
    ITradeStorage public tradeStorage;

    uint256 public lastFundingUpdateTime; // last time funding was updated
    uint256 public lastBorrowUpdateTime; // last time borrowing fee was updated
    // positive rate = longs pay shorts, negative rate = shorts pay longs
    int256 public fundingRate; // Stored as a fixed-point number (e.g., 0.01% == 1e8)  scaled by 1e10
    uint256 public skewScale = 1e7; // Skew scale in USDC (10_000_000)
    uint256 public maxFundingVelocity = 3e12; // 300% represented as fixed-point
    uint256 public fundingInterval = 8 hours; // Update interval in seconds
    uint256 public maxFundingRate = 5e10; // 5% represented as fixed-point (5% == 5e10)

    uint256 public longCumulativeFundingRate; // how much longs have owed shorts, scaled by 1e10
    uint256 public shortCumulativeFundingRate; // how much shorts have owed longs, scaled by 1e10

    uint256 public borrowingFactor = 34722; // = 0.0000034722% per second = 0.3% per day mean
    uint256 public borrowingExponent = 1;
    // Flag for skipping borrowing fee for the smaller side
    bool public feeForSmallerSide;
    uint256 public longCumulativeBorrowFee;
    uint256 public shortCumulativeBorrowFee;
    uint256 public longBorrowingRate; // borrow fee per second for longs
    uint256 public shortBorrowingRate; // borrow fee per second for shorts

    uint256 public priceImpactExponent = 1;
    uint256 public priceImpactFactor = 1e6; // 0.0001%

    uint256 public longCumulativePricePerToken; // long cumulative price paid for all index tokens in OI
    uint256 public shortCumulativePricePerToken; // short cumulative price paid for all index tokens in OI

    // might need to update to an initialize function instead of constructor
    constructor(address _indexToken, address _stablecoin, IMarketStorage _marketStorage, address _liquidityVault, ITradeStorage _tradeStorage)
        RoleValidation(roleStorage)
    {
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
        return _isLong
            ? marketStorage.collatTokenLongOpenInterest(key)
            : marketStorage.collatTokenShortOpenInterest(key);
    }

    // returns the open interest in tokens of the index token
    // basically how many collateral tokens have been exchanged for index tokens
    function _calculateIndexOpenInterest(bool _isLong) internal view returns (uint256) {
        bytes32 key = getMarketKey();
        return _isLong
            ? marketStorage.indexTokenLongOpenInterest(key)
            : marketStorage.indexTokenShortOpenInterest(key);
    }

    /////////////
    // Funding //
    /////////////

    function _upkeepNeeded() internal view returns (bool) {
        // check if funding rate needs to be updated
        return block.timestamp >= lastFundingUpdateTime + fundingInterval;
    }

    function updateFundingRate() external {
        bool upkeepNeeded = _upkeepNeeded();
        if (upkeepNeeded) {
            _updateFundingRate();
        }
    }

    /// @dev Only GlobalMarketConfig
    function setFundingConfig(
        uint256 _fundingInterval,
        uint256 _maxFundingVelocity,
        uint256 _skewScale,
        uint256 _maxFundingRate
    ) public onlyConfigurator {
        require(_fundingInterval <= MAX_FUNDING_INTERVAL, "Invalid funding interval");
        fundingInterval = _fundingInterval;
        maxFundingVelocity = _maxFundingVelocity;
        skewScale = _skewScale;
        maxFundingRate = _maxFundingRate;
    }

    function _updateFundingRate() internal {
        uint256 longOI = getIndexOpenInterestUSD(true);
        uint256 shortOI = getIndexOpenInterestUSD(false);
        int256 skew = int256(longOI) - int256(shortOI);
        uint256 fundingRateVelocity = _calculateFundingRateVelocity(skew);

        uint256 timeElapsed = block.timestamp - lastFundingUpdateTime;
        uint256 deltaRate = (fundingRateVelocity * timeElapsed) / (1 days);

        if (longOI > shortOI) {
            // if funding rate will be > 5%, set it to 5%
            fundingRate + int256(deltaRate) > int256(maxFundingRate)
                ? fundingRate = int256(maxFundingRate)
                : fundingRate += int256(deltaRate);
            longCumulativeFundingRate += uint256(fundingRate);
        } else if (shortOI > longOI) {
            // if funding rate will be < -5%, set it to -5%
            fundingRate - int256(deltaRate) < -int256(maxFundingRate)
                ? fundingRate = -int256(maxFundingRate)
                : fundingRate -= int256(deltaRate);
            shortCumulativeFundingRate += uint256(fundingRate);
        }

        lastFundingUpdateTime = block.timestamp;
    }

    function _calculateFundingRateVelocity(int256 _skew) internal view returns (uint256) {
        uint256 c = maxFundingVelocity / skewScale; // will underflow (3 mil < 10 mil)
        // scaled by 1e10
        // c = 0.3% = 3e9
        if (_skew < 0) {
            return c * uint256(-_skew);
        }
        return c * uint256(_skew); // 4.5e7 == 0.045%
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

        uint256 timeSinceUpdate = (block.timestamp - lastFundingUpdateTime) * PERCENTAGE_PRECISION; // scaled by 1e10 => 1 sec = 1e10

        // subtract current funding rate
        // need to account for fact current funding Rate can be positive
        uint256 longFeesOwed = (longAccumulatedFunding - uint256(fundingRate))
            + ((timeSinceUpdate / fundingInterval) * uint256(fundingRate));
        uint256 shortFeesOwed = (shortAccumulatedFunding - uint256(fundingRate))
            + ((timeSinceUpdate / fundingInterval) * uint256(fundingRate));

        // +ve value = fees owed, -ve value = fees earned
        // IMPORTANT: De-scale the return value by PRICE PRECISION
        return _position.isLong
            ? (int256(longFeesOwed) - int256(shortFeesOwed)) / int256(PERCENTAGE_PRECISION) // Will descale underflow?
            : (int256(shortFeesOwed) - int256(longFeesOwed)) / int256(PERCENTAGE_PRECISION);
    }


    function getFundingFees(MarketStructs.Position memory _position) external view returns (int256) {
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

        int256 feeBase = _isLong ? int256(openInterest) + pendingPnL : int256(openInterest);
        uint256 fee = borrowingFactor * (uint256(feeBase) ** borrowingExponent) / poolBalance; // underflow?

        // update cumulative fees with current borrowing rate
        if (_isLong) {
            longCumulativeBorrowFee += borrowingRate * (block.timestamp - lastBorrowUpdateTime);
        } else {
            shortCumulativeBorrowFee += borrowingRate * (block.timestamp - lastBorrowUpdateTime);
        }
        // update last update time
        lastBorrowUpdateTime = block.timestamp;
        // update borrowing rate
        _isLong ? longBorrowingRate = fee : shortBorrowingRate = fee;
    }

    // Get the borrowing fees owed for a particular position
    // MAKE SURE PERCENTAGE IS THE SAME PRECISION AS FUNDING FEE
    function getBorrowingFees(MarketStructs.Position memory _position) public view returns (uint256) {
        return _position.isLong ? longCumulativeBorrowFee - _position.entryLongCumulativeBorrowFee : shortCumulativeBorrowFee - _position.entryShortCumulativeBorrowFee;
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
        return _position.isLong ? int256(entryValue) - int256(positionValue) : int256(positionValue) - int256(entryValue);
    }

    function getPnL(MarketStructs.Position memory _position) public view returns (int256) {
        return _calculatePnL(_position);
    }

    function getNetPnL(bool _isLong) public view returns (int256) {
        return _getNetPnL(_isLong);
    }

    // returns the difference between the worth of index token open interest and collateral token
    function _getNetPnL(bool _isLong) internal view returns (int256) {
        uint256 indexValue = getIndexOpenInterestUSD(_isLong);
        uint256 entryValue = _getTotalEntryValue(_isLong);

        return _isLong
            ? int256(indexValue) - int256(entryValue)
            : int256(entryValue) - int256(indexValue);
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
        uint256 positionCount = _isLong ? tradeStorage.openLongPositionKeys(marketKey).length : tradeStorage.openShortPositionKeys(marketKey).length;
        // averageEntryPrice = cumulativePricePaid / no positions
        uint256 cumulativePricePerToken = _isLong ? longCumulativePricePerToken : shortCumulativePricePerToken;
        uint256 averageEntryPrice = cumulativePricePerToken / positionCount;
        // uint256 averageEntryPrice = cumulativePricePerToken / positionCount;
        // entryValue = averageEntryPrice * total OI
        return averageEntryPrice * _calculateIndexOpenInterest(_isLong);
    }

    //////////////////
    // PRICE IMPACT //
    //////////////////

 

    // Returns Price impact as a percentage of the position size
    function _calculatePriceImpact(MarketStructs.PositionRequest memory _positionRequest, bool _isIncrease) internal view returns (int256) {
        uint256 longOI = getIndexOpenInterestUSD(true);  // existing function to get long OI in USD
        uint256 shortOI = getIndexOpenInterestUSD(false);  // existing function to get short OI in USD

        uint256 skewBefore = longOI > shortOI ? longOI - shortOI : shortOI - longOI;

        uint256 sizeDeltaUSD = _positionRequest.sizeDelta * getPrice(indexToken);

        // Update open interest based on the action type
        if (_isIncrease) {
            _positionRequest.isLong ? longOI += sizeDeltaUSD : shortOI += sizeDeltaUSD;
        } else {
            _positionRequest.isLong ? longOI -= sizeDeltaUSD : shortOI -= sizeDeltaUSD;
        }

        uint256 skewAfter = longOI > shortOI ? longOI - shortOI : shortOI - longOI;

        // Calculate the price impact
        int256 priceImpact = int256((skewBefore ** priceImpactExponent) * priceImpactFactor) - int256((skewAfter ** priceImpactExponent) * priceImpactFactor);

        if (priceImpact > MAX_PRICE_IMPACT) priceImpact = MAX_PRICE_IMPACT;

        // Calculate the price impact as a percentage of the position size
        int256 priceImpactPercentage = (priceImpact * 100 * int256(PERCENTAGE_PRECISION)) / int256(sizeDeltaUSD);

        return priceImpactPercentage; // scaled by percentage precision
    }


    function getPriceImpact(MarketStructs.PositionRequest memory _positionRequest, bool _isIncrease) public view returns (int256) {
        return _calculatePriceImpact(_positionRequest, _isIncrease);
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
        return ILiquidityVault(liquidityVault).getMarketAllocation(key);
    }

    function getPoolBalanceUSD() public view returns (uint256) {
        return getPoolBalance() * getPrice(stablecoin);
    }
}
