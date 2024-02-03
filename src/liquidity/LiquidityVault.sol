// SPDX-License-Identifier: BUSL-1.1

pragma solidity 0.8.23;

import {ILiquidityVault} from "./interfaces/ILiquidityVault.sol";
import {ERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {RoleValidation} from "../access/RoleValidation.sol";
import {Deposit} from "./Deposit.sol";
import {Withdrawal} from "./Withdrawal.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {ReentrancyGuard} from "@solmate/utils/ReentrancyGuard.sol";
import {IPriceOracle} from "../oracle/interfaces/IPriceOracle.sol";
import {IDataOracle} from "../oracle/interfaces/IDataOracle.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {PriceImpact} from "../libraries/PriceImpact.sol";
import {Fee} from "../libraries/Fee.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Pool} from "./Pool.sol";

// Stores all funds for the protocol
/// @dev Needs Vault Role
contract LiquidityVault is ILiquidityVault, ERC20, RoleValidation, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using Address for address payable;

    uint256 public constant MIN_SLIPPAGE = 0.0001e18; // 0.01%
    uint256 public constant MAX_SLIPPAGE = 0.9999e18; // 99.99%
    uint256 public constant SCALING_FACTOR = 1e18;

    address public immutable LONG_TOKEN;
    address public immutable SHORT_TOKEN;
    uint256 private immutable LONG_BASE_UNIT;
    uint256 private immutable SHORT_BASE_UNIT;

    IPriceOracle priceOracle;
    IDataOracle dataOracle;

    bool isInitialised;
    uint48 minTimeToExpiration;
    uint256 depositFee; // 18 D.P
    uint256 withdrawalFee; // 18 D.P

    uint256 private longTokenBalance;
    uint256 private shortTokenBalance;
    uint256 private accumulatedFees;
    uint256 private longTokensReserved;
    uint256 private shortTokensReserved;

    uint8 private priceImpactExponent;
    uint256 private priceImpactFactor;

    uint256 public executionFee; // in Wei

    mapping(bytes32 => Deposit.Data) public depositRequests;
    EnumerableSet.Bytes32Set private depositKeys;
    mapping(bytes32 => Withdrawal.Data) public withdrawalRequests;
    EnumerableSet.Bytes32Set private withdrawalKeys;
    mapping(address user => mapping(bool isLong => uint256 reserved)) public reservedAmounts;

    modifier isValidToken(address _token) {
        require(_token == LONG_TOKEN || _token == SHORT_TOKEN, "LV: Invalid Token");
        _;
    }

    modifier orderExists(bytes32 _key, bool _isDeposit) {
        if (_isDeposit) {
            require(depositKeys.contains(_key), "LiquidityVault: invalid key");
        } else {
            require(withdrawalKeys.contains(_key), "LiquidityVault: invalid key");
        }
        _;
    }

    constructor(
        address _longToken,
        address _shortToken,
        uint256 _longBaseUnit,
        uint256 _shortBaseUnit,
        string memory _name,
        string memory _symbol,
        address _roleStorage
    ) ERC20(_name, _symbol) RoleValidation(_roleStorage) {
        LONG_TOKEN = _longToken;
        SHORT_TOKEN = _shortToken;
        LONG_BASE_UNIT = _longBaseUnit;
        SHORT_BASE_UNIT = _shortBaseUnit;
    }

    function initialise(
        IPriceOracle _priceOracle,
        IDataOracle _dataOracle,
        uint48 _minTimeToExpiration,
        uint8 _priceImpactExponent,
        uint256 _priceImpactFactor,
        uint256 _executionFee,
        uint256 _depositFee,
        uint256 _withdrawalFee
    ) external onlyAdmin {
        require(!isInitialised, "LiquidityVault: already initialised");
        priceOracle = _priceOracle;
        dataOracle = _dataOracle;
        executionFee = _executionFee;
        minTimeToExpiration = _minTimeToExpiration;
        depositFee = _depositFee;
        withdrawalFee = _withdrawalFee;
        priceImpactFactor = _priceImpactFactor;
        priceImpactExponent = _priceImpactExponent;
    }

    function updateFees(uint256 _executionFee, uint256 _depositFee, uint256 _withdrawalFee) external onlyConfigurator {
        executionFee = _executionFee;
        depositFee = _depositFee;
        withdrawalFee = _withdrawalFee;
    }

    function updatePriceImpact(uint256 _priceImpactFactor, uint8 _priceImpactExponent) external onlyConfigurator {
        priceImpactFactor = _priceImpactFactor;
        priceImpactExponent = _priceImpactExponent;
    }

    ///////////////////////////////
    // TRADING RELATED FUNCTIONS //
    ///////////////////////////////

    // q - do we need any input validation for _user?
    // e.g user could be a contract, could he reject this function call?
    // q - what must hold true in order to transfer profit to a user???
    function transferPositionProfit(address _user, uint256 _amount, bool _isLong) external onlyTradeStorage {
        require(_amount != 0, "LV: Invalid Profit Amount");
        require(_user != address(0), "LV: Zero Address");
        // check enough in pool to transfer position
        // @audit - is this check correct?
        if (_isLong) {
            require(_amount <= longTokenBalance - longTokensReserved, "LV: Insufficient Funds");
            longTokenBalance -= _amount;
            IERC20(LONG_TOKEN).safeTransfer(_user, _amount);
        } else {
            require(_amount <= shortTokenBalance - shortTokensReserved, "LV: Insufficient Funds");
            shortTokenBalance -= _amount;
            IERC20(SHORT_TOKEN).safeTransfer(_user, _amount);
        }
        emit ProfitTransferred(_user, _amount, _isLong);
    }

    function accumulateFees(uint256 _amount) external onlyFeeAccumulator {
        require(_amount != 0, "LV: Invalid Acc Fee");
        accumulatedFees += _amount;
        emit FeesAccumulated(_amount);
    }

    /// @dev Used to reserve / unreserve funds for open positions
    // We need a reserve factor to cap reserves to a % of the available liquidity
    function updateReservation(address _user, int256 _amount, bool _isLong) external onlyTradeStorage {
        require(_amount != 0, "LV: Invalid Res Amount");
        uint256 amt;
        if (_amount > 0) {
            amt = uint256(_amount);
            if (_isLong) {
                require(amt <= longTokenBalance, "LV: Insufficient Long Liq");
                longTokensReserved += amt;
                reservedAmounts[_user][true] += amt;
            } else {
                require(amt <= shortTokenBalance, "LV: Insufficient Short Liq");
                shortTokensReserved += amt;
                reservedAmounts[_user][false] += amt;
            }
        } else {
            amt = uint256(-_amount);
            if (_isLong) {
                require(reservedAmounts[_user][true] >= amt, "LV: Insufficient Reserves");
                require(longTokensReserved >= amt, "LV: Insufficient Long Liq");
                longTokensReserved -= amt;
                reservedAmounts[_user][true] -= amt;
            } else {
                require(reservedAmounts[_user][false] >= amt, "LV: Insufficient Reserves");
                require(shortTokensReserved >= amt, "LV: Insufficient Short Liq");
                shortTokensReserved -= amt;
                reservedAmounts[_user][false] -= amt;
            }
        }
        emit LiquidityReserved(_user, amt, _amount > 0, _isLong);
    }

    ///////////////////////
    // DEPOSIT EXECUTION //
    ///////////////////////

    function executeDeposit(bytes32 _key) external onlyExecutor orderExists(_key, true) {
        // fetch and cache
        Deposit.Data memory data = depositRequests[_key];
        // remove from storage
        depositKeys.remove(_key);
        delete depositRequests[_key];
        bool isLongToken = data.params.tokenIn == address(LONG_TOKEN);

        (uint256 mintAmount, uint256 fee, uint256 remaining) = Deposit.execute(
            data,
            Pool.Values({
                dataOracle: dataOracle,
                priceOracle: priceOracle,
                longTokenBalance: longTokenBalance,
                shortTokenBalance: shortTokenBalance,
                marketTokenSupply: totalSupply(),
                blockNumber: data.blockNumber,
                longBaseUnit: LONG_BASE_UNIT,
                shortBaseUnit: SHORT_BASE_UNIT
            }),
            isLongToken,
            priceImpactExponent,
            priceImpactFactor
        );

        // update storage
        isLongToken ? longTokenBalance += remaining : shortTokenBalance += remaining;
        accumulatedFees += fee;

        // send execution fee to keeper
        payable(msg.sender).sendValue(data.params.executionFee);
        // mint tokens to user
        _mint(data.params.owner, mintAmount);
        // fire event
        emit DepositExecuted(_key, data.params.owner, data.params.tokenIn, data.params.amountIn, mintAmount);
    }

    //////////////////////////
    // WITHDRAWAL EXECUTION //
    //////////////////////////

    // @audit - review
    function executeWithdrawal(bytes32 _key) external onlyExecutor orderExists(_key, false) {
        // fetch and cache
        Withdrawal.Data memory data = withdrawalRequests[_key];

        _burn(msg.sender, data.params.marketTokenAmountIn);
        // remove from storage
        withdrawalKeys.remove(_key);
        delete withdrawalRequests[_key];
        bool isLongToken = data.params.tokenOut == address(LONG_TOKEN);

        (uint256 amountOut, uint256 fee, uint256 remaining) = Withdrawal.execute(
            data,
            Pool.Values({
                dataOracle: dataOracle,
                priceOracle: priceOracle,
                longTokenBalance: longTokenBalance,
                shortTokenBalance: shortTokenBalance,
                marketTokenSupply: totalSupply(),
                blockNumber: data.blockNumber,
                longBaseUnit: LONG_BASE_UNIT,
                shortBaseUnit: SHORT_BASE_UNIT
            }),
            isLongToken,
            priceImpactExponent,
            priceImpactFactor
        );

        // update storage
        isLongToken ? longTokenBalance -= amountOut : shortTokenBalance -= amountOut;
        accumulatedFees += fee;

        // send execution fee to keeper
        payable(msg.sender).sendValue(data.params.executionFee);

        // transfer tokens to user
        IERC20(data.params.tokenOut).safeTransfer(data.params.owner, remaining);

        // fire event
        emit WithdrawalExecuted(
            _key, data.params.owner, data.params.tokenOut, data.params.marketTokenAmountIn, remaining
        );
    }

    //////////////////////
    // DEPOSIT CREATION //
    //////////////////////

    // Function to create a deposit request
    // Note -> need to add ability to create deposit in eth
    function createDeposit(Deposit.Params memory _params) external payable onlyRouter isValidToken(_params.tokenIn) {
        Deposit.validateParameters(_params, executionFee);

        // Transfer tokens from user to this contract
        IERC20(_params.tokenIn).safeTransferFrom(_params.owner, address(this), _params.amountIn);

        (Deposit.Data memory deposit, bytes32 key) = Deposit.create(dataOracle, _params, minTimeToExpiration);

        depositKeys.add(key);
        depositRequests[key] = deposit;
        emit DepositRequestCreated(key, _params.owner, _params.tokenIn, _params.amountIn, deposit.blockNumber);
    }

    // Request must be expired for a user to cancel it
    function cancelDeposit(bytes32 _key) external onlyRouter orderExists(_key, true) {
        Deposit.Data memory deposit = depositRequests[_key];

        Deposit.validateCancellation(deposit);

        depositKeys.remove(_key);
        delete depositRequests[_key];

        // Transfer tokens back to user
        IERC20(deposit.params.tokenIn).safeTransfer(msg.sender, deposit.params.amountIn);

        emit DepositRequestCancelled(_key, deposit.params.owner, deposit.params.tokenIn, deposit.params.amountIn);
    }

    /////////////////////////
    // WITHDRAWAL CREATION //
    /////////////////////////

    // Function to create a withdrawal request
    function createWithdrawal(Withdrawal.Params memory _params)
        external
        payable
        onlyRouter
        isValidToken(_params.tokenOut)
    {
        Withdrawal.validateParameters(_params, executionFee);

        // transfer market tokens to contract
        IERC20(address(this)).safeTransferFrom(_params.owner, address(this), _params.marketTokenAmountIn);

        (Withdrawal.Data memory withdrawal, bytes32 key) = Withdrawal.create(dataOracle, _params, minTimeToExpiration);

        withdrawalKeys.add(key);
        withdrawalRequests[key] = withdrawal;

        emit WithdrawalRequestCreated(
            key, _params.owner, _params.tokenOut, _params.marketTokenAmountIn, withdrawal.blockNumber
        );
    }

    function cancelWithdrawal(bytes32 _key) external onlyRouter orderExists(_key, false) {
        Withdrawal.Data memory withdrawal = withdrawalRequests[_key];

        Withdrawal.validateCancellation(withdrawal);

        withdrawalKeys.remove(_key);
        delete withdrawalRequests[_key];

        emit WithdrawalRequestCancelled(
            _key, withdrawal.params.owner, withdrawal.params.tokenOut, withdrawal.params.marketTokenAmountIn
        );
    }
}
