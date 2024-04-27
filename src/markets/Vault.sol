// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {ERC20} from "../tokens/ERC20.sol";
import {IERC20} from "../tokens/interfaces/IERC20.sol";
import {IVault} from "./interfaces/IVault.sol";
import {RoleValidation} from "../access/RoleValidation.sol";
import {SafeTransferLib} from "../libraries/SafeTransferLib.sol";
import {MarketLogic} from "./MarketLogic.sol";
import {MarketUtils} from "./MarketUtils.sol";
import {EnumerableMap} from "../libraries/EnumerableMap.sol";
import {IMarket} from "./interfaces/IMarket.sol";
import {IWETH} from "../tokens/interfaces/IWETH.sol";
import {ReentrancyGuard} from "../utils/ReentrancyGuard.sol";
import {IRewardTracker} from "../rewards/interfaces/IRewardTracker.sol";
import {IFeeDistributor} from "../rewards/interfaces/IFeeDistributor.sol";

contract Vault is ERC20, IVault, RoleValidation, ReentrancyGuard {
    using SafeTransferLib for IERC20;
    using SafeTransferLib for IVault;

    address private immutable WETH;
    address private immutable USDC;

    IMarket market;
    IRewardTracker public rewardTracker;
    IFeeDistributor feeDistributor;

    address poolOwner;
    address feeReceiver;

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
        if (msg.sender != address(market)) revert RoleValidation_AccessDenied();
        _;
    }

    constructor(address _weth, address _usdc, string memory _name, string memory _symbol, address _roleStorage)
        ERC20(_name, _symbol, 18)
        RoleValidation(_roleStorage)
    {
        WETH = _weth;
        USDC = _usdc;
    }

    receive() external payable {
        // Only accept ETH via fallback from the WETH contract when unwrapping WETH
        // Ensure that the call depth is 1 (direct call from WETH contract)
        if (msg.sender != WETH || gasleft() <= 2300) revert Vault_InvalidETHTransfer();
    }

    function initialize(address _market) external onlyMarketFactory {
        if (isInitialized) revert Vault_AlreadyInitialized();
        market = IMarket(_market);
        isInitialized = true;
    }

    /**
     * =============================== Storage Functions ===============================
     */
    function updateLiquidityReservation(uint256 _amount, bool _isLong, bool _isIncrease)
        external
        onlyTradeStorage(address(market))
    {
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

    function updatePoolBalance(uint256 _amount, bool _isLong, bool _isIncrease)
        external
        onlyTradeStorage(address(market))
    {
        _updatePoolBalance(_amount, _isLong, _isIncrease);
    }

    function updateCollateralAmount(uint256 _amount, address _user, bool _isLong, bool _isIncrease, bool _isFullClose)
        external
        onlyTradeStorage(address(market))
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

    function accumulateFees(uint256 _amount, bool _isLong) external onlyTradeStorage(address(market)) {
        _accumulateFees(_amount, _isLong);
    }

    function batchWithdrawFees() external onlyConfigurator(address(this)) nonReentrant {
        uint256 longFees = longAccumulatedFees;
        uint256 shortFees = shortAccumulatedFees;
        longAccumulatedFees = 0;
        shortAccumulatedFees = 0;
        MarketLogic.batchWithdrawFees(WETH, USDC, address(feeDistributor), feeReceiver, poolOwner, longFees, shortFees);
    }

    function executeDeposit(ExecuteDeposit calldata _params, address _tokenIn, address _positionManager)
        external
        onlyMarket
    {
        // Cache the initial state
        State memory initialState = getState(_params.deposit.isLongToken);
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
        MarketLogic.validateAction(initialState, _params.deposit.amountIn, 0, _params.deposit.isLongToken, true);
    }

    function executeWithdrawal(ExecuteWithdrawal calldata _params, address _tokenOut, address _positionManager)
        external
        onlyMarket
    {
        // Cache the initial state
        State memory initialState = getState(_params.withdrawal.isLongToken);

        // Transfer Market Tokens in
        IVault(this).safeTransferFrom(_positionManager, address(this), _params.withdrawal.amountIn);

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
        MarketLogic.validateAction(
            initialState, _params.withdrawal.amountIn, transferAmountOut, _params.withdrawal.isLongToken, false
        );
    }

    /**
     * =============================== Token Transfers ===============================
     */
    // @audit - does this follow token transfer best practices? Is it best to invoke a function,
    // or to do an approve --> transfer from call?
    function transferOutTokens(address _to, uint256 _amount, bool _isLongToken, bool _shouldUnwrap)
        external
        onlyTradeEngine(address(market))
    {
        _transferOutTokens(_isLongToken ? WETH : USDC, _to, _amount, _isLongToken, _shouldUnwrap);
    }

    /**
     * =============================== Private Functions ===============================
     */
    function _transferInTokens(address _token, address _from, uint256 _amount) private {
        IERC20(_token).safeTransferFrom(_from, address(this), _amount);
    }

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

    /**
     * =============================== Getter Functions ===============================
     */
    function getState(bool _isLong) public view returns (State memory) {
        if (_isLong) {
            return State({
                totalSupply: totalSupply,
                wethBalance: IERC20(WETH).balanceOf(address(this)),
                usdcBalance: IERC20(USDC).balanceOf(address(this)),
                accumulatedFees: longAccumulatedFees,
                poolBalance: longTokenBalance
            });
        } else {
            return State({
                totalSupply: totalSupply,
                wethBalance: IERC20(WETH).balanceOf(address(this)),
                usdcBalance: IERC20(USDC).balanceOf(address(this)),
                accumulatedFees: shortAccumulatedFees,
                poolBalance: shortTokenBalance
            });
        }
    }
}
