// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {IExecutor} from "../../execution/interfaces/IExecutor.sol";
import {Deposit} from "../../liquidity/Deposit.sol";
import {Withdrawal} from "../../liquidity/Withdrawal.sol";
import {IPriceFeed} from "../../oracle/interfaces/IPriceFeed.sol";

interface ILiquidityVault {
    // Constructor is not included in the interface

    // Admin functions
    function initialise(
        IPriceFeed _priceFeed,
        IExecutor _executor,
        uint48 _minTimeToExpiration,
        uint8 _priceImpactExponent,
        uint256 _priceImpactFactor,
        uint256 _executionFee,
        uint256 _depositFee,
        uint256 _withdrawalFee
    ) external;
    function updateFees(uint256 _executionFee, uint256 _depositFee, uint256 _withdrawalFee) external;

    // Trading related functions
    function transferPositionProfit(address _user, uint256 _amount, bool _isLong) external;
    function updateReservation(address _user, int256 _amount, bool _isLong) external;
    function accumulateFees(uint256 _amount, bool _isLong) external;
    function sendExecutionFee(address payable _executor, uint256 _executionFee) external;
    function transferOutTokens(address _market, address _to, uint256 _collateralDelta, bool _isLong) external;
    function liquidatePositionCollateral(
        address _liquidator,
        uint256 _liqFee,
        address _market,
        uint256 _totalCollateral,
        uint256 _collateralFundingOwed,
        bool _isLong
    ) external;
    function claimFundingFees(address _market, address _user, uint256 _claimed, bool _isLong) external;
    function swapFundingAmount(address _market, uint256 _amount, bool _isLong) external;
    function recordCollateralTransferIn(address _market, uint256 _collateralDelta, bool _isLong) external;

    // Deposit execution
    function executeDeposit(bytes32 _key, int256 _cumulativePnl, address _executor) external;

    // Withdrawal execution
    function executeWithdrawal(bytes32 _key, int256 _cumulativePnl, address _executor) external;

    // Deposit creation
    function createDeposit(Deposit.Params memory _params) external payable;
    function cancelDeposit(bytes32 _key, address _caller) external;

    // Withdrawal creation
    function createWithdrawal(Withdrawal.Params memory _params) external payable;
    function cancelWithdrawal(bytes32 _key, address _caller) external;

    // Getter
    function reservedAmounts(address _user, bool _isLong) external view returns (uint256);
    function executionFee() external view returns (uint256);
    function depositFee() external view returns (uint256);
    function withdrawalFee() external view returns (uint256);

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
    event FeesAccumulated(uint256 amount, bool _isLong);
    event TransferOutTokens(address _market, address indexed _to, uint256 _collateralDelta, bool _isLong);
    event PositionCollateralLiquidated(
        address indexed _liquidator,
        uint256 indexed _liqFee,
        address _market,
        uint256 _totalCollateral,
        uint256 _collateralFundingOwed,
        bool _isLong
    );
    event TransferInCollateral(address indexed _market, uint256 indexed _collateralDelta, bool _isLong);
}
