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
pragma solidity 0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IMarketToken} from "./interfaces/IMarketToken.sol";
import {RoleValidation} from "../access/RoleValidation.sol";
import {ReentrancyGuard} from "@solmate/utils/ReentrancyGuard.sol";
import {IUSDE} from "../token/interfaces/IUSDE.sol";
import {IDataOracle} from "../oracle/interfaces/IDataOracle.sol";
import {IPriceOracle} from "../oracle/interfaces/IPriceOracle.sol";

/// @dev Needs Vault Role
contract LiquidityVault is RoleValidation, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeERC20 for IMarketToken;

    uint256 public constant SCALING_FACTOR = 1e18;
    uint256 public constant MIN_LIQUIDITY_FEE = 0.0001e18; // 0.01%
    uint256 public constant MAX_LIQUIDITY_FEE = 0.01e18; // 1%

    IUSDE public immutable USDE;
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

    // liquidity token = market token
    constructor(address _usde, address _liquidityToken, address _roleStorage) RoleValidation(_roleStorage) {
        require(address(_usde) != address(0), "LV: Zero Address");
        require(_liquidityToken != address(0), "LV: Zero Address");
        USDE = IUSDE(_usde);
        USDC = USDE.USDC();
        liquidityToken = IMarketToken(_liquidityToken);
    }

    receive() external payable {}

    function initialise(address _dataOracle, address _priceOracle, uint256 _liquidityFee) external onlyAdmin {
        require(!isInitialised, "LV: Already Initialised");
        require(_dataOracle != address(0) && _priceOracle != address(0), "LV: Zero Address");
        require(_liquidityFee >= MIN_LIQUIDITY_FEE && _liquidityFee <= MAX_LIQUIDITY_FEE, "LV: Invalid Liq Fee");
        dataOracle = IDataOracle(_dataOracle);
        priceOracle = IPriceOracle(_priceOracle);
        liquidityFee = _liquidityFee;
        isInitialised = true;
    }

    function setDataOracle(IDataOracle _dataOracle) external onlyAdmin {
        require(address(_dataOracle) != address(0), "LV: Zero Address");
        dataOracle = _dataOracle;
    }

    function setPriceOracle(IPriceOracle _priceOracle) external onlyAdmin {
        require(address(_priceOracle) != address(0), "LV: Zero Address");
        priceOracle = _priceOracle;
    }

    /// @dev only GlobalMarketConfig
    function updateLiquidityFee(uint256 _liquidityFee) external onlyConfigurator {
        require(_liquidityFee >= MIN_LIQUIDITY_FEE && _liquidityFee <= MAX_LIQUIDITY_FEE, "LV: Invalid Liq Fee");
        liquidityFee = _liquidityFee;
        emit LiquidityFeeUpdated(_liquidityFee);
    }

    function setIsHandler(address _handler, bool _isHandler) external {
        require(_handler != address(0), "LV: Zero Address");
        require(_handler != msg.sender, "LV: Invalid Handler");
        isHandler[_handler][msg.sender] = _isHandler;
        emit HandlerSet(_handler, _isHandler);
    }

    function addLiquidity(uint256 _amount) external nonReentrant {
        _addLiquidity(msg.sender, _amount);
    }

    function removeLiquidity(uint256 _liquidityTokenAmount) external nonReentrant {
        _removeLiquidity(msg.sender, _liquidityTokenAmount);
    }

    function addLiquidityForAccount(address _account, uint256 _amount) external nonReentrant {
        require(_account != msg.sender, "LV: Handler is Sender");
        require(isHandler[msg.sender][_account], "LV: Invalid Handler");
        _addLiquidity(_account, _amount);
    }

    function removeLiquidityForAccount(address _account, uint256 _liquidityTokenAmount) external nonReentrant {
        require(_account != msg.sender, "LV: Handler is Sender");
        require(isHandler[msg.sender][_account], "LV: Invalid Handler");
        _removeLiquidity(_account, _liquidityTokenAmount);
    }

    // q - are fees being accumulated with universal units?
    // q - are we missing checks? what must hold true?
    function accumulateFees(uint256 _amount) external onlyFeeAccumulator {
        require(_amount != 0, "LV: Invalid Acc Fee");
        accumulatedFees += _amount;
        emit FeesAccumulated(_amount);
    }

    // q - do we need any input validation for _user?
    // e.g user could be a contract, could he reject this function call?
    // q - what must hold true in order to transfer profit to a user???
    function transferPositionProfit(address _user, uint256 _amount) external onlyTradeStorage {
        require(_amount != 0, "LV: Invalid Profit Amount");
        require(_user != address(0), "LV: Zero Address");
        // check enough in pool to transfer position
        require(_amount <= poolAmounts - totalReserved, "LV: Insufficient Funds");
        // transfer collateral token to user
        poolAmounts -= _amount;
        IERC20(address(USDE)).safeTransfer(_user, _amount);
        emit ProfitTransferred(_user, _amount);
    }

    /// @dev Used to reserve / unreserve funds for open positions
    // q - do we need a reserve factor to cap reserves to a % of the available liquidity
    function updateReservation(address _user, int256 _amount) external onlyTradeStorage {
        require(_amount != 0, "LV: Invalid Res Amount");
        uint256 amt;
        if (_amount > 0) {
            amt = uint256(_amount);
            require(amt <= poolAmounts, "LV: Insufficient Liq");
            totalReserved += amt;
            reservedAmounts[_user] += amt;
        } else {
            amt = uint256(-_amount);
            require(reservedAmounts[_user] >= amt, "LV: Insufficient Reserves");
            require(totalReserved >= amt, "LV: Insufficient Total Reserves");
            totalReserved -= amt;
            reservedAmounts[_user] -= amt;
        }
        // Invariant Check
        assert(totalReserved <= poolAmounts);
        emit LiquidityReserved(_user, amt, _amount > 0);
    }

    // $1 = 1e18
    function getLiquidityTokenPrice(uint256 _collateralPrice) public view returns (uint256 lpTokenPrice) {
        // market token price = (worth of market pool in USD) / total supply
        uint256 aum = getAum(_collateralPrice);
        uint256 supply = IERC20(address(liquidityToken)).totalSupply();
        if (aum == 0 || supply == 0) {
            lpTokenPrice = 0;
        } else {
            lpTokenPrice = (aum * SCALING_FACTOR) / supply;
        }
    }

    // Returns AUM in USD value
    function getAum(uint256 _collateralPrice) public view returns (uint256 aum) {
        // pool amount * price / decimals
        aum = (poolAmounts * _collateralPrice) / SCALING_FACTOR;
        // subtract losses, ignore profit => should only reflect available liquidity
        int256 pendingPnL = dataOracle.getCumulativeNetPnl();
        if (pendingPnL > 0) {
            aum -= uint256(pendingPnL);
        }
    }

    /// @dev Do we need transfer invariant checks???
    function _addLiquidity(address _account, uint256 _amount) internal {
        require(_amount != 0, "LV: Invalid Amount");
        require(_account != address(0), "LV: Zero Address");
        // Deposit USDC to the contract
        uint256 usdcBalanceBefore = USDC.balanceOf(address(this));
        USDC.safeTransferFrom(msg.sender, address(this), _amount);
        require(USDC.balanceOf(address(this)) == usdcBalanceBefore + _amount, "USDC Transfer Failed");

        // Wrap USDC to USDE
        uint256 usdeAmount = _wrapUsdc(_amount);
        // Deduct Fees
        uint256 afterFeeAmount = _deductLiquidityFees(usdeAmount);

        // Calculate Mint Amount
        uint256 collateralPrice = priceOracle.getCollateralPrice();
        uint256 valueUsd = (afterFeeAmount * collateralPrice) / SCALING_FACTOR;
        uint256 lpTokenPrice = getLiquidityTokenPrice(collateralPrice);
        uint256 mintAmount = lpTokenPrice == 0 ? valueUsd : (valueUsd * SCALING_FACTOR) / lpTokenPrice;

        // Update Pool Amounts
        poolAmounts += afterFeeAmount;
        // Mint Liquidity Token
        liquidityToken.mint(_account, mintAmount);

        emit LiquidityAdded(_account, afterFeeAmount, mintAmount);
    }

    /// @dev Do we need transfer invariant checks???
    function _removeLiquidity(address _account, uint256 _liquidityTokenAmount) internal {
        require(_liquidityTokenAmount != 0, "LV: Invalid Amount");
        require(_account != address(0), "LV: Zero Address");
        // Deposit Liquidity Token to this contract
        uint256 liquidityTokenBalance = liquidityToken.balanceOf(address(this));
        liquidityToken.safeTransferFrom(_account, address(this), _liquidityTokenAmount);

        require(
            liquidityToken.balanceOf(address(this)) == liquidityTokenBalance + _liquidityTokenAmount,
            "Liq Transfer Failed"
        );

        // Calculate Available Liquidity & Tokens to Redeem
        uint256 collateralPrice = priceOracle.getCollateralPrice();
        uint256 lpTokenValueUsd = (_liquidityTokenAmount * getLiquidityTokenPrice(collateralPrice)) / SCALING_FACTOR;
        uint256 tokenAmount = (lpTokenValueUsd * SCALING_FACTOR) / collateralPrice;
        uint256 availableLiquidity = poolAmounts - totalReserved;

        // Check if enough liquidity to redeem
        require(tokenAmount <= availableLiquidity, "LV: Insufficient Liq");

        // Update Pool Amounts
        poolAmounts -= tokenAmount;
        // Burn Liquidity Token
        liquidityToken.burn(address(this), _liquidityTokenAmount);
        // Deduct Fees & Unwrap USDC
        uint256 afterFeeAmount = _deductLiquidityFees(tokenAmount);
        uint256 tokenOutAmount = USDE.withdraw(afterFeeAmount);
        // Transfer USDC to User
        uint256 usdcBalanceBefore = USDC.balanceOf(address(this));
        USDC.safeTransfer(_account, tokenOutAmount);
        require(USDC.balanceOf(address(this)) == usdcBalanceBefore - tokenOutAmount, "USDC Transfer Failed");

        emit LiquidityWithdrawn(_account, address(USDE), _liquidityTokenAmount, afterFeeAmount);
    }

    function _wrapUsdc(uint256 _amount) internal returns (uint256 usdeAmount) {
        USDC.safeIncreaseAllowance(address(USDE), _amount);
        usdeAmount = USDE.deposit(_amount);
    }

    // Returns % amount after fee deduction
    function _deductLiquidityFees(uint256 _amount) internal returns (uint256 afterFeeAmount) {
        uint256 feeToCharge = (_amount * liquidityFee) / SCALING_FACTOR;
        accumulatedFees += feeToCharge;
        afterFeeAmount = _amount - feeToCharge;
    }
}
