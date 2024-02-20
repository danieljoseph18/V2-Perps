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
    function reserveLiquidity(uint256 _amount, bool _isLong) external;
    function unreserveLiquidity(uint256 _amount, bool _isLong) external;
    function accumulateFees(uint256 _amount, bool _isLong) external;
    function sendExecutionFee(address payable _processor, uint256 _executionFee) external;
    function accumulateFundingFees(uint256 _amount, bool _isLong) external;
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

    // Withdrawal creation
    function createWithdrawal(Withdrawal.Input memory _params) external payable;
    function cancelWithdrawal(bytes32 _key, address _caller) external;

    // Mint and Burn
    function mint(address _user, uint256 _amount) external;
    function burn(uint256 _amount) external;

    // Funding
    function increaseUserClaimableFunding(uint256 _amount, bool _isLong) external;

    // Getter
    function executionFee() external view returns (uint256);
    function feeScale() external view returns (uint256);
    function BASE_FEE() external view returns (uint256);
    function getDepositRequest(bytes32 _key) external view returns (Deposit.Data memory);
    function getWithdrawalRequest(bytes32 _key) external view returns (Withdrawal.Data memory);
    function longTokenBalance() external view returns (uint256);
    function shortTokenBalance() external view returns (uint256);
    function longAccumulatedFees() external view returns (uint256);
    function shortAccumulatedFees() external view returns (uint256);
    function longTokensReserved() external view returns (uint256);
    function shortTokensReserved() external view returns (uint256);
    function totalAvailableLiquidity(bool _isLong) external view returns (uint256 total);
    function LONG_TOKEN() external view returns (address);
    function SHORT_TOKEN() external view returns (address);
    function getDepositRequestAtIndex(uint256 _index) external view returns (Deposit.Data memory);
    function getWithdrawalRequestAtIndex(uint256 _index) external view returns (Withdrawal.Data memory);

    event DepositRequestCreated(
        bytes32 indexed key, address indexed owner, address indexed tokenIn, uint256 amountIn, uint256 blockNumber
    );
    event DepositRequestCancelled(
        bytes32 indexed key, address indexed owner, address indexed tokenIn, uint256 amountIn
    );
    event DepositExecuted(
        bytes32 indexed key, address indexed owner, address indexed tokenIn, uint256 amountIn, uint256 mintAmount
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