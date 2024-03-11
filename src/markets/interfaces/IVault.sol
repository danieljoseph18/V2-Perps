// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {Deposit} from "../Deposit.sol";
import {Withdrawal} from "../Withdrawal.sol";
import {IPriceFeed} from "../../oracle/interfaces/IPriceFeed.sol";

interface IVault {
    // Admin functions
    function updateFees(address _poolOwner, address _feeDistributor, uint256 _feeScale, uint256 _feePercentageToOwner)
        external;
    function updatePriceFeed(IPriceFeed _priceFeed) external;

    // Trading related functions
    function reserveLiquidity(uint256 _amount, bool _isLong) external;
    function unreserveLiquidity(uint256 _amount, bool _isLong) external;
    function accumulateFees(uint256 _amount, bool _isLong) external;
    function decreasePoolBalance(uint256 _amount, bool _isLong) external;
    function increasePoolBalance(uint256 _amount, bool _isLong) external;
    function transferOutTokens(address _to, uint256 _amount, bool _isLongToken, bool _shouldUnwrap) external;

    // Deposit execution
    function executeDeposit(Deposit.ExecuteParams memory _params) external;

    // Withdrawal execution
    function executeWithdrawal(Withdrawal.ExecuteParams memory _params) external;

    // Deposit creation
    function createDeposit(Deposit.Input memory _params) external payable;
    function cancelDeposit(bytes32 _key, address _caller) external;

    // Withdrawal creation
    function createWithdrawal(Withdrawal.Input memory _params) external payable;
    function cancelWithdrawal(bytes32 _key, address _caller) external;

    // Getter
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
    function getPoolValues() external view returns (uint256, uint256, uint256, uint256, uint256);

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
        address indexed _liquidator, uint256 indexed _liqFee, address _market, uint256 _totalCollateral, bool _isLong
    );
    event FeesWithdrawn(uint256 _longFees, uint256 _shortFees);
    event TransferInCollateral(address indexed _market, uint256 indexed _collateralDelta, bool _isLong);
    event MarketAdded(address indexed _market);

    error Vault_InvalidKey();
    error Vault_InvalidPoolOwner();
    error Vault_InvalidFeeDistributor();
    error Vault_InvalidFeeScale();
    error Vault_InvalidFeePercentage();
    error Vault_InsufficientAvailableTokens();
    error Vault_InvalidUnwrapToken();
}
