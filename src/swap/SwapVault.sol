// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// Contract for storing all liquidity for swaps
// Kept separately from Liquidity Vault as LPs are exposed to more risk
// Accepts BTC, ETH, and Stablecoins
// Users can swap into stablecoins to trade with (trading is stable only)
// Users can swap out of stablecoins to withdraw (withdrawals are stable only)
// Based on the GMX V1 Architecture but only swaps
// Needs price impact to keep liquidity balanced between assets
// Priced by Oracles
// Dynamic fees to keep liquidity at target levels
// Aim for around 50% stables -> the rest BTC / ETH (30% ETH, 20% BTC)

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IMarketToken} from "../markets/interfaces/IMarketToken.sol";
import {RoleValidation} from "../access/RoleValidation.sol";
import {ReentrancyGuard} from "@solmate/utils/ReentrancyGuard.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {UD60x18, ud, unwrap} from "@prb/math/UD60x18.sol";


/// Note Anything that's common between this contract and the LiquidityVault,
/// we can create a parent contract and inherit from it
contract SwapVault is RoleValidation, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    
    IMarketToken public liquidityToken;

    // Whitelist only select assets
    mapping (address => bool) public whitelistedTokens;
    address[] public tokens;
    // Store target weights for dynamic fees
    mapping(address => uint256) public tokenWeights;
    // Store amount of assets in the pool
    mapping (address => uint256) public poolAmounts;
    mapping(address => uint256) public accumulatedFees;
    mapping (address _account => mapping (address _handler => bool)) public isHandler;

    uint256 public constant MAX_FEE = 1.0e18;

    uint256 public totalTokenWeights; // tokenWeight / totalTokenWeights = ideal composition
    uint256 public baseFee = 0.1e18; // 0.1%


    event LiquidityAdded(address indexed token, uint256 amount, uint256 mintAmount);
    event LiquidityWithdrawn(address account, address tokenOut, uint256 liquidityTokenAmount, uint256 amountOut);
    
    error SwapVault_InvalidTokenAmount();
    error SwapVault_InvalidToken();
    error SwapVault_ZeroAddress();
    error SwapVault_InvalidHandler();
    error SwapVault_InsufficientFunds();
    error SwapVault_AlreadyInitialized();
    error SwapVault_InsufficientOutputAmount();

    constructor (IMarketToken _liquidityToken) RoleValidation(roleStorage) {
        liquidityToken = _liquidityToken;
    }

    function whitelistToken(address _token) external onlyAdmin {
        whitelistedTokens[_token] = true;
        tokens.push(_token);
    }

    function unwhitelistToken(address _token) external onlyAdmin {
        whitelistedTokens[_token] = false;
        for (uint256 i = 0; i < tokens.length; ++i) {
            if (tokens[i] == _token) {
                tokens[i] = tokens[tokens.length - 1];
                tokens.pop();
                break;
            }
        }
    }

    function swap(uint256 _amount, address _tokenIn, address _tokenOut, uint256 _minOut) external returns (uint256) {
        _validateSwap(_amount, _tokenIn, _tokenOut);
        // transfer tokens in from the user
        IERC20(_tokenIn).safeTransferFrom(msg.sender, address(this), _amount);
        // deduct fees
        uint256 afterFeeAmount = _deductSwapFees(_amount, _tokenIn);
        // check the price impact
        uint256 priceImpact = _calculateSwapPriceImpact(afterFeeAmount, _tokenIn, _tokenOut);
        // calculate the amount out
        uint256 amountOut = afterFeeAmount * getPrice(_tokenIn) / getPrice(_tokenOut);
        amountOut = unwrap(ud(amountOut).sub(ud(amountOut).mul(ud(priceImpact))));
        // validate amount out > min out
        if (amountOut < _minOut) revert SwapVault_InsufficientOutputAmount();
        // update contract state
        poolAmounts[_tokenIn] += _amount;
        poolAmounts[_tokenOut] -= amountOut;
        // transfer tokens out to the user
        IERC20(_tokenOut).safeTransfer(msg.sender, amountOut);
        return amountOut;
    }

    // function to add liquidity
    /// @dev Need to add function to add liquidity in ETH
    function addLiquidity(address _account, uint256 _amount, address _tokenIn) external {
        _addLiquidity(_account, _amount, _tokenIn);
    }

    function addLiquidityForAccount(address _account, uint256 _amount, address _tokenIn) external {
        // check if account is approved to spend
        _validateHandler(_account, msg.sender);
        // call addLiquidity
        _addLiquidity(_account, _amount, _tokenIn);
    }

    // function to remove liquidity
    /// @dev Need to add function to remove liquidity in ETH
    function removeLiquidity(address _account, uint256 _liquidityTokenAmount, address _tokenOut) external {
        _removeLiquidity(_account, _liquidityTokenAmount, _tokenOut);
    }

    function removeLiquidityForAccount(address _account, uint256 _liquidityTokenAmount, address _tokenOut) external {
        // check if account is approved to spend
        _validateHandler(_account, msg.sender);
        // call removeLiquidity
        _removeLiquidity(_account, _liquidityTokenAmount, _tokenOut);
    }

    // Get Price

    function getPrice(address _token) public view returns (uint256) {
        // perform safety checks
        return _getPrice(_token);
    }

    // price per 1 token (1e18 decimals)
    // returns price of token in USD => $1 = 1e18
    function getMarketTokenPrice() public view returns (uint256) {
        // market token price = (worth of market pool) / total supply
        UD60x18 aum = ud(getAum());
        UD60x18 supply = ud(IERC20(address(liquidityToken)).totalSupply());
        return unwrap(aum.div(supply));
    }

    // Returns AUM in USD value
    function getAum() public view returns (uint256 aum) {
        uint256 total;
        for (uint256 i = 0; i < tokens.length; ++i) {
            total += poolAmounts[tokens[i]] * getPrice(tokens[i]);
        }
        return total;
    }

    // subtract fees, many additional safety checks needed
    function _addLiquidity(address _account, uint256 _amount, address _tokenIn) internal {
        if (_amount == 0) revert SwapVault_InvalidTokenAmount();
        if (!whitelistedTokens[_tokenIn]) revert SwapVault_InvalidToken();
        if (_account == address(0)) revert SwapVault_ZeroAddress();

        uint256 afterFeeAmount = _deductLpFees(_amount, _tokenIn);

        IERC20(_tokenIn).safeTransferFrom(_account, address(this), _amount);

        // add full amount to the pool
        poolAmounts[_tokenIn] += _amount;

        // mint market tokens (afterFeeAmount)
        uint256 mintAmount = (afterFeeAmount * getPrice(_tokenIn)) / getMarketTokenPrice();

        liquidityToken.mint(_account, mintAmount);
        emit LiquidityAdded(_account, _amount, mintAmount);
    }

    // subtract fees, many additional safety checks needed
    function _removeLiquidity(address _account, uint256 _liquidityTokenAmount, address _tokenOut) internal {
        if (_liquidityTokenAmount == 0) revert SwapVault_InvalidTokenAmount();
        if (!whitelistedTokens[_tokenOut]) revert SwapVault_InvalidToken();
        if (_account == address(0)) revert SwapVault_ZeroAddress();

        // remove liquidity from the market
        UD60x18 marketTokenValue = ud(_liquidityTokenAmount * getMarketTokenPrice());
        UD60x18 price = ud(getPrice(_tokenOut));
        uint256 tokenAmount = unwrap(marketTokenValue.div(price));

        poolAmounts[_tokenOut] -= tokenAmount;

        liquidityToken.burn(_account, _liquidityTokenAmount);

        uint256 afterFeeAmount = _deductLpFees(tokenAmount, _tokenOut);

        IERC20(_tokenOut).safeTransfer(_account, afterFeeAmount);
        emit LiquidityWithdrawn(_account, _tokenOut, _liquidityTokenAmount, afterFeeAmount);
    }

    function _validateSwap(uint256 _amountIn, address _tokenIn, address _tokenOut) internal view {
        if (IERC20(_tokenIn).balanceOf(msg.sender) < _amountIn) revert SwapVault_InsufficientFunds();
        if (!whitelistedTokens[_tokenIn]) revert SwapVault_InvalidToken();
        if (!whitelistedTokens[_tokenOut]) revert SwapVault_InvalidToken();
        if (_tokenIn == _tokenOut) revert SwapVault_InvalidToken();
        if (_amountIn == 0) revert SwapVault_InvalidTokenAmount();
    }

    function _getPrice(address _token) internal view returns (uint256) {
        // call the oracle contract and return the price of the token passed in as an argument
    }

    function _deductSwapFees(uint256 _amount, address _tokenIn) internal returns (uint256) {
        uint256 fee = unwrap(ud(baseFee).mul(ud(_amount)));
        accumulatedFees[_tokenIn] += fee;
        return _amount - fee;
    }

    function _deductLpFees(uint256 _amount, address _tokenIn) internal returns (uint256) {
        uint256 aum = getAum();
        uint256 actionSize = _amount * getPrice(_tokenIn);
        uint256 aumAfter = aum + actionSize;
        uint256 tokenComposition = poolAmounts[_tokenIn] * getPrice(_tokenIn) / aum;
        uint256 compositionAfter = (poolAmounts[_tokenIn] * getPrice(_tokenIn)) + actionSize / aumAfter;
        uint256 targetComposition = tokenWeights[_tokenIn] / totalTokenWeights;

        uint256 deltaBefore = tokenComposition > targetComposition ? tokenComposition - targetComposition : targetComposition - tokenComposition;
        uint256 deltaAfter = compositionAfter > targetComposition ? compositionAfter - targetComposition : targetComposition - compositionAfter;

        if ( deltaAfter < deltaBefore ) { // Action moves towards target
            uint256 fee = unwrap(ud(baseFee).mul(ud(_amount)));
            accumulatedFees[_tokenIn] += fee;
            return _amount - fee;
        } else { // Action moves away from target
            uint256 dynamicFee = deltaAfter / targetComposition;
            uint256 feeBps = dynamicFee > MAX_FEE ? MAX_FEE : dynamicFee;
            uint256 fee = unwrap(ud(feeBps).mul(ud(_amount)));
            accumulatedFees[_tokenIn] += fee;
            return _amount - fee;
        }
    }

    /*
        if (delta(tr,cr) < delta(tr, ar)) {
            priceImpact = delta(tr,ar) / tr
        } else {
            priceImpact = 0
        }
    */
    function _calculateSwapPriceImpact(uint256 _amount, address _tokenIn, address _tokenOut) internal view returns (uint256) {
        uint256 priceIn = _getPrice(_tokenIn);
        uint256 priceOut = _getPrice(_tokenOut);
        uint256 amountUsd = _amount * priceIn;
        uint256 poolInUsd = poolAmounts[_tokenIn] * priceIn;
        uint256 poolOutUsd = poolAmounts[_tokenOut] * priceOut;
        uint256 targetRatio = tokenWeights[_tokenIn] / tokenWeights[_tokenOut];
        uint256 currentRatio = poolInUsd / poolOutUsd;
        uint256 afterRatio = (poolInUsd + amountUsd) / (poolOutUsd - amountUsd);

        uint256 currentDelta = currentRatio > targetRatio ? currentRatio - targetRatio : targetRatio - currentRatio;
        uint256 afterDelta = afterRatio > targetRatio ? afterRatio - targetRatio : targetRatio - afterRatio;

        if (currentDelta < afterDelta) {
            return afterDelta / targetRatio;
        } else {
            return 0;
        }
    }

    function _validateHandler(address _account, address _handler) internal view {
        // check if account is approved to spend
        if (!isHandler[_account][_handler]) revert SwapVault_InvalidHandler();
    }

}
