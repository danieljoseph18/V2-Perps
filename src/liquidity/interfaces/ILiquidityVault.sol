// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {Deposit} from "../../liquidity/Deposit.sol";
import {Withdrawal} from "../../liquidity/Withdrawal.sol";

interface ILiquidityVault {
    // Constructor is not included in the interface

    // Admin functions
    function initialise(
        address _priceFeed,
        address _processor,
        uint48 _minTimeToExpiration,
        uint256 _executionFee,
        uint256 _feeScale
    ) external;
    function updateFees(uint256 _executionFee, uint256 _feeScale) external;

    // Trading related functions
    function transferPositionProfit(address _user, uint256 _amount, bool _isLong) external;
    function updateReservation(address _user, int256 _amount, bool _isLong) external;
    function accumulateFees(uint256 _amount, bool _isLong) external;
    function sendExecutionFee(address payable _processor, uint256 _executionFee) external;
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
    function decreasePoolBalance(uint256 _amount, bool _isLong) external;
    function increasePoolBalance(uint256 _amount, bool _isLong) external;
    function transferOutTokens(address _to, uint256 _amount, bool _isLongToken, bool _shouldUnwrap) external;

    // Deposit execution
    function executeDeposit(Deposit.ExecuteParams memory _cache) external;

    // Withdrawal execution
    function executeWithdrawal(Withdrawal.ExecuteParams memory _cache) external;

    // Deposit creation
    function createDeposit(Deposit.Input memory _params) external payable;
    function cancelDeposit(bytes32 _key, address _caller) external;
    function deleteDeposit(bytes32 _key) external;

    // Withdrawal creation
    function createWithdrawal(Withdrawal.Input memory _params) external payable;
    function cancelWithdrawal(bytes32 _key, address _caller) external;
    function deleteWithdrawal(bytes32 _key) external;

    // Mint and Burn
    function mint(address _user, uint256 _amount) external;
    function burn(uint256 _amount) external;

    // Getter
    function reservedAmounts(address _user, bool _isLong) external view returns (uint256);
    function executionFee() external view returns (uint256);
    function feeScale() external view returns (uint256);
    function BASE_FEE() external view returns (uint256);
    function getDepositRequest(bytes32 _key) external view returns (Deposit.Data memory);
    function getWithdrawalRequest(bytes32 _key) external view returns (Withdrawal.Data memory);

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
