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

    uint256 public longClaimableFunding;
    uint256 public shortClaimableFunding;

    mapping(bytes32 => Deposit.Data) private depositRequests;
    EnumerableSet.Bytes32Set private depositKeys;
    mapping(bytes32 => Withdrawal.Data) private withdrawalRequests;
    EnumerableSet.Bytes32Set private withdrawalKeys;

    mapping(address user => mapping(bool isLong => uint256 reserved)) public reservedAmounts;

    mapping(address _market => uint256 _collateral) public longCollateral;
    mapping(address _market => uint256 _collateral) public shortCollateral;

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
        onlyVault
    {
        if (_shouldUnwrap) {
            require(_isLongToken == true, "LiquidityVault: Invalid Unwrap Token");
            IWETH(LONG_TOKEN).withdraw(_amount);
            payable(_to).sendValue(_amount);
        } else {
            IERC20(_isLongToken ? LONG_TOKEN : SHORT_TOKEN).safeTransfer(_to, _amount);
        }
    }

    function sendExecutionFee(address payable _processor, uint256 _executionFee) public onlyTradeStorage {
        _processor.sendValue(_executionFee);
    }

    //////////////////////////////
    // STORAGE UPDATE FUNCTIONS //
    //////////////////////////////

    function accumulateFees(uint256 _amount, bool _isLong) external onlyFeeAccumulator {
        _isLong ? longAccumulatedFees += _amount : shortAccumulatedFees += _amount;
        emit FeesAccumulated(_amount, _isLong);
    }

    function reserveLiquidity(address _user, uint256 _amount, bool _isLong) external onlyTradeStorage {
        if (_isLong) {
            longTokensReserved += _amount;
            reservedAmounts[_user][true] += _amount;
        } else {
            shortTokensReserved += _amount;
            reservedAmounts[_user][false] += _amount;
        }
    }

    function unreserveLiquidity(address _user, uint256 _amount, bool _isLong) external onlyTradeStorage {
        if (_isLong) {
            longTokensReserved -= _amount;
            reservedAmounts[_user][true] -= _amount;
        } else {
            shortTokensReserved -= _amount;
            reservedAmounts[_user][false] -= _amount;
        }
    }

    function increasePoolBalance(uint256 _amount, bool _isLong) external onlyVault {
        _isLong ? longTokenBalance += _amount : shortTokenBalance += _amount;
    }

    function decreasePoolBalance(uint256 _amount, bool _isLong) external onlyVault {
        _isLong ? longTokenBalance -= _amount : shortTokenBalance -= _amount;
    }

    ///////////////////////
    // DEPOSIT FUNCTIONS //
    ///////////////////////

    // Function to create a deposit request
    // Note -> need to add ability to create deposit in eth
    function createDeposit(Deposit.Input memory _input) external payable onlyRouter {
        (Deposit.Data memory deposit, bytes32 key) = Deposit.create(_input, minTimeToExpiration);
        depositKeys.add(key);
        depositRequests[key] = deposit;
        emit DepositRequestCreated(key, _input.owner, _input.tokenIn, _input.amountIn, deposit.blockNumber);
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
        Deposit.execute(_params);
    }

    function deleteDeposit(bytes32 _key) external onlyVault {
        _deleteDeposit(_key);
    }

    //////////////////////////
    // WITHDRAWAL FUNCTIONS //
    //////////////////////////

    // Function to create a withdrawal request
    function createWithdrawal(Withdrawal.Input memory _input) external payable onlyRouter {
        (Withdrawal.Data memory withdrawal, bytes32 key) = Withdrawal.create(_input, minTimeToExpiration);

        withdrawalKeys.add(key);
        withdrawalRequests[key] = withdrawal;

        emit WithdrawalRequestCreated(
            key, _input.owner, _input.tokenOut, _input.marketTokenAmountIn, withdrawal.blockNumber
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
        Withdrawal.execute(_params);
    }

    function deleteWithdrawal(bytes32 _key) external onlyVault {
        _deleteWithdrawal(_key);
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

    /////////////
    // GETTERS //
    /////////////

    function getDepositRequest(bytes32 _key) external view returns (Deposit.Data memory) {
        return depositRequests[_key];
    }

    function getWithdrawalRequest(bytes32 _key) external view returns (Withdrawal.Data memory) {
        return withdrawalRequests[_key];
    }

    function totalAvailableLiquidity(bool _isLong) external view returns (uint256 total) {
        total = _isLong ? longTokenBalance - longTokensReserved : shortTokenBalance - shortTokensReserved;
    }
}
