// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.21;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IMarketToken} from "./interfaces/IMarketToken.sol";
import {MarketStructs} from "./MarketStructs.sol";
import {IMarket} from "./interfaces/IMarket.sol";
import {RoleValidation} from "../access/RoleValidation.sol";
import {ReentrancyGuard} from "@solmate/utils/ReentrancyGuard.sol";
import {IWUSDC} from "../token/interfaces/IWUSDC.sol";
import {IDataOracle} from "../oracle/interfaces/IDataOracle.sol";
import {IPriceOracle} from "../oracle/interfaces/IPriceOracle.sol";

/// @dev Needs Vault Role
contract LiquidityVault is RoleValidation, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeERC20 for IMarketToken;
    using MarketStructs for MarketStructs.Market;

    uint256 public constant STATE_UPDATE_INTERVAL = 5 seconds;
    uint256 public constant SCALING_FACTOR = 1e18;

    IWUSDC public immutable WUSDC;
    IMarketToken public immutable liquidityToken;
    IDataOracle public dataOracle;
    IPriceOracle public priceOracle;

    /// @dev Amount of liquidity in the pool
    uint256 public poolAmounts;
    uint256 public totalReserved;
    mapping(address => uint256) public reservedAmounts;
    mapping(address _handler => mapping(address _lp => bool _isHandler)) public isHandler;

    uint256 public accumulatedFees;
    uint256 public liquidityFee;
    bool private isInitialised;

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
    error LiquidityVault_InsufficientReserves();
    error LiquidityVault_AlreadyInitialised();

    // liquidity token = market token
    constructor(address _wusdc, address _liquidityToken, address _roleStorage) RoleValidation(_roleStorage) {
        if (address(_wusdc) == address(0)) revert LiquidityVault_InvalidToken();
        if (_liquidityToken == address(0)) revert LiquidityVault_InvalidToken();
        WUSDC = IWUSDC(_wusdc);
        liquidityToken = IMarketToken(_liquidityToken);
    }

    receive() external payable {}

    function initialise(address _dataOracle, address _priceOracle, uint256 _liquidityFee) external onlyAdmin {
        if (isInitialised) revert LiquidityVault_AlreadyInitialised();
        if (_dataOracle == address(0)) revert LiquidityVault_ZeroAddress();
        dataOracle = IDataOracle(_dataOracle);
        priceOracle = IPriceOracle(_priceOracle);
        /// @dev Liquidity Fee needs 18 decimals => e.g 0.002e18 = 0.2% fee
        liquidityFee = _liquidityFee;
        isInitialised = true;
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

    function accumulateFees(uint256 _amount) external onlyFeeAccumulator {
        accumulatedFees += _amount;
        emit FeesAccumulated(_amount);
    }

    function transferPositionProfit(address _user, uint256 _amount) external onlyTradeStorage {
        // check enough in pool to transfer position
        if (_amount > poolAmounts) revert LiquidityVault_InsufficientFunds();
        // transfer collateral token to user
        poolAmounts -= _amount;
        IERC20(address(WUSDC)).safeTransfer(_user, _amount);
        emit ProfitTransferred(_user, _amount);
    }

    /// @dev Used to reserve / unreserve funds for open positions
    function updateReservation(address _user, int256 _amount) external onlyTradeStorage {
        if (_amount == 0) revert LiquidityVault_InvalidTokenAmount();
        uint256 amt;
        if (_amount > 0) {
            amt = uint256(_amount);
            totalReserved += amt;
            reservedAmounts[_user] += amt;
        } else {
            amt = uint256(-_amount);
            if (reservedAmounts[_user] < amt) revert LiquidityVault_InsufficientReserves();
            totalReserved -= amt;
            reservedAmounts[_user] -= amt;
        }
    }

    // $1 = 1e18
    function getLiquidityTokenPrice() public view returns (uint256) {
        // market token price = (worth of market pool in USD) / total supply
        uint256 aum = getAum();
        uint256 supply = IERC20(address(liquidityToken)).totalSupply();
        if (supply == 0 || aum == 0) {
            return 0;
        } else {
            return (aum * SCALING_FACTOR) / supply;
        }
    }

    // Returns AUM in USD value
    /// Need to reserve a portion of assets for open positions
    /// Can do for a reservedAmounts mapping for each position
    /// Users shouldn't be able to withdraw assets being used for open trades
    /// Markets need to remain liquid to pay out potential profits
    function getAum() public view returns (uint256 aum) {
        // pool amount * price / decimals
        uint256 liquidity = (poolAmounts * getPrice(address(WUSDC.USDC()))) / SCALING_FACTOR;
        aum = liquidity;
        // subtract pnl and reserved amounts => should only reflect available liquidity
        int256 pendingPnL = dataOracle.getCumulativeNetPnl();
        pendingPnL > 0 ? aum -= uint256(pendingPnL) : aum += uint256(pendingPnL);
        return aum;
    }

    function getAumInWusdc() public view returns (uint256) {
        uint256 price = priceOracle.getCollateralPrice();
        return (getAum() * price) / SCALING_FACTOR;
    }

    // Price has 18 DPs
    function getPrice(address _token) public view returns (uint256) {
        // perform safety checks
        return _getPrice(_token);
    }

    /// @dev Gas Inefficient -> Revisit
    function _addLiquidity(address _account, uint256 _amount) internal {
        if (_amount == 0) revert LiquidityVault_InvalidTokenAmount();
        if (_account == address(0)) revert LiquidityVault_ZeroAddress();

        // Transfer From User to Contract
        IERC20(WUSDC.USDC()).safeTransferFrom(msg.sender, address(this), _amount);
        // Wrap Stablecoin
        uint256 wusdcAmount = _wrapUsdc(_amount);
        // Deduct Fees
        uint256 afterFeeAmount = _deductLiquidityFees(wusdcAmount);
        // mint market tokens
        uint256 price = getPrice(address(WUSDC));

        uint256 valueUsd = (afterFeeAmount * price) / SCALING_FACTOR;
        uint256 aum = getAumInWusdc();
        uint256 supply = liquidityToken.totalSupply();

        uint256 mintAmount;

        if (aum == 0 || supply == 0) {
            mintAmount = valueUsd;
        } else {
            mintAmount = (valueUsd * supply) / aum;
        }

        // add full amount to the pool
        poolAmounts += wusdcAmount;

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
        uint256 aum = getAumInWusdc();
        uint256 supply = liquidityToken.totalSupply();

        uint256 tokenAmount = (_liquidityTokenAmount * aum) / supply;

        if (tokenAmount > poolAmounts) revert LiquidityVault_InsufficientFunds();

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
        address usdc = WUSDC.USDC();
        IERC20(usdc).approve(address(WUSDC), _amount);
        return WUSDC.deposit(_amount);
    }

    function _unwrapUsdc(uint256 _amount) internal returns (uint256) {
        return WUSDC.withdraw(_amount);
    }

    function _validateHandler(address _sender, address _handler) internal view {
        if (!isHandler[_sender][_handler]) revert LiquidityVault_InvalidHandler();
    }

    function _getPrice(address _token) internal view returns (uint256) {
        if (_token == address(WUSDC) || _token == address(WUSDC.USDC())) {
            return 1e18;
            /// @dev Fix upon oracle implementation
        } else {
            return 1000e18;
        }
    }

    // Returns % amount after fee deduction
    function _deductLiquidityFees(uint256 _amount) internal returns (uint256) {
        uint256 divisor = SCALING_FACTOR / liquidityFee; // e.g 0.05 = % 20
        uint256 liqFee = _amount / divisor;
        accumulatedFees += liqFee;
        return _amount - liqFee;
    }
}
