// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IERC20} from "../../tokens/interfaces/IERC20.sol";
import {IMarket} from "./IMarket.sol";
import {Pool} from "../Pool.sol";
import {EnumerableMap} from "../../libraries/EnumerableMap.sol";
import {Oracle} from "../../oracle/Oracle.sol";
import {IGlobalRewardTracker} from "../../rewards/interfaces/IGlobalRewardTracker.sol";

interface IVault is IERC20 {
    // Only used in memory as a cache for updating state
    // No packing necessary
    struct ExecuteDeposit {
        IMarket market;
        IVault vault;
        Pool.Input deposit;
        Oracle.Prices longPrices;
        Oracle.Prices shortPrices;
        bytes32 key;
        uint256 longBorrowFeesUsd;
        uint256 shortBorrowFeesUsd;
        int256 cumulativePnl;
    }

    // Only used in memory as a cache for updating state
    // No packing necessary
    struct ExecuteWithdrawal {
        IMarket market;
        IVault vault;
        Pool.Input withdrawal;
        Oracle.Prices longPrices;
        Oracle.Prices shortPrices;
        bytes32 key;
        uint256 longBorrowFeesUsd;
        uint256 shortBorrowFeesUsd;
        int256 cumulativePnl;
        uint256 amountOut;
        bool shouldUnwrap;
    }

    event DepositExecuted(
        bytes32 indexed key, address indexed account, address indexed token, uint256 amountIn, uint256 mintAmount
    );
    event WithdrawalExecuted(
        bytes32 indexed key, address indexed account, address indexed token, uint256 amountIn, uint256 amountOut
    );
    event FeesAccumulated(uint256 amount, bool isLong);
    event FeesWithdrawn(uint256 longFees, uint256 shortFees);

    error Vault_AlreadyInitialized();
    error Vault_InsufficientAvailableTokens();
    error Vault_InvalidDeposit();
    error Vault_InvalidWithdrawal();
    error Vault_AccessDenied();

    function initialize(address _market, address _feeDistributor, address _rewardTracker, address _feeReceiver)
        external;
    function executeDeposit(ExecuteDeposit calldata _params, address _tokenIn, address _positionManager) external;
    function executeWithdrawal(ExecuteWithdrawal calldata _params, address _tokenOut, address _positionManager)
        external;
    function updateCollateralAmount(uint256 _amount, address _user, bool _isLong, bool _isIncrease, bool _isFullClose)
        external;
    function updatePoolBalance(uint256 _amount, bool _isLong, bool _isIncrease) external;
    function updateLiquidityReservation(uint256 _amount, bool _isLong, bool _isIncrease) external;
    function transferOutTokens(address _to, uint256 _amount, bool _isLongToken, bool _shouldUnwrap) external;
    function accumulateFees(uint256 _amount, bool _isLong) external;
    function collateralAmounts(address _user, bool _isLong) external view returns (uint256);
    function longTokenBalance() external view returns (uint256);
    function shortTokenBalance() external view returns (uint256);
    function longTokensReserved() external view returns (uint256);
    function shortTokensReserved() external view returns (uint256);
    function totalAvailableLiquidity(bool _isLong) external view returns (uint256 total);
    function rewardTracker() external view returns (IGlobalRewardTracker);
}
