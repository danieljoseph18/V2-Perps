// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {IPriceOracle} from "../../oracle/interfaces/IPriceOracle.sol";
import {IDataOracle} from "../../oracle/interfaces/IDataOracle.sol";
import {Deposit} from "../../liquidity/Deposit.sol";
import {Withdrawal} from "../../liquidity/Withdrawal.sol";

interface ILiquidityVault {
    // Constructor is not included in the interface

    // Admin functions
    function initialise(
        IPriceOracle _priceOracle,
        IDataOracle _dataOracle,
        address _marketMaker,
        uint32 _minTimeToExpiration,
        uint256 _minExecutionFee,
        uint256 _depositFee,
        uint256 _withdrawalFee
    ) external;
    function updateFees(uint256 _minExecutionFee, uint256 _depositFee, uint256 _withdrawalFee) external;

    // Trading related functions
    function transferPositionProfit(address _user, uint256 _amount, bool _isLong) external;
    function updateReservation(address _user, int256 _amount, bool _isLong) external;
    function accumulateFees(uint256 _amount) external;

    // Deposit execution
    function executeDeposit(bytes32 _key) external;

    // Withdrawal execution
    function executeWithdrawal(bytes32 _key) external;

    // Deposit creation
    function createDeposit(Deposit.Params memory _params) external payable;
    function cancelDeposit(bytes32 _key) external;

    // Withdrawal creation
    function createWithdrawal(Withdrawal.Params memory _params) external payable;
    function cancelWithdrawal(bytes32 _key) external;

    // Getter
    function reservedAmounts(address _user, bool _isLong) external view returns (uint256);

    event DepositRequestCreated(
        bytes32 indexed key, address indexed owner, address indexed tokenIn, uint256 amountIn, uint256 blockNumber
    );
    event DepositRequestCancelled(
        bytes32 indexed key, address indexed owner, address indexed tokenIn, uint256 amountIn
    );
    event WithdrawalRequestCreated(
        bytes32 indexed key,
        address indexed owner,
        address indexed tokenOut,
        uint256 marketTokenAmountIn,
        uint256 blockNumber
    );
    event WithdrawalRequestCancelled(
        bytes32 indexed key, address indexed owner, address indexed tokenOut, uint256 marketTokenAmountIn
    );
    event DepositExecuted(
        bytes32 indexed key, address indexed owner, address indexed tokenIn, uint256 amountIn, uint256 mintAmount
    );
    event WithdrawalExecuted(
        bytes32 indexed key,
        address indexed owner,
        address indexed tokenOut,
        uint256 marketTokenAmountIn,
        uint256 amountOut
    );
    event ProfitTransferred(address indexed user, uint256 amount, bool isLong);
    event LiquidityReserved(address indexed user, uint256 amount, bool isIncrease, bool isLong);
    event FeesAccumulated(uint256 amount);
}
