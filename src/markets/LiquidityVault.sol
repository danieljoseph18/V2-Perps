// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IMarketToken} from "./interfaces/IMarketToken.sol";
import {MarketStructs} from "./MarketStructs.sol";
import {IMarket} from "./interfaces/IMarket.sol";
import {RoleValidation} from "../access/RoleValidation.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @dev Needs Vault Role
contract LiquidityVault is RoleValidation, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using MarketStructs for MarketStructs.Market;

    // stores all liquidity for the protocol
    // liquidity only stored in stablecoins
    // user receives LP token in return, denominating a stake in the pool
    // markets trade in and out of this pool, losses and fees accumulate in here
    // markets reserve a share of the pool => share reserved = open interest x factor (1.5 - 2x ish)
    // the shares allocated to each market are updated at set intervals to rebalance distribution

    uint256 public constant PERCENTAGE_PRECISION = 1e6; // 1e6 = 100%
    uint256 public constant PRICE_PRECISION = 1e30;

    address public stablecoin;
    IMarketToken public liquidityToken;
    uint256 public liquidityFee; // 0.2% fee on all liquidity added/removed = 200

    mapping(address _token => uint256 _poolAmount) public poolAmounts;
    // how do we store this in a way that it never gets too large?
    mapping(bytes32 _marketKey => MarketStructs.Market) public markets;
    bytes32[] public marketKeys;

    // reps liquidity allocated to each market in USDC
    // OI is capped to % of allocation
    // whenever a trade is opened, check it won't put the OI over the allocation
    // cap = marketAllocation(market) * 100% / overCollateralizationPercentage
    mapping(bytes32 _marketKey => uint256 _allocation) public marketAllocations;

    mapping(address => uint256) public fundingFeesEarned;

    // fees handled by fee handler contract
    // claim from here, reset to 0, send to fee handler
    // divide fees and handled distribution in fee handler
    uint256 public accumulatedFees;
    uint256 public overCollateralizationPercentage; // 150000 = 150% ratio => 1.5x collateral

    // liquidity token = market token
    // another contract should handle minting and burning of LP token
    constructor(address _stablecoin, IMarketToken _liquidityToken) RoleValidation(roleStorage) {
        stablecoin = _stablecoin;
        liquidityToken = _liquidityToken;
        overCollateralizationPercentage = 1500000;
        liquidityFee = 200;
    }

    //////////////
    // SETTERS //
    ////////////

    /// @dev only GlobalMarketConfig
    function updateOverCollateralizationPercentage(uint256 _percentage) external onlyConfigurator {
        overCollateralizationPercentage = _percentage;
    }

    /// @dev Only MarketFactory
    function addMarket(MarketStructs.Market memory _market) external onlyFactory {
        require(_market.indexToken != _market.stablecoin, "Index and collateral tokens must be different");
        require(_market.indexToken != address(0), "Invalid index token");
        // check if market already added
        bytes32 key = keccak256(abi.encodePacked(_market.indexToken, _market.stablecoin));
        require(markets[key].market == address(0), "Market already added");
        // add market to mapping
        markets[key] = _market;
        marketKeys.push(key);
    }

    /// @dev only GlobalMarketConfig
    function updateLiquidityFee(uint256 _fee) external onlyConfigurator {
        liquidityFee = _fee;
    }

    ///////////////
    // LIQUIDITY //
    ///////////////

    function addLiquidity(uint256 _amount, address _tokenIn) external nonReentrant {
        _addLiquidity(msg.sender, _amount, _tokenIn);
    }

    function removeLiquidity(uint256 _marketTokenAmount, address _tokenOut) external nonReentrant {
        _removeLiquidity(msg.sender, _marketTokenAmount, _tokenOut);
    }

    // allows users to delegate permissions from ledger to hot wallet
    function addLiquidityForAccount(address _account, uint256 _amount, address _tokenIn) external nonReentrant {
        // check if msg.sender is approved to add liquidity for _account
        _addLiquidity(_account, _amount, _tokenIn);
    }

    // allows users to delegate permissions from ledger to hot wallet
    function removeLiquidityForAccount(address _account, uint256 _liquidityTokenAmount, address _tokenOut) external nonReentrant {
        // check if msg.sender is approved to remove liquidity for _account
        _removeLiquidity(_account, _liquidityTokenAmount, _tokenOut);
    }

    // subtract fees, many additional safety checks needed
    function _addLiquidity(address _account, uint256 _amount, address _tokenIn) internal {
        require(_amount > 0, "Invalid amount");
        require(_tokenIn == stablecoin, "Invalid token");

        uint256 afterFeeAmount = _deductLiquidityFees(_amount);
        
        IERC20(_tokenIn).safeTransferFrom(_account, address(this), _amount);

        // add full amount to the pool
        poolAmounts[_tokenIn] += _amount;

        // mint market tokens (afterFeeAmount)
        uint256 mintAmount = (afterFeeAmount * getPrice(_tokenIn)) / getMarketTokenPrice();

        liquidityToken.mint(_account, mintAmount);

        _updateMarketAllocations();
    }

    // subtract fees, many additional safety checks needed
    function _removeLiquidity(address _account, uint256 _liquidityTokenAmount, address _tokenOut) internal {
        require(_liquidityTokenAmount > 0, "Invalid amount");
        require(_tokenOut == stablecoin, "Invalid token");

        // remove liquidity from the market
        uint256 marketTokenValue = _liquidityTokenAmount * getMarketTokenPrice();

        uint256 tokenAmount = marketTokenValue / getPrice(_tokenOut);

        poolAmounts[_tokenOut] -= tokenAmount;

        liquidityToken.burn(_account, _liquidityTokenAmount);

        uint256 afterFeeAmount = _deductLiquidityFees(tokenAmount);

        IERC20(_tokenOut).safeTransfer(_account, afterFeeAmount);

        _updateMarketAllocations();
    }

    /////////////
    // PRICING //
    /////////////

    // must factor in worth of all tokens deposited, pending PnL, pending borrow fees
    // price per 1 token (1e18 decimals)
    // returns price of token in USD x 1e30
    function getMarketTokenPrice() public view returns (uint256) {
        // market token price = (worth of market pool) / total supply
        return (getAum() * PRICE_PRECISION) / IERC20(address(liquidityToken)).totalSupply();
    }

    // Returns AUM in USD value
    function getAum() public view returns (uint256 aum) {
        // get the AUM of the market in USD
        // must factor in worth of all tokens deposited, pending PnL, pending borrow fees
        // liquidity in USD
        uint256 liquidity = (poolAmounts[stablecoin] * getPrice(stablecoin));
        aum = liquidity;
        int256 pendingPnL = _getNetPnL(true) + _getNetPnL(false);
        pendingPnL > 0 ? aum -= uint256(pendingPnL) : aum += uint256(pendingPnL); // if in profit, subtract, if at loss, add
        return aum;
    }

    function getPrice(address _token) public view returns (uint256) {
        // perform safety checks
        return _getPrice(_token);
    }

    function _getPrice(address _token) internal view returns (uint256) {
        // call the oracle contract and return the price of the token passed in as an argument
    }

    /////////
    // PNL //
    /////////

    function getNetPnL(bool _isLong) public view returns (int256) {
        return _getNetPnL(_isLong);
    }

    // should loops through all markets and add together their net PNL in USD
    function _getNetPnL(bool _isLong) internal view returns (int256) {
        int256 netPnL;
        uint256 len = marketKeys.length;
        for (uint256 i = 0; i < len; ++i) {
            address market = markets[marketKeys[i]].market;
            netPnL += IMarket(market).getNetPnL(_isLong);
        }
        return netPnL;
    }

    ///////////////////
    // OPEN INTEREST //
    ///////////////////

    function getNetOpenInterest() public view returns (uint256) {
        uint256 total = 0;
        uint256 len = marketKeys.length;
        for (uint256 i = 0; i < len; ++i) {
            address market = markets[marketKeys[i]].market;
            total += IMarket(market).getTotalOpenInterest();
        }
        return total;
    }

    //////////
    // FEES //
    //////////

    // (amount x percentage) / 100%
    function _deductLiquidityFees(uint256 _amount) internal view returns (uint256) {
        return (_amount * (PERCENTAGE_PRECISION - liquidityFee)) / PERCENTAGE_PRECISION;
    }

    /// @dev Only to be called by TradeStorage
    function accumulateFundingFees(uint256 _amount, address _account) external nonReentrant onlyTradeStorage {
        fundingFeesEarned[_account] += _amount;
    }

    // called by a trader to claim their earned funding fees
    // only become claimable once a position is edited
    function claimFundingFees() external nonReentrant {
        uint256 amount = fundingFeesEarned[msg.sender];
        require(amount > 0, "No fees to claim");
        fundingFeesEarned[msg.sender] = 0;
        IERC20(stablecoin).safeTransfer(msg.sender, amount);
    }

    /////////////////
    // ALLOCATIONS //
    /////////////////

    /// @dev Only Executor
    function updateMarketAllocations() external onlyExecutor {
        _updateMarketAllocations();
    }

    /*
        numerator = total OI
        denominator = OI of market minus overcollateralization
        e.g if overCollateralization = 150% / 3/2 => (OI of Market x 2/3) = denominator
        divisor = numerator / denominator (e.g 7 = 1/7 of the AUM)
     */
    // gas intensive function for LPs and traders to call every time, keeper style preferable
    // called by the market when a trade is opened, or call periodically from a keeper
    // or call from provide/remove liquidity functions
    function _updateMarketAllocations() internal {
        // loop through all markets and update their allocations
        uint256 len = marketKeys.length;
        uint256 totalOpenInterest = getNetOpenInterest();
        uint256 aum = getAum();
        for (uint256 i = 0; i < len; ++i) {
            // get the markets open interest
            uint256 marketOpenInterest = IMarket(markets[marketKeys[i]].market).getTotalOpenInterest();
            uint256 overCollateralizedMarketOI = (marketOpenInterest * PERCENTAGE_PRECISION) / overCollateralizationPercentage;
            uint256 percentageAllocation = totalOpenInterest / overCollateralizedMarketOI;
            // allocate a percentage of the treasury to the market
            marketAllocations[marketKeys[i]] = aum / percentageAllocation; // this will be the amount of stablecoin allocated to the market
        }
    }
}
