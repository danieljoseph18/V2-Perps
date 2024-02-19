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
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {PriceImpact} from "../libraries/PriceImpact.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {mulDiv} from "@prb/math/Common.sol";
import {Pool} from "./Pool.sol";
import {IWETH} from "../tokens/interfaces/IWETH.sol";
import {IProcessor} from "../router/interfaces/IProcessor.sol";
import {IPriceFeed} from "../oracle/interfaces/IPriceFeed.sol";
import {Oracle} from "../oracle/Oracle.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";

// Stores all funds for the protocol
/// @dev Needs Vault Role
contract LiquidityVault is ILiquidityVault, ERC20, RoleValidation, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using Address for address payable;
    using SignedMath for int256;

    uint256 public constant MIN_SLIPPAGE = 0.0001e18; // 0.01%
    uint256 public constant MAX_SLIPPAGE = 0.9999e18; // 99.99%
    uint256 public constant SCALING_FACTOR = 1e18;
    uint256 public constant BASE_FEE = 0.001e18; // 0.1%

    address public immutable LONG_TOKEN;
    address public immutable SHORT_TOKEN;
    uint256 private immutable LONG_BASE_UNIT;
    uint256 private immutable SHORT_BASE_UNIT;

    IPriceFeed priceFeed;
    IProcessor processor;

    bool isInitialised;
    uint48 minTimeToExpiration;

    // Value = Max Bonus Fee
    // Users will be charged a % of this fee based on the skew of the market
    uint256 public feeScale; // 3% = 0.03e18

    uint256 public longTokenBalance;
    uint256 public shortTokenBalance;

    uint256 public longAccumulatedFees;
    uint256 public shortAccumulatedFees;

    uint256 public longTokensReserved;
    uint256 public shortTokensReserved;

    uint256 public executionFee; // in Wei

    uint256 public longClaimableFunding; // in Short Tokens
    uint256 public shortClaimableFunding; // in Long Tokens

    mapping(bytes32 => Deposit.Data) private depositRequests;
    EnumerableSet.Bytes32Set private depositKeys;
    mapping(bytes32 => Withdrawal.Data) private withdrawalRequests;
    EnumerableSet.Bytes32Set private withdrawalKeys;

    mapping(address _user => mapping(bool _isLong => uint256 _claimable)) public userClaimableFunding;

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

    receive() external payable {}

    function initialise(
        address _priceFeed,
        address _processor,
        uint48 _minTimeToExpiration,
        uint256 _executionFee,
        uint256 _feeScale
    ) external onlyAdmin {
        require(!isInitialised, "LiquidityVault: already initialised");
        priceFeed = IPriceFeed(_priceFeed);
        processor = IProcessor(_processor);
        executionFee = _executionFee;
        minTimeToExpiration = _minTimeToExpiration;
        feeScale = _feeScale;
    }

    function updateFees(uint256 _executionFee, uint256 _feeScale) external onlyConfigurator {
        executionFee = _executionFee;
        feeScale = _feeScale;
    }

    function updateProcessor(IProcessor _processor) external onlyConfigurator {
        processor = _processor;
    }

    function processFees() external onlyAdmin {
        uint256 longFees = longAccumulatedFees;
        uint256 shortFees = shortAccumulatedFees;
        longAccumulatedFees = 0;
        shortAccumulatedFees = 0;
        IERC20(LONG_TOKEN).safeTransfer(msg.sender, longFees);
        IERC20(SHORT_TOKEN).safeTransfer(msg.sender, shortFees);
    }

    /////////////////////////////
    // TOKEN RELATED FUNCTIONS //
    /////////////////////////////

    function mint(address _to, uint256 _amount) external onlyVault {
        _mint(_to, _amount);
    }

    function burn(uint256 _amount) external onlyVault {
        _burn(address(this), _amount);
    }

    //////////////////////////////
    // TOKEN TRANSFER FUNCTIONS //
    //////////////////////////////

    function transferOutTokens(address _to, uint256 _amount, bool _isLongToken, bool _shouldUnwrap)
        external
        onlyTradeStorage
    {
        _transferOutTokens(_to, _amount, _isLongToken, _shouldUnwrap);
    }

    function sendExecutionFee(address payable _processor, uint256 _executionFee) public onlyTradeStorage {
        _processor.sendValue(_executionFee);
    }

    //////////////////////////////
    // STORAGE UPDATE FUNCTIONS //
    //////////////////////////////

    function accumulateFees(uint256 _amount, bool _isLong) external onlyFeeAccumulator {
        _accumulateFees(_amount, _isLong);
        emit FeesAccumulated(_amount, _isLong);
    }

    function reserveLiquidity(uint256 _amount, bool _isLong) external onlyTradeStorage {
        _isLong ? longTokensReserved += _amount : shortTokensReserved += _amount;
    }

    function unreserveLiquidity(uint256 _amount, bool _isLong) external onlyTradeStorage {
        if (_isLong) {
            if (_amount > longTokensReserved) longTokensReserved = 0;
            else longTokensReserved -= _amount;
        } else {
            if (_amount > shortTokensReserved) shortTokensReserved = 0;
            else shortTokensReserved -= _amount;
        }
    }

    function increasePoolBalance(uint256 _amount, bool _isLong) external onlyProcessor {
        _increasePoolBalance(_amount, _isLong);
    }

    function decreasePoolBalance(uint256 _amount, bool _isLong) external onlyProcessor {
        _decreasePoolBalance(_amount, _isLong);
    }

    ///////////////////////
    // DEPOSIT FUNCTIONS //
    ///////////////////////

    // Function to create a deposit request
    function createDeposit(Deposit.Input memory _input) external payable onlyRouter {
        Deposit.Data memory deposit = Deposit.create(_input, minTimeToExpiration);
        depositKeys.add(deposit.key);
        depositRequests[deposit.key] = deposit;
        emit DepositRequestCreated(deposit.key, _input.owner, _input.tokenIn, _input.amountIn, deposit.blockNumber);
    }

    // Request must be expired for a user to cancel it
    function cancelDeposit(bytes32 _key, address _caller) external onlyRouter orderExists(_key, true) {
        Deposit.Data memory deposit = depositRequests[_key];

        Deposit.validateCancellation(deposit, _caller);

        _deleteDeposit(_key);

        // Transfer tokens back to user
        IERC20(deposit.input.tokenIn).safeTransfer(msg.sender, deposit.input.amountIn);

        emit DepositRequestCancelled(_key, deposit.input.owner, deposit.input.tokenIn, deposit.input.amountIn);
    }

    function executeDeposit(Deposit.ExecuteParams memory _params)
        external
        onlyProcessor
        orderExists(_params.key, true)
    {
        // Delete Deposit Request
        _deleteDeposit(_params.key);
        // Get Pool Values
        _params.values = Pool.Values({
            longTokenBalance: longTokenBalance,
            shortTokenBalance: shortTokenBalance,
            marketTokenSupply: totalSupply(),
            longBaseUnit: LONG_BASE_UNIT,
            shortBaseUnit: SHORT_BASE_UNIT
        });
        // Execute Deposit
        Deposit.ExecuteCache memory cache = Deposit.execute(_params);
        // update storage
        _accumulateFees(cache.fee, _params.isLongToken);
        _increasePoolBalance(cache.afterFeeAmount, _params.isLongToken);
        // Transfer tokens into the market
        processor.transferDepositTokens(_params.data.input.tokenIn, _params.data.input.amountIn);
        // Invariant checks
        // @audit - what invariants checks do we need here?
        emit DepositExecuted(
            _params.key,
            _params.data.input.owner,
            _params.data.input.tokenIn,
            _params.data.input.amountIn,
            cache.mintAmount
        );
        // mint tokens to user
        _mint(_params.data.input.owner, cache.mintAmount);
    }

    //////////////////////////
    // WITHDRAWAL FUNCTIONS //
    //////////////////////////

    // Function to create a withdrawal request
    function createWithdrawal(Withdrawal.Input memory _input) external payable onlyRouter {
        Withdrawal.Data memory withdrawal = Withdrawal.create(_input, minTimeToExpiration);

        withdrawalKeys.add(withdrawal.key);
        withdrawalRequests[withdrawal.key] = withdrawal;

        emit WithdrawalRequestCreated(
            withdrawal.key, _input.owner, _input.tokenOut, _input.marketTokenAmountIn, withdrawal.blockNumber
        );
    }

    function cancelWithdrawal(bytes32 _key, address _caller) external onlyRouter orderExists(_key, false) {
        Withdrawal.Data memory withdrawal = withdrawalRequests[_key];

        Withdrawal.validateCancellation(withdrawal, _caller);

        _deleteWithdrawal(_key);

        emit WithdrawalRequestCancelled(
            _key, withdrawal.input.owner, withdrawal.input.tokenOut, withdrawal.input.marketTokenAmountIn
        );
    }

    // @audit - review
    function executeWithdrawal(Withdrawal.ExecuteParams memory _params)
        external
        onlyProcessor
        orderExists(_params.key, false)
    {
        // Transfer in Market Tokens
        _params.processor.transferDepositTokens(address(_params.liquidityVault), _params.data.input.marketTokenAmountIn);
        // Get Pool Values
        _params.values = Pool.Values({
            longTokenBalance: longTokenBalance,
            shortTokenBalance: shortTokenBalance,
            marketTokenSupply: totalSupply(), // Before Burn
            longBaseUnit: LONG_BASE_UNIT,
            shortBaseUnit: SHORT_BASE_UNIT
        });
        // Burn Market Tokens
        _burn(address(this), _params.data.input.marketTokenAmountIn);
        // Delete the WIthdrawal from Storage
        _deleteWithdrawal(_params.key);
        // Execute the Withdrawal
        Withdrawal.ExecuteCache memory cache = Withdrawal.execute(_params);
        // accumulate the fee
        _accumulateFees(cache.fee, _params.isLongToken);
        // decrease the pool
        _decreasePoolBalance(cache.totalTokensOut, _params.isLongToken);

        // @audit - add invariant checks
        emit WithdrawalExecuted(
            _params.key,
            _params.data.input.owner,
            _params.data.input.tokenOut,
            _params.data.input.marketTokenAmountIn,
            cache.amountOut
        );
        // transfer tokens to user
        _transferOutTokens(_params.data.input.owner, cache.amountOut, _params.isLongToken, _params.shouldUnwrap);
    }

    /////////////
    // FUNDING //
    /////////////

    function accumulateFundingFees(uint256 _amount, bool _isLong) external onlyTradeStorage {
        _isLong ? longClaimableFunding += _amount : shortClaimableFunding += _amount;
    }

    function subtractFundingFees(uint256 _amount, bool _isLong) external onlyProcessor {
        _isLong ? longClaimableFunding -= _amount : shortClaimableFunding -= _amount;
    }

    function increaseUserClaimableFunding(uint256 _amount, bool _isLong) external onlyTradeStorage {
        userClaimableFunding[msg.sender][_isLong] += _amount;
    }

    function claimFundingFees(bool _isLong) external nonReentrant {
        uint256 amount = userClaimableFunding[msg.sender][_isLong];
        require(amount > 0, "LiquidityVault: Insufficient claimable funds");
        userClaimableFunding[msg.sender][_isLong] = 0;
        _isLong ? longClaimableFunding -= amount : shortClaimableFunding -= amount;
        _transferOutTokens(msg.sender, amount, _isLong, false);
    }

    //////////////
    // INTERNAL //
    //////////////

    function _deleteWithdrawal(bytes32 _key) internal {
        withdrawalKeys.remove(_key);
        delete withdrawalRequests[_key];
    }

    function _deleteDeposit(bytes32 _key) internal {
        depositKeys.remove(_key);
        delete depositRequests[_key];
    }

    function _accumulateFees(uint256 _amount, bool _isLong) internal {
        _isLong ? longAccumulatedFees += _amount : shortAccumulatedFees += _amount;
    }

    function _increasePoolBalance(uint256 _amount, bool _isLong) internal {
        _isLong ? longTokenBalance += _amount : shortTokenBalance += _amount;
    }

    function _decreasePoolBalance(uint256 _amount, bool _isLong) internal {
        _isLong ? longTokenBalance -= _amount : shortTokenBalance -= _amount;
    }

    function _transferOutTokens(address _to, uint256 _amount, bool _isLongToken, bool _shouldUnwrap) internal {
        if (_shouldUnwrap) {
            require(_isLongToken == true, "LiquidityVault: Invalid Unwrap Token");
            IWETH(LONG_TOKEN).withdraw(_amount);
            payable(_to).sendValue(_amount);
        } else {
            IERC20(_isLongToken ? LONG_TOKEN : SHORT_TOKEN).safeTransfer(_to, _amount);
        }
    }

    /////////////
    // GETTERS //
    /////////////

    function getDepositRequestAtIndex(uint256 _index) external view returns (Deposit.Data memory) {
        return depositRequests[depositKeys.at(_index)];
    }

    function getDepositRequest(bytes32 _key) external view returns (Deposit.Data memory) {
        return depositRequests[_key];
    }

    function getWithdrawalRequest(bytes32 _key) external view returns (Withdrawal.Data memory) {
        return withdrawalRequests[_key];
    }

    function getWithdrawalRequestAtIndex(uint256 _index) external view returns (Withdrawal.Data memory) {
        return withdrawalRequests[withdrawalKeys.at(_index)];
    }

    function totalAvailableLiquidity(bool _isLong) external view returns (uint256 total) {
        total = _isLong ? longTokenBalance - longTokensReserved : shortTokenBalance - shortTokensReserved;
    }
}
