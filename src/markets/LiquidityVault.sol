//  ,----,------------------------------,------.
//   | ## |                              |    - |
//   | ## |                              |    - |
//   |    |------------------------------|    - |
//   |    ||............................||      |
//   |    ||,-                        -.||      |
//   |    ||___                      ___||    ##|
//   |    ||---`--------------------'---||      |
//   `--mb'|_|______________________==__|`------'

//    ____  ____  ___ _   _ _____ _____ ____
//   |  _ \|  _ \|_ _| \ | |_   _|___ /|  _ \
//   | |_) | |_) || ||  \| | | |   |_ \| |_) |
//   |  __/|  _ < | || |\  | | |  ___) |  _ <
//   |_|   |_| \_\___|_| \_| |_| |____/|_| \_\

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.22;

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

    uint256 public constant SCALING_FACTOR = 1e18;
    uint256 public constant MIN_LIQUIDITY_FEE = 0.0001e18; // 0.01%
    uint256 public constant MAX_LIQUIDITY_FEE = 0.01e18; // 1%

    IWUSDC public immutable WUSDC;
    IERC20 public immutable USDC;
    IMarketToken public immutable liquidityToken;

    IDataOracle public dataOracle;
    IPriceOracle public priceOracle;

    /// @dev Amount of liquidity in the pool
    uint256 public poolAmounts;
    uint256 public totalReserved;
    mapping(address => uint256) public reservedAmounts;
    mapping(address _handler => mapping(address _lp => bool _isHandler)) public isHandler;

    uint256 public accumulatedFees;
    uint256 public liquidityFee; // 18 D.P
    bool private isInitialised;

    event LiquidityFeeUpdated(uint256 indexed liquidityFee);
    event HandlerSet(address indexed handler, bool indexed isHandler);
    event LiquidityAdded(address indexed token, uint256 indexed amount, uint256 indexed mintAmount);
    event LiquidityWithdrawn(
        address indexed account, address indexed tokenOut, uint256 indexed liquidityTokenAmount, uint256 amountOut
    );
    event FeesAccumulated(uint256 indexed _amount);
    event ProfitTransferred(address indexed _user, uint256 indexed _amount);
    event StateUpdated(int256 indexed _netPnL, uint256 indexed _netOI);
    event LiquidityReserved(address indexed _user, uint256 indexed _amount, bool indexed _isIncrease);

    error LiquidityVault_InvalidTokenAmount();
    error LiquidityVault_InvalidToken();
    error LiquidityVault_UpkeepNotNeeded();
    error LiquidityVault_ZeroAddress();
    error LiquidityVault_InvalidHandler();
    error LiquidityVault_InsufficientFunds();
    error LiquidityVault_InsufficientReserves();
    error LiquidityVault_AlreadyInitialised();
    error LiquidityVault_LiquidityFeeOutOfBounds();
    error LiquidityVault_InsufficientLiquidity();
    error LiquidityVault_CallerIsAContract();

    // liquidity token = market token
    constructor(address _wusdc, address _liquidityToken, address _roleStorage) RoleValidation(_roleStorage) {
        if (address(_wusdc) == address(0)) revert LiquidityVault_InvalidToken();
        if (_liquidityToken == address(0)) revert LiquidityVault_InvalidToken();
        WUSDC = IWUSDC(_wusdc);
        USDC = WUSDC.USDC();
        liquidityToken = IMarketToken(_liquidityToken);
    }

    receive() external payable {}

    function initialise(address _dataOracle, address _priceOracle, uint256 _liquidityFee) external onlyAdmin {
        if (isInitialised) revert LiquidityVault_AlreadyInitialised();
        if (_dataOracle == address(0) || _priceOracle == address(0)) revert LiquidityVault_ZeroAddress();
        if (_liquidityFee < MIN_LIQUIDITY_FEE || _liquidityFee > MAX_LIQUIDITY_FEE) {
            revert LiquidityVault_LiquidityFeeOutOfBounds();
        }
        dataOracle = IDataOracle(_dataOracle);
        priceOracle = IPriceOracle(_priceOracle);
        liquidityFee = _liquidityFee;
        isInitialised = true;
    }

    function setDataOracle(IDataOracle _dataOracle) external onlyAdmin {
        if (address(_dataOracle) == address(0)) revert LiquidityVault_ZeroAddress();
        dataOracle = _dataOracle;
    }

    function setPriceOracle(IPriceOracle _priceOracle) external onlyAdmin {
        if (address(_priceOracle) == address(0)) revert LiquidityVault_ZeroAddress();
        priceOracle = _priceOracle;
    }

    /// @dev only GlobalMarketConfig
    function updateLiquidityFee(uint256 _liquidityFee) external onlyConfigurator {
        if (_liquidityFee < MIN_LIQUIDITY_FEE || _liquidityFee > MAX_LIQUIDITY_FEE) {
            revert LiquidityVault_LiquidityFeeOutOfBounds();
        }
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

    // q - are fees being accumulated with universal units?
    // q - are we missing checks? what must hold true?
    function accumulateFees(uint256 _amount) external onlyFeeAccumulator {
        accumulatedFees += _amount;
        emit FeesAccumulated(_amount);
    }

    // q - do we need any input validation for _user?
    // e.g user could be a contract, could he reject this function call?
    // q - what must hold true in order to transfer profit to a user???
    function transferPositionProfit(address _user, uint256 _amount) external onlyTradeStorage {
        if (_amount == 0) revert LiquidityVault_InvalidTokenAmount();
        // check enough in pool to transfer position
        // q - is this check sufficient?
        if (_amount > poolAmounts) revert LiquidityVault_InsufficientFunds();
        // transfer collateral token to user
        poolAmounts -= _amount;
        IERC20(address(WUSDC)).safeTransfer(_user, _amount);
        emit ProfitTransferred(_user, _amount);
    }

    /// @dev Used to reserve / unreserve funds for open positions
    // q - do we need a reserve factor to cap reserves to a % of the available liquidity
    function updateReservation(address _user, int256 _amount) external onlyTradeStorage {
        if (_amount == 0) revert LiquidityVault_InvalidTokenAmount();
        uint256 amt;
        if (_amount > 0) {
            amt = uint256(_amount);
            if (amt > poolAmounts) revert LiquidityVault_InsufficientLiquidity();
            totalReserved += amt;
            reservedAmounts[_user] += amt;
        } else {
            amt = uint256(-_amount);
            if (reservedAmounts[_user] < amt) revert LiquidityVault_InsufficientReserves();
            totalReserved -= amt;
            reservedAmounts[_user] -= amt;
        }
        // Invariant Check
        assert(totalReserved <= poolAmounts);
        emit LiquidityReserved(_user, amt, _amount > 0);
    }

    // $1 = 1e18
    function getLiquidityTokenPrice() public view returns (uint256 lpTokenPrice) {
        // market token price = (worth of market pool in USD) / total supply
        uint256 aum = getAum();
        uint256 supply = IERC20(address(liquidityToken)).totalSupply();
        if (aum == 0 || supply == 0) {
            lpTokenPrice = 0;
        } else {
            lpTokenPrice = (aum * SCALING_FACTOR) / supply;
        }
    }

    // Returns AUM in USD value
    function getAum() public view returns (uint256 aum) {
        // pool amount * price / decimals
        uint256 price = priceOracle.getCollateralPrice();
        aum = (poolAmounts * price) / SCALING_FACTOR;
        // subtract losses, ignore profit => should only reflect available liquidity
        int256 pendingPnL = dataOracle.getCumulativeNetPnl();
        if (pendingPnL > 0) {
            aum -= uint256(pendingPnL);
        }
    }

    /// @dev Gas Inefficient -> Revisit
    function _addLiquidity(address _account, uint256 _amount) internal {
        if (_amount == 0) revert LiquidityVault_InvalidTokenAmount();
        if (_account == address(0)) revert LiquidityVault_ZeroAddress();

        uint256 initialPoolAmount = poolAmounts;
        uint256 initialAccumulatedFees = accumulatedFees;
        USDC.safeTransferFrom(msg.sender, address(this), _amount);

        uint256 wusdcAmount = _wrapUsdc(_amount);
        uint256 afterFeeAmount = _deductLiquidityFees(wusdcAmount);
        uint256 price = priceOracle.getCollateralPrice();
        uint256 valueUsd = (afterFeeAmount * price) / SCALING_FACTOR;
        uint256 lpTokenPrice = getLiquidityTokenPrice();
        uint256 mintAmount = lpTokenPrice == 0 ? valueUsd : (valueUsd * SCALING_FACTOR) / lpTokenPrice;
        poolAmounts += afterFeeAmount;

        liquidityToken.mint(_account, mintAmount);
        emit LiquidityAdded(_account, afterFeeAmount, mintAmount);

        uint256 feeAmount = wusdcAmount - afterFeeAmount;
        assert(poolAmounts == initialPoolAmount + afterFeeAmount); // Pool amount correctly increased
        assert(accumulatedFees == initialAccumulatedFees + feeAmount); // Fees correctly accumulated
        assert(wusdcAmount == afterFeeAmount + feeAmount); // Total wrapped amount accounted for
    }

    /// @dev Gas Inefficient -> Revisit
    function _removeLiquidity(address _account, uint256 _liquidityTokenAmount) internal {
        if (_liquidityTokenAmount == 0) revert LiquidityVault_InvalidTokenAmount();
        if (_account == address(0)) revert LiquidityVault_ZeroAddress();

        uint256 initialPoolAmount = poolAmounts;
        uint256 initialAccumulatedFees = accumulatedFees;
        liquidityToken.safeTransferFrom(_account, address(this), _liquidityTokenAmount);
        uint256 lpTokenValueUsd = (_liquidityTokenAmount * getLiquidityTokenPrice()) / SCALING_FACTOR;
        uint256 tokenAmount = (lpTokenValueUsd * SCALING_FACTOR) / priceOracle.getCollateralPrice();
        uint256 availableLiquidity = poolAmounts - totalReserved;

        // Ensures markets stay liquid
        if (tokenAmount > availableLiquidity) revert LiquidityVault_InsufficientFunds();

        poolAmounts -= tokenAmount;
        liquidityToken.burn(address(this), _liquidityTokenAmount);
        uint256 afterFeeAmount = _deductLiquidityFees(tokenAmount);
        uint256 tokenOutAmount = _unwrapUsdc(afterFeeAmount);

        USDC.safeTransfer(_account, tokenOutAmount);
        emit LiquidityWithdrawn(_account, address(WUSDC), _liquidityTokenAmount, afterFeeAmount);

        uint256 feeAmount = tokenAmount - afterFeeAmount;
        assert(poolAmounts == initialPoolAmount - tokenAmount); // Pool amount correctly decreased
        assert(accumulatedFees == initialAccumulatedFees + feeAmount); // Fees correctly accumulated
        assert(tokenAmount == afterFeeAmount + feeAmount); // Total wrapped amount accounted for
    }

    function _wrapUsdc(uint256 _amount) internal returns (uint256 wusdcAmount) {
        USDC.safeIncreaseAllowance(address(WUSDC), _amount);
        wusdcAmount = WUSDC.deposit(_amount);
    }

    function _unwrapUsdc(uint256 _amount) internal returns (uint256 usdcAmount) {
        usdcAmount = WUSDC.withdraw(_amount);
    }

    /// @dev Protects against arbitrary from address in transferFrom
    function _validateHandler(address _sender, address _handler) internal view {
        if (!isHandler[_sender][_handler]) revert LiquidityVault_InvalidHandler();
    }

    // Returns % amount after fee deduction
    function _deductLiquidityFees(uint256 _amount) internal returns (uint256 afterFeeAmount) {
        uint256 liqFee = (_amount * liquidityFee) / SCALING_FACTOR;
        accumulatedFees += liqFee;
        afterFeeAmount = _amount - liqFee;
    }
}
