// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IMarketToken} from "./interfaces/IMarketToken.sol";
import {MarketStructs} from "./MarketStructs.sol";
import {IMarket} from "./interfaces/IMarket.sol";
import {RoleValidation} from "../access/RoleValidation.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {UD60x18, ud, unwrap} from "@prb/math/UD60x18.sol";

/// @dev Needs Vault Role
/// Note REPLACE WITH SOLMATE REENTRANCY GUARD
contract LiquidityVault is RoleValidation, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using MarketStructs for MarketStructs.Market;
    using SafeCast for int256;

    uint256 public constant STATE_UPDATE_INTERVAL = 5 seconds;

    address public collateralToken;
    IMarketToken public liquidityToken;
    uint256 public liquidityFee; // 0.2% fee on all liquidity added/removed => 1e18 = 100%

    /// Note Will run into trouble because USDC is 6 decimals
    mapping(address _token => uint256 _poolAmount) public poolAmounts;
    mapping (address _handler => mapping(address _lp => bool _isHandler)) public isHandler;

    // fees handled by fee handler contract
    // claim from here, reset to 0, send to fee handler
    // divide fees and handled distribution in fee handler
    // trading fees, LP fees and borrow fees
    uint256 public accumulatedFees;

    uint256 public lastStateUpdate; // last time state was updated by keepers
    bool public upkeepNeeded; // is a new state update required?

    uint256 private cachedNetOI;
    int256 private cachedNetPnL;

    error LiquidityVault_InvalidTokenAmount();
    error LiquidityVault_InvalidToken();
    error LiquidityVault_UpkeepNotNeeded();
    error LiquidityVault_ZeroAddress();
    error LiquidityVault_InvalidHandler();

    // liquidity token = market token
    // another contract should handle minting and burning of LP token
    // change to intialize function
    constructor(address _collateralToken, IMarketToken _liquidityToken) RoleValidation(roleStorage) {
        collateralToken = _collateralToken;
        liquidityToken = _liquidityToken;
        liquidityFee = 0.02e18;
    }

    //////////////
    // SETTERS //
    ////////////

    /// @dev only GlobalMarketConfig
    function updateLiquidityFee(uint256 _fee) external onlyConfigurator {
        liquidityFee = _fee;
    }

    function setIsHandler(address _handler, bool _isHandler) external {
        isHandler[_handler][msg.sender] = _isHandler;
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

    function addLiquidityForAccount(address _account, uint256 _amount, address _tokenIn) external nonReentrant {
        _validateHandler(msg.sender, _account);
        _addLiquidity(_account, _amount, _tokenIn);
    }

    function removeLiquidityForAccount(address _account, uint256 _liquidityTokenAmount, address _tokenOut)
        external
        nonReentrant
    {
        _validateHandler(msg.sender, _account);
        _removeLiquidity(_account, _liquidityTokenAmount, _tokenOut);
    }

    // subtract fees, many additional safety checks needed
    function _addLiquidity(address _account, uint256 _amount, address _tokenIn) internal {
        if (_amount == 0) revert LiquidityVault_InvalidTokenAmount();
        if (_tokenIn != collateralToken) revert LiquidityVault_InvalidToken();
        if (_account == address(0)) revert LiquidityVault_ZeroAddress();

        uint256 afterFeeAmount = _deductLiquidityFees(_amount);

        IERC20(_tokenIn).safeTransferFrom(_account, address(this), _amount);

        // add full amount to the pool
        poolAmounts[_tokenIn] += _amount;

        // mint market tokens (afterFeeAmount)
        uint256 mintAmount = (afterFeeAmount * getPrice(_tokenIn)) / getMarketTokenPrice();

        liquidityToken.mint(_account, mintAmount);
    }

    // subtract fees, many additional safety checks needed
    function _removeLiquidity(address _account, uint256 _liquidityTokenAmount, address _tokenOut) internal {
        if (_liquidityTokenAmount == 0) revert LiquidityVault_InvalidTokenAmount();
        if (_tokenOut != collateralToken) revert LiquidityVault_InvalidToken();
        if (_account == address(0)) revert LiquidityVault_ZeroAddress();

        // remove liquidity from the market
        UD60x18 marketTokenValue = ud(_liquidityTokenAmount * getMarketTokenPrice());
        UD60x18 price = ud(getPrice(_tokenOut));
        uint256 tokenAmount = unwrap(marketTokenValue.div(price));

        poolAmounts[_tokenOut] -= tokenAmount;

        liquidityToken.burn(_account, _liquidityTokenAmount);

        uint256 afterFeeAmount = _deductLiquidityFees(tokenAmount);

        IERC20(_tokenOut).safeTransfer(_account, afterFeeAmount);
    }

    function _validateHandler(address _sender, address _handler) internal view {
        if (!isHandler[_sender][_handler]) revert LiquidityVault_InvalidHandler();
    }

    /////////////
    // PRICING //
    /////////////

    // must factor in worth of all tokens deposited, pending PnL, pending borrow fees
    // price per 1 token (1e18 decimals)
    // returns price of token in USD => $1 = 1e18
    function getMarketTokenPrice() public view returns (uint256) {
        // market token price = (worth of market pool) / total supply
        UD60x18 aum = ud(getAum());
        UD60x18 supply = ud(IERC20(address(liquidityToken)).totalSupply());
        return unwrap(aum.div(supply));
    }

    // Returns AUM in USD value
    /// do we need to include borrow fees?
    function getAum() public view returns (uint256 aum) {
        // get the AUM of the market in USD
        // must factor in worth of all tokens deposited, pending PnL, pending borrow fees
        // liquidity in USD
        uint256 liquidity = (poolAmounts[collateralToken] * getPrice(collateralToken));
        aum = liquidity;
        int256 pendingPnL = getNetPnL();
        pendingPnL > 0 ? aum -= pendingPnL.toUint256() : aum += pendingPnL.toUint256(); // if in profit, subtract, if at loss, add
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

    function getNetPnL() public view returns (int256) {
        return cachedNetPnL;
    }

    ///////////////////
    // OPEN INTEREST //
    ///////////////////

    function getNetOpenInterest() public view returns (uint256) {
        return cachedNetOI;
    }

    //////////
    // FEES //
    //////////

    // Returns % amount after fee deduction
    function _deductLiquidityFees(uint256 _amount) internal view returns (uint256) {
        UD60x18 amount = ud(_amount);
        UD60x18 liqFee = ud(liquidityFee);
        return _amount - unwrap(amount.mul(liqFee));
    }

    function accumulateFees(uint256 _amount) external onlyTradeStorage {
        accumulatedFees += _amount;
    }

    ///////////
    // STATE //
    ///////////

    /// Note Needs to be called by keepers to regularly update the state of the net pnl and OI
    /// @dev Computation kept separate to future-proof against gas constraints.
    function updateState(int256 _netPnL, uint256 _netOpenInterest) external onlyStateUpdater {
        if (block.timestamp < lastStateUpdate + STATE_UPDATE_INTERVAL) {
            revert LiquidityVault_UpkeepNotNeeded();
        }
        cachedNetPnL = _netPnL;
        cachedNetOI = _netOpenInterest;
    }
}
