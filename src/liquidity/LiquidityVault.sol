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
import {Fee} from "../libraries/Fee.sol";
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

    address public immutable LONG_TOKEN;
    address public immutable SHORT_TOKEN;
    uint256 private immutable LONG_BASE_UNIT;
    uint256 private immutable SHORT_BASE_UNIT;

    IPriceFeed priceFeed;
    IProcessor processor;

    bool isInitialised;
    uint48 minTimeToExpiration;
    uint256 public depositFee; // 18 D.P
    uint256 public withdrawalFee; // 18 D.P

    uint256 private longTokenBalance;
    uint256 private shortTokenBalance;
    uint256 private longAccumulatedFees;
    uint256 private shortAccumulatedFees;
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
        IPriceFeed _priceFeed,
        IProcessor _processor,
        uint48 _minTimeToExpiration,
        uint8 _priceImpactExponent,
        uint256 _priceImpactFactor,
        uint256 _executionFee,
        uint256 _depositFee,
        uint256 _withdrawalFee
    ) external onlyAdmin {
        require(!isInitialised, "LiquidityVault: already initialised");
        priceFeed = _priceFeed;
        processor = _processor;
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

    ///////////////////////////////
    // TRADING RELATED FUNCTIONS //
    ///////////////////////////////

    // @audit - CRITICAL -> Profit needs to be paid from a market's allocation
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

    function transferOutTokens(address _market, address _to, uint256 _collateralDelta, bool _isLong)
        external
        onlyTradeStorage
    {
        require(longCollateral[_market] != 0 || shortCollateral[_market] != 0, "TV: Incorrect Market Key");
        require(_to != address(0), "TV: Zero Address");
        require(_collateralDelta != 0, "TV: Zero Amount");
        if (_isLong) {
            require(longCollateral[_market] >= _collateralDelta, "TV: Insufficient Collateral");
            longCollateral[_market] -= _collateralDelta;
            IERC20(LONG_TOKEN).safeTransfer(_to, _collateralDelta);
        } else {
            require(shortCollateral[_market] >= _collateralDelta, "TV: Insufficient Collateral");
            shortCollateral[_market] -= _collateralDelta;
            IERC20(SHORT_TOKEN).safeTransfer(_to, _collateralDelta);
        }
        emit TransferOutTokens(_market, _to, _collateralDelta, _isLong);
    }

    function recordCollateralTransferIn(address _market, uint256 _collateralDelta, bool _isLong)
        external
        onlyTradeStorage
    {
        require(_collateralDelta != 0, "TV: Zero Amount");
        if (_isLong) {
            longCollateral[_market] += _collateralDelta;
        } else {
            shortCollateral[_market] += _collateralDelta;
        }
        emit TransferInCollateral(_market, _collateralDelta, _isLong);
    }

    function accumulateFees(uint256 _amount, bool _isLong) external onlyFeeAccumulator {
        require(_amount != 0, "LV: Invalid Acc Fee");
        if (_isLong) {
            longAccumulatedFees += _amount;
        } else {
            shortAccumulatedFees += _amount;
        }
        emit FeesAccumulated(_amount, _isLong);
    }

    /// @dev Used to reserve / unreserve funds for open positions
    // We need a reserve factor to cap reserves to a % of the available liquidity
    function updateReservation(address _user, int256 _amount, bool _isLong) external onlyTradeStorage {
        require(_amount != 0, "LV: Invalid Res Amount");
        uint256 amt = _amount.abs();
        if (_amount > 0) {
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

    function sendExecutionFee(address payable _processor, uint256 _executionFee) public onlyTradeStorage {
        _processor.sendValue(_executionFee);
    }

    function swapFundingAmount(address _market, uint256 _amount, bool _isLong) external onlyTradeStorage {
        _swapFundingAmount(_market, _amount, _isLong);
    }

    // @audit - Liq Fee needs to be measured in collateral token
    function liquidatePositionCollateral(
        address _liquidator,
        uint256 _liqFee,
        address _market,
        uint256 _totalCollateral,
        uint256 _collateralFundingOwed,
        bool _isLong
    ) external onlyTradeStorage {
        // funding
        if (_collateralFundingOwed > 0) {
            _swapFundingAmount(_market, _collateralFundingOwed, _isLong);
        }
        // Funds remaining after paying funding and liquidation fee
        uint256 remainingCollateral = _totalCollateral - _collateralFundingOwed - _liqFee;
        if (remainingCollateral > 0) {
            if (_isLong) {
                longCollateral[_market] -= remainingCollateral;
                longAccumulatedFees += remainingCollateral;
                IERC20(LONG_TOKEN).safeTransfer(_liquidator, _liqFee);
            } else {
                shortCollateral[_market] -= remainingCollateral;
                shortAccumulatedFees += remainingCollateral;
                IERC20(SHORT_TOKEN).safeTransfer(_liquidator, _liqFee);
            }
        }
        emit PositionCollateralLiquidated(
            _liquidator, _liqFee, _market, _totalCollateral, _collateralFundingOwed, _isLong
        );
    }

    // Funding fee needs to be measured in collateral token
    function claimFundingFees(address _market, address _user, uint256 _claimed, bool _isLong)
        external
        onlyTradeStorage
    {
        if (_isLong) {
            require(shortCollateral[_market] >= _claimed, "TV: Insufficient Claimable");
            shortCollateral[_market] -= _claimed;
            IERC20(SHORT_TOKEN).safeTransfer(_user, _claimed);
        } else {
            require(longCollateral[_market] >= _claimed, "TV: Insufficient Claimable");
            longCollateral[_market] -= _claimed;
            IERC20(LONG_TOKEN).safeTransfer(_user, _claimed);
        }
    }

    function _swapFundingAmount(address _market, uint256 _amount, bool _isLong) internal {
        if (_isLong) {
            longCollateral[_market] -= _amount;
            shortCollateral[_market] += _amount;
        } else {
            shortCollateral[_market] -= _amount;
            longCollateral[_market] += _amount;
        }
    }

    ///////////////////////
    // DEPOSIT EXECUTION //
    ///////////////////////

    function executeDeposit(bytes32 _key, int256 _cumulativePnl, address _processor)
        external
        onlyProcessor
        orderExists(_key, true)
    {
        // fetch and cache
        Deposit.Data memory data = depositRequests[_key];
        // remove from storage
        depositKeys.remove(_key);
        delete depositRequests[_key];

        bool isLongToken = data.params.tokenIn == LONG_TOKEN;

        (uint256 mintAmount, uint256 fee, uint256 remaining) = Deposit.execute(
            this,
            priceFeed,
            data,
            Pool.Values({
                longToken: LONG_TOKEN,
                shortToken: SHORT_TOKEN,
                longTokenBalance: longTokenBalance,
                shortTokenBalance: shortTokenBalance,
                marketTokenSupply: totalSupply(),
                blockNumber: data.blockNumber,
                longBaseUnit: LONG_BASE_UNIT,
                shortBaseUnit: SHORT_BASE_UNIT,
                cumulativePnl: _cumulativePnl
            }),
            isLongToken,
            priceImpactExponent,
            priceImpactFactor
        );

        // update storage
        if (isLongToken) {
            longTokenBalance += remaining;
            longAccumulatedFees += fee;
        } else {
            shortTokenBalance += remaining;
            shortAccumulatedFees += fee;
        }

        // Transfer in intermediary tokens
        processor.transferDepositTokens(data.params.tokenIn, data.params.amountIn);
        // send execution fee to keeper
        sendExecutionFee(payable(_processor), data.params.executionFee);
        // mint tokens to user
        _mint(data.params.owner, mintAmount);
        // fire event
        emit DepositExecuted(_key, data.params.owner, data.params.tokenIn, data.params.amountIn, mintAmount);
    }

    //////////////////////////
    // WITHDRAWAL EXECUTION //
    //////////////////////////

    // @audit - review
    function executeWithdrawal(bytes32 _key, int256 _cumulativePnl, address _processor)
        external
        onlyProcessor
        orderExists(_key, false)
    {
        // fetch and cache
        Withdrawal.Data memory data = withdrawalRequests[_key];

        // Transfer in intermediary market tokens
        processor.transferDepositTokens(address(this), data.params.marketTokenAmountIn);
        // Burn tokens
        _burn(msg.sender, data.params.marketTokenAmountIn);
        // remove from storage
        withdrawalKeys.remove(_key);
        delete withdrawalRequests[_key];
        bool isLongToken = data.params.tokenOut == LONG_TOKEN;

        (uint256 amountOut, uint256 fee, uint256 remaining) = Withdrawal.execute(
            this,
            priceFeed,
            data,
            Pool.Values({
                longToken: LONG_TOKEN,
                shortToken: SHORT_TOKEN,
                longTokenBalance: longTokenBalance,
                shortTokenBalance: shortTokenBalance,
                marketTokenSupply: totalSupply(),
                blockNumber: data.blockNumber,
                longBaseUnit: LONG_BASE_UNIT,
                shortBaseUnit: SHORT_BASE_UNIT,
                cumulativePnl: _cumulativePnl
            }),
            isLongToken,
            priceImpactExponent,
            priceImpactFactor
        );

        // update storage
        if (isLongToken) {
            longTokenBalance -= amountOut;
            longAccumulatedFees += fee;
        } else {
            shortTokenBalance -= amountOut;
            shortAccumulatedFees += fee;
        }

        // send execution fee to keeper
        sendExecutionFee(payable(_processor), data.params.executionFee);

        // transfer tokens to user
        if (data.params.shouldUnwrap) {
            IWETH(LONG_TOKEN).withdraw(remaining);
            payable(data.params.owner).sendValue(remaining);
        } else {
            IERC20(data.params.tokenOut).safeTransfer(data.params.owner, remaining);
        }

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
    function createDeposit(Deposit.Params memory _params) external payable onlyRouter {
        (Deposit.Data memory deposit, bytes32 key) = Deposit.create(_params, minTimeToExpiration);
        depositKeys.add(key);
        depositRequests[key] = deposit;
        emit DepositRequestCreated(key, _params.owner, _params.tokenIn, _params.amountIn, deposit.blockNumber);
    }

    // Request must be expired for a user to cancel it
    function cancelDeposit(bytes32 _key, address _caller) external onlyRouter orderExists(_key, true) {
        Deposit.Data memory deposit = depositRequests[_key];

        Deposit.validateCancellation(deposit, _caller);

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
    function createWithdrawal(Withdrawal.Params memory _params) external payable onlyRouter {
        (Withdrawal.Data memory withdrawal, bytes32 key) = Withdrawal.create(_params, minTimeToExpiration);

        withdrawalKeys.add(key);
        withdrawalRequests[key] = withdrawal;

        emit WithdrawalRequestCreated(
            key, _params.owner, _params.tokenOut, _params.marketTokenAmountIn, withdrawal.blockNumber
        );
    }

    function cancelWithdrawal(bytes32 _key, address _caller) external onlyRouter orderExists(_key, false) {
        Withdrawal.Data memory withdrawal = withdrawalRequests[_key];

        Withdrawal.validateCancellation(withdrawal, _caller);

        withdrawalKeys.remove(_key);
        delete withdrawalRequests[_key];

        emit WithdrawalRequestCancelled(
            _key, withdrawal.params.owner, withdrawal.params.tokenOut, withdrawal.params.marketTokenAmountIn
        );
    }
}
