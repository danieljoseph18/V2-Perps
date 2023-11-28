// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IMarketToken} from "./interfaces/IMarketToken.sol";
import {MarketStructs} from "./MarketStructs.sol";
import {IMarket} from "./interfaces/IMarket.sol";
import {RoleValidation} from "../access/RoleValidation.sol";
import {ReentrancyGuard} from "@solmate/utils/ReentrancyGuard.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {UD60x18, ud, unwrap} from "@prb/math/UD60x18.sol";
import {IWUSDC} from "../token/interfaces/IWUSDC.sol";
import {IDataOracle} from "../oracle/interfaces/IDataOracle.sol";

/// @dev Needs Vault Role
contract LiquidityVault is RoleValidation, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeERC20 for IMarketToken;
    using MarketStructs for MarketStructs.Market;
    using SafeCast for int256;

    uint256 public constant STATE_UPDATE_INTERVAL = 5 seconds;

    IWUSDC public immutable WUSDC;
    IMarketToken public liquidityToken;
    IDataOracle public dataOracle;

    /// @dev Amount of liquidity in the pool
    uint256 public poolAmounts;
    mapping(address _handler => mapping(address _lp => bool _isHandler)) public isHandler;

    uint256 public accumulatedFees;
    uint256 public liquidityFee;
    bool private isInitialized;

    event LiquidityFeeUpdated(uint256 liquidityFee);
    event HandlerSet(address handler, bool isHandler);
    event LiquidityAdded(address indexed token, uint256 amount, uint256 mintAmount);
    event LiquidityWithdrawn(address account, address tokenOut, uint256 liquidityTokenAmount, uint256 amountOut);
    event FeesAccumulated(uint256 indexed _amount);
    event ProfitTransferred(address indexed _user, uint256 indexed _amount);
    event StateUpdated(int256 indexed _netPnL, uint256 indexed _netOI);

    error LiquidityVault_InvalidTokenAmount();
    error LiquidityVault_InvalidToken();
    error LiquidityVault_UpkeepNotNeeded();
    error LiquidityVault_ZeroAddress();
    error LiquidityVault_InvalidHandler();
    error LiquidityVault_InsufficientFunds();
    error LiquidityVault_AlreadyInitialized();

    // liquidity token = market token
    constructor(IWUSDC _wusdc, IMarketToken _liquidityToken, IDataOracle _dataOracle, uint256 _liquidityFee)
        RoleValidation(roleStorage)
    {
        if (address(_wusdc) == address(0)) revert LiquidityVault_InvalidToken();
        if (_liquidityToken == IMarketToken(address(0))) revert LiquidityVault_InvalidToken();
        WUSDC = _wusdc;
        liquidityToken = _liquidityToken;
        dataOracle = _dataOracle;
        /// @dev Liquidity Fee needs 18 decimals => e.g 0.002e18 = 0.2% fee
        liquidityFee = _liquidityFee;
    }

    function setDataOracle(IDataOracle _dataOracle) external onlyAdmin {
        if (address(_dataOracle) == address(0)) revert LiquidityVault_ZeroAddress();
        dataOracle = _dataOracle;
    }

    /// @dev only GlobalMarketConfig
    function updateLiquidityFee(uint256 _liquidityFee) external onlyConfigurator {
        liquidityFee = _liquidityFee;
        emit LiquidityFeeUpdated(_liquidityFee);
    }

    function setIsHandler(address _handler, bool _isHandler) external {
        if (_handler == address(0)) revert LiquidityVault_ZeroAddress();
        if (_handler == msg.sender) revert LiquidityVault_InvalidHandler();
        isHandler[_handler][msg.sender] = _isHandler;
        emit HandlerSet(_handler, _isHandler);
    }

    function addLiquidity(uint256 _amount) external nonReentrant {
        _addLiquidity(msg.sender, _amount);
    }

    function removeLiquidity(uint256 _marketTokenAmount) external nonReentrant {
        _removeLiquidity(msg.sender, _marketTokenAmount);
    }

    function addLiquidityForAccount(address _account, uint256 _amount) external nonReentrant {
        _validateHandler(msg.sender, _account);
        _addLiquidity(_account, _amount);
    }

    function removeLiquidityForAccount(address _account, uint256 _liquidityTokenAmount) external nonReentrant {
        _validateHandler(msg.sender, _account);
        _removeLiquidity(_account, _liquidityTokenAmount);
    }

    function accumulateFees(uint256 _amount) external onlyTradeStorage {
        accumulatedFees += _amount;
        emit FeesAccumulated(_amount);
    }

    /// @dev To improve UX, we can add an unwrap step from P3USD to Stables
    /// To Accomplish this: We will need a checker for most abundant token
    /// in the P3 contract (or just default to USDC)
    function transferPositionProfit(address _user, uint256 _amount) external onlyTradeStorage {
        // check enough in pool to transfer position
        if (_amount > poolAmounts) revert LiquidityVault_InsufficientFunds();
        // transfer collateral token to user
        poolAmounts -= _amount;
        IERC20(address(WUSDC)).safeTransfer(_user, _amount);
        emit ProfitTransferred(_user, _amount);
    }

    // must factor in worth of all tokens deposited, pending PnL, pending borrow fees
    // price per 1 token (1e18 decimals)
    // returns price of token in USD => $1 = 1e18
    function getLiquidityTokenPrice() public view returns (uint256) {
        // market token price = (worth of market pool) / total supply
        UD60x18 aum = ud(getAum());
        UD60x18 supply = ud(IERC20(address(liquidityToken)).totalSupply());
        return unwrap(aum.div(supply));
    }

    // Returns AUM in USD value
    /// do we need to include borrow fees?
    function getAum() public view returns (uint256 aum) {
        uint256 liquidity = (poolAmounts * getPrice(address(WUSDC.USDC())));
        aum = liquidity;
        int256 pendingPnL = dataOracle.getCumulativeNetPnl();
        pendingPnL > 0 ? aum -= pendingPnL.toUint256() : aum += pendingPnL.toUint256(); // if in profit, subtract, if at loss, add
        return aum;
    }

    function getPrice(address _token) public view returns (uint256) {
        // perform safety checks
        return _getPrice(_token);
    }

    /// @dev Gas Inefficient -> Revisit
    function _addLiquidity(address _account, uint256 _amount) internal {
        if (_amount == 0) revert LiquidityVault_InvalidTokenAmount();
        if (_account == address(0)) revert LiquidityVault_ZeroAddress();

        // Transfer From User to Contract
        IERC20(WUSDC.USDC()).safeTransferFrom(_account, address(this), _amount);
        // Wrap Stablecoin
        uint256 wusdcAmount = _wrapUsdc(_amount);
        // Deduct Fees
        uint256 afterFeeAmount = _deductLiquidityFees(wusdcAmount);
        // add full amount to the pool
        poolAmounts += wusdcAmount;

        // mint market tokens (afterFeeAmount)
        uint256 mintAmount =
            unwrap((ud(afterFeeAmount).mul(ud(getPrice(address(WUSDC))))).div(ud(getLiquidityTokenPrice())));
        liquidityToken.mint(_account, mintAmount);
        // Fire event
        emit LiquidityAdded(_account, wusdcAmount, mintAmount);
    }

    /// @dev Gas Inefficient -> Revisit
    function _removeLiquidity(address _account, uint256 _liquidityTokenAmount) internal {
        if (_liquidityTokenAmount == 0) revert LiquidityVault_InvalidTokenAmount();
        if (_account == address(0)) revert LiquidityVault_ZeroAddress();

        // Transfer LP Tokens from User to Contract
        liquidityToken.safeTransferFrom(_account, address(this), _liquidityTokenAmount);

        // remove liquidity from the market
        UD60x18 liquidityTokenValue = ud(_liquidityTokenAmount * getLiquidityTokenPrice());
        UD60x18 price = ud(getPrice(address(WUSDC)));
        uint256 tokenAmount = unwrap(liquidityTokenValue.div(price));

        poolAmounts -= tokenAmount;

        liquidityToken.burn(address(this), _liquidityTokenAmount);
        // Deduct Fees
        uint256 afterFeeAmount = _deductLiquidityFees(tokenAmount);
        // Unwrap
        uint256 tokenOutAmount = _unwrapUsdc(afterFeeAmount);
        // Transfer Stablecoin to User
        IERC20(WUSDC.USDC()).safeTransfer(_account, tokenOutAmount);
        // Fire event
        emit LiquidityWithdrawn(_account, address(WUSDC), _liquidityTokenAmount, afterFeeAmount);
    }

    function _wrapUsdc(uint256 _amount) internal returns (uint256) {
        return WUSDC.deposit(_amount);
    }

    function _unwrapUsdc(uint256 _amount) internal returns (uint256) {
        return WUSDC.withdraw(_amount);
    }

    function _validateHandler(address _sender, address _handler) internal view {
        if (!isHandler[_sender][_handler]) revert LiquidityVault_InvalidHandler();
    }

    function _getPrice(address _token) internal view returns (uint256) {
        // call the oracle contract and return the price of the token passed in as an argument
    }

    // Returns % amount after fee deduction
    function _deductLiquidityFees(uint256 _amount) internal returns (uint256) {
        UD60x18 amount = ud(_amount);
        UD60x18 liqFee = ud(liquidityFee).mul(amount);
        accumulatedFees += unwrap(liqFee);
        return unwrap(amount.sub(liqFee));
    }
}
