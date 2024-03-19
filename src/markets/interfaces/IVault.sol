// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IPriceFeed} from "../../oracle/interfaces/IPriceFeed.sol";
import {IMarket} from "./IMarket.sol";
import {IPositionManager} from "../../router/interfaces/IPositionManager.sol";
import {Oracle} from "../../oracle/Oracle.sol";

interface IVault {
    struct VaultConfig {
        address longToken;
        address shortToken;
        uint64 longBaseUnit;
        uint64 shortBaseUnit;
        uint64 feeScale;
        uint64 feePercentageToOwner;
        uint48 minTimeToExpiration;
        address priceFeed;
        address positionManager;
        address poolOwner;
        address feeDistributor;
        string name;
        string symbol;
    }

    // For snapshotting state for invariant checks
    struct State {
        uint256 longPoolBalance;
        uint256 shortPoolBalance;
        uint256 longAccumulatedFees;
        uint256 shortAccumulatedFees;
        uint256 totalSupply;
        uint256 wethBalance;
        uint256 usdcBalance;
    }

    struct Deposit {
        uint256 amountIn;
        uint256 executionFee;
        address owner;
        uint48 expirationTimestamp;
        bool isLongToken;
        bool shouldWrap;
        uint256 blockNumber;
        bytes32 key;
    }

    struct Withdrawal {
        uint256 marketTokenAmountIn;
        uint256 executionFee;
        address owner;
        uint48 expirationTimestamp;
        bool isLongToken;
        bool shouldUnwrap;
        uint256 blockNumber;
        bytes32 key;
    }

    struct ExecuteDeposit {
        IMarket market;
        IPositionManager positionManager;
        IPriceFeed priceFeed;
        Deposit deposit;
        bytes32 key;
        int256 cumulativePnl;
    }

    struct ExecuteWithdrawal {
        IMarket market;
        IPositionManager positionManager;
        IPriceFeed priceFeed;
        Withdrawal withdrawal;
        Oracle.Price longPrices;
        Oracle.Price shortPrices;
        bytes32 key;
        int256 cumulativePnl;
        uint256 amountOut;
        bool shouldUnwrap;
    }
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
    function increaseCollateralAmount(uint256 _amount, address _user, bool _islong) external;
    function decreaseCollateralAmount(uint256 _amount, address _user, bool _islong) external;

    // Deposit execution
    function executeDeposit(ExecuteDeposit memory _params) external;

    // Withdrawal execution
    function executeWithdrawal(ExecuteWithdrawal memory _params) external;

    // Deposit creation
    function createDeposit(address owner, address tokenIn, uint256 amountIn, uint256 executionFee, bool shouldWrap)
        external
        payable;
    function deleteDeposit(bytes32 _key) external;

    // Withdrawal creation
    function createWithdrawal(
        address _owner,
        address _tokenOut,
        uint256 _marketTokenAmountIn,
        uint256 _executionFee,
        bool _shouldUnwrap
    ) external payable;
    function deleteWithdrawal(bytes32 _key) external;
    function withdrawMarketTokensToTokens(
        Oracle.Price memory _longPrices,
        Oracle.Price memory _shortPrices,
        uint256 _marketTokenAmountIn,
        int256 _cumulativePnl,
        bool _isLongToken
    ) external view returns (uint256 tokenAmount);

    // Getter
    function collateralAmounts(address _user, bool _isLong) external view returns (uint256);
    function feeScale() external view returns (uint256);
    function BASE_FEE() external view returns (uint256);
    function getDepositRequest(bytes32 _key) external view returns (Deposit memory);
    function getWithdrawalRequest(bytes32 _key) external view returns (Withdrawal memory);
    function longTokenBalance() external view returns (uint256);
    function shortTokenBalance() external view returns (uint256);
    function longAccumulatedFees() external view returns (uint256);
    function shortAccumulatedFees() external view returns (uint256);
    function longTokensReserved() external view returns (uint256);
    function shortTokensReserved() external view returns (uint256);
    function totalAvailableLiquidity(bool _isLong) external view returns (uint256 total);
    function LONG_TOKEN() external view returns (address);
    function SHORT_TOKEN() external view returns (address);
    function getDepositRequestAtIndex(uint256 _index) external view returns (Deposit memory);
    function getWithdrawalRequestAtIndex(uint256 _index) external view returns (Withdrawal memory);
    function getPoolValues() external view returns (uint256, uint256, uint256, uint256, uint256);
    function getTokenBalances() external view returns (uint256, uint256);
    function getReservedAmounts() external view returns (uint256, uint256);

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
    error Vault_FailedToAddDeposit();
    error Vault_FailedToAddWithdrawal();
    error Vault_FailedToRemoveWithdrawal();
    error Vault_FailedToRemoveDeposit();
    error Vault_InsufficientLongBalance();
    error Vault_InsufficientShortBalance();
    error Vault_InsufficientCollateral();
    error Vault_InvalidAmountOut(uint256 actualOut, uint256 expectedOut);
}
