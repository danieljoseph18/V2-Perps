// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {ERC20} from "../tokens/ERC20.sol";
import {IERC20} from "../tokens/interfaces/IERC20.sol";
import {IVault} from "./interfaces/IVault.sol";
import {OwnableRoles} from "../auth/OwnableRoles.sol";
import {SafeTransferLib} from "../libraries/SafeTransferLib.sol";
import {MarketUtils} from "./MarketUtils.sol";
import {EnumerableMap} from "../libraries/EnumerableMap.sol";
import {IMarket} from "./interfaces/IMarket.sol";
import {IWETH} from "../tokens/interfaces/IWETH.sol";
import {ReentrancyGuard} from "../utils/ReentrancyGuard.sol";
import {IRewardTracker} from "../rewards/interfaces/IRewardTracker.sol";
import {IFeeDistributor} from "../rewards/interfaces/IFeeDistributor.sol";
import {Units} from "../libraries/Units.sol";

contract Vault is ERC20, IVault, OwnableRoles, ReentrancyGuard {
    using SafeTransferLib for IERC20;
    using SafeTransferLib for Vault;
    using Units for uint256;

    address private immutable WETH;
    address private immutable USDC;

    uint64 private constant FEES_TO_OWNERS = 0.1e18; // 10% to Owner and 10% to Protocol

    IMarket market;
    IRewardTracker public rewardTracker;
    IFeeDistributor public feeDistributor;

    address public poolOwner;
    address public feeReceiver;

    uint256 public longAccumulatedFees;
    uint256 public shortAccumulatedFees;
    uint256 public longTokenBalance;
    uint256 public shortTokenBalance;
    uint256 public longTokensReserved;
    uint256 public shortTokensReserved;
    bool private isInitialized;

    // Store the Collateral Amount for each User
    mapping(address user => mapping(bool _isLong => uint256 collateralAmount)) public collateralAmounts;

    modifier onlyMarket() {
        if (msg.sender != address(market)) revert Vault_AccessDenied();
        _;
    }

    constructor(address _poolOwner, address _weth, address _usdc, string memory _name, string memory _symbol)
        ERC20(_name, _symbol, 18)
    {
        _initializeOwner(msg.sender);
        poolOwner = _poolOwner;
        WETH = _weth;
        USDC = _usdc;
    }

    receive() external payable {
        // Only accept ETH via fallback from the WETH contract when unwrapping WETH
        // Ensure that the call depth is 1 (direct call from WETH contract)
        if (msg.sender != WETH || gasleft() <= 2300) revert Vault_InvalidETHTransfer();
    }

    function initialize(address _market, address _feeDistributor, address _rewardTracker, address _feeReceiver)
        external
        onlyOwner
    {
        if (isInitialized) revert Vault_AlreadyInitialized();
        market = IMarket(_market);
        feeDistributor = IFeeDistributor(_feeDistributor);
        rewardTracker = IRewardTracker(_rewardTracker);
        feeReceiver = _feeReceiver;
        isInitialized = true;
    }

    /**
     * =============================== Storage Functions ===============================
     */
    function updateLiquidityReservation(uint256 _amount, bool _isLong, bool _isIncrease) external onlyRoles(_ROLE_5) {
        if (_isIncrease) {
            _isLong ? longTokensReserved += _amount : shortTokensReserved += _amount;
        } else {
            if (_isLong) {
                if (_amount > longTokensReserved) longTokensReserved = 0;
                else longTokensReserved -= _amount;
            } else {
                if (_amount > shortTokensReserved) shortTokensReserved = 0;
                else shortTokensReserved -= _amount;
            }
        }
    }

    function updatePoolBalance(uint256 _amount, bool _isLong, bool _isIncrease) external onlyRoles(_ROLE_5) {
        _updatePoolBalance(_amount, _isLong, _isIncrease);
    }

    function updateCollateralAmount(uint256 _amount, address _user, bool _isLong, bool _isIncrease, bool _isFullClose)
        external
        onlyRoles(_ROLE_5)
    {
        if (_isIncrease) {
            // Case 1: Increase the collateral amount
            collateralAmounts[_user][_isLong] += _amount;
        } else {
            // Case 2: Decrease the collateral amount
            uint256 currentCollateral = collateralAmounts[_user][_isLong];

            if (_amount > currentCollateral) {
                // Amount to decrease is greater than stored collateral
                uint256 excess = _amount - currentCollateral;
                collateralAmounts[_user][_isLong] = 0;
                // Subtract the extra amount from the pool
                _isLong ? longTokenBalance -= excess : shortTokenBalance -= excess;
            } else {
                // Amount to decrease is less than or equal to stored collateral
                collateralAmounts[_user][_isLong] -= _amount;
            }

            if (_isFullClose) {
                // Transfer any remaining collateral to the pool
                uint256 remaining = collateralAmounts[_user][_isLong];
                if (remaining > 0) {
                    collateralAmounts[_user][_isLong] = 0;
                    _isLong ? longTokenBalance += remaining : shortTokenBalance += remaining;
                }
            }
        }
    }

    function accumulateFees(uint256 _amount, bool _isLong) external onlyRoles(_ROLE_5) {
        _accumulateFees(_amount, _isLong);
    }

    // @audit - long fees go to long LPs, short to short LPs
    // Or can we split them 50/50 to encourage arbitrage???
    function batchWithdrawFees() external onlyRoles(_ROLE_2) nonReentrant {
        uint256 longFees = longAccumulatedFees;
        uint256 shortFees = shortAccumulatedFees;
        longAccumulatedFees = 0;
        shortAccumulatedFees = 0;

        // calculate percentages and distribute percentage to owner and feeDistributor
        uint256 longOwnerFees = longFees.percentage(FEES_TO_OWNERS);
        uint256 shortOwnerFees = shortFees.percentage(FEES_TO_OWNERS);
        uint256 longDistributorFee = longFees - (longOwnerFees * 2); // 2 because 10% to owner and 10% to protocol
        uint256 shortDistributorFee = shortFees - (shortOwnerFees * 2);

        // Send Fees to Distribute to LPs
        address distributor = address(feeDistributor);

        IERC20(WETH).approve(distributor, longDistributorFee);
        IERC20(USDC).approve(distributor, shortDistributorFee);
        IFeeDistributor(distributor).accumulateFees(longDistributorFee, shortDistributorFee);
        // Send Fees to Protocol
        IERC20(WETH).safeTransfer(feeReceiver, longOwnerFees);
        IERC20(USDC).safeTransfer(feeReceiver, shortOwnerFees);
        // Send Fees to Owner
        IERC20(WETH).safeTransfer(poolOwner, longOwnerFees);
        IERC20(USDC).safeTransfer(poolOwner, shortOwnerFees);

        emit FeesWithdrawn(longFees, shortFees);
    }

    function executeDeposit(ExecuteDeposit calldata _params, address _tokenIn, address _positionManager)
        external
        onlyMarket
    {
        // Cache the initial state
        uint256 initialBalance =
            _params.deposit.isLongToken ? IERC20(WETH).balanceOf(address(this)) : IERC20(USDC).balanceOf(address(this));
        // Transfer deposit tokens from position manager
        IERC20(_tokenIn).safeTransferFrom(_positionManager, address(this), _params.deposit.amountIn);

        (uint256 afterFeeAmount, uint256 fee, uint256 mintAmount) = MarketUtils.calculateDepositAmounts(_params);

        // update storage -> keep
        _accumulateFees(fee, _params.deposit.isLongToken);
        _updatePoolBalance(afterFeeAmount, _params.deposit.isLongToken, true);

        emit DepositExecuted(_params.key, _params.deposit.owner, _tokenIn, _params.deposit.amountIn, mintAmount);
        // mint tokens to user
        _mint(_params.deposit.owner, mintAmount);

        // Validate the state change
        _validateDeposit(initialBalance, _params.deposit.amountIn, _params.deposit.isLongToken);
    }

    function executeWithdrawal(ExecuteWithdrawal calldata _params, address _tokenOut, address _positionManager)
        external
        onlyMarket
    {
        // Cache the initial state
        uint256 initialBalance = _params.withdrawal.isLongToken
            ? IERC20(WETH).balanceOf(address(this))
            : IERC20(USDC).balanceOf(address(this));

        // Transfer Market Tokens in
        this.safeTransferFrom(_positionManager, address(this), _params.withdrawal.amountIn);

        // Calculate Amount Out after Fee
        uint256 transferAmountOut = MarketUtils.calculateWithdrawalAmounts(_params);

        // Calculate amount out / aum before burning
        _burn(address(this), _params.withdrawal.amountIn);

        // accumulate the fee
        _accumulateFees(_params.amountOut - transferAmountOut, _params.withdrawal.isLongToken);
        // validate whether the pool has enough tokens
        uint256 availableTokens = _params.withdrawal.isLongToken
            ? longTokenBalance - longTokensReserved
            : shortTokenBalance - shortTokensReserved;
        if (transferAmountOut > availableTokens) revert Vault_InsufficientAvailableTokens();
        // decrease the pool
        _updatePoolBalance(_params.amountOut, _params.withdrawal.isLongToken, false);

        emit WithdrawalExecuted(
            _params.key, _params.withdrawal.owner, _tokenOut, _params.withdrawal.amountIn, transferAmountOut
        );
        // transfer tokens to user
        _transferOutTokens(
            _tokenOut,
            _params.withdrawal.owner,
            transferAmountOut,
            _params.withdrawal.isLongToken,
            _params.withdrawal.reverseWrap
        );

        // Validate the state change
        _validateWithdrawal(initialBalance, transferAmountOut, _params.withdrawal.isLongToken);
    }

    /**
     * =============================== Token Transfers ===============================
     */
    function transferOutTokens(address _to, uint256 _amount, bool _isLongToken, bool _shouldUnwrap)
        external
        onlyRoles(_ROLE_5)
    {
        _transferOutTokens(_isLongToken ? WETH : USDC, _to, _amount, _isLongToken, _shouldUnwrap);
    }

    /**
     * =============================== Private Functions ===============================
     */
    function _transferOutTokens(address _tokenOut, address _to, uint256 _amount, bool _isLongToken, bool _shouldUnwrap)
        private
    {
        if (_isLongToken) {
            if (_shouldUnwrap) {
                IWETH(_tokenOut).withdraw(_amount);
                SafeTransferLib.safeTransferETH(_to, _amount);
            } else {
                IERC20(_tokenOut).safeTransfer(_to, _amount);
            }
        } else {
            IERC20(_tokenOut).safeTransfer(_to, _amount);
        }
    }

    function _updatePoolBalance(uint256 _amount, bool _isLong, bool _isIncrease) private {
        if (_isIncrease) {
            _isLong ? longTokenBalance += _amount : shortTokenBalance += _amount;
        } else {
            _isLong ? longTokenBalance -= _amount : shortTokenBalance -= _amount;
        }
    }

    function _accumulateFees(uint256 _amount, bool _isLong) private {
        _isLong ? longAccumulatedFees += _amount : shortAccumulatedFees += _amount;
        emit FeesAccumulated(_amount, _isLong);
    }

    function _validateDeposit(uint256 _initialBalance, uint256 _amountIn, bool _isLong) private view {
        if (_isLong) {
            uint256 wethBalance = IERC20(WETH).balanceOf(address(this));

            if (longTokenBalance > wethBalance) revert Vault_InvalidDeposit();

            if (wethBalance != _initialBalance + _amountIn) {
                revert Vault_InvalidDeposit();
            }
        } else {
            uint256 usdcBalance = IERC20(USDC).balanceOf(address(this));

            if (shortTokenBalance > usdcBalance) revert Vault_InvalidDeposit();

            if (usdcBalance != _initialBalance + _amountIn) {
                revert Vault_InvalidDeposit();
            }
        }
    }

    function _validateWithdrawal(uint256 _initialBalance, uint256 _amountOut, bool _isLong) private view {
        if (_isLong) {
            uint256 wethBalance = IERC20(WETH).balanceOf(address(this));
            if (longTokenBalance > wethBalance) revert Vault_InvalidWithdrawal();
            if (wethBalance != _initialBalance - _amountOut) {
                revert Vault_InvalidWithdrawal();
            }
        } else {
            uint256 usdcBalance = IERC20(USDC).balanceOf(address(this));
            if (shortTokenBalance > usdcBalance) revert Vault_InvalidWithdrawal();
            if (usdcBalance != _initialBalance - _amountOut) {
                revert Vault_InvalidWithdrawal();
            }
        }
    }

    /**
     * =============================== Getter Functions ===============================
     */
    function totalAvailableLiquidity(bool _isLong) external view returns (uint256 total) {
        total = _isLong ? longTokenBalance - longTokensReserved : shortTokenBalance - shortTokensReserved;
    }
}
