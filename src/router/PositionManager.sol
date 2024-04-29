// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IMarket} from "../markets/interfaces/IMarket.sol";
import {ITradeStorage} from "../positions/interfaces/ITradeStorage.sol";
import {ITradeEngine} from "../positions/interfaces/ITradeEngine.sol";
import {IMarketFactory} from "../markets/interfaces/IMarketFactory.sol";
import {OwnableRoles} from "../auth/OwnableRoles.sol";
import {ReentrancyGuard} from "../utils/ReentrancyGuard.sol";
import {Position} from "../positions/Position.sol";
import {IERC20} from "../tokens/interfaces/IERC20.sol";
import {SafeTransferLib} from "../libraries/SafeTransferLib.sol";
import {MarketUtils} from "../markets/MarketUtils.sol";
import {IReferralStorage} from "../referrals/interfaces/IReferralStorage.sol";
import {Execution} from "../positions/Execution.sol";
import {IPriceFeed} from "../oracle/interfaces/IPriceFeed.sol";
import {Oracle} from "../oracle/Oracle.sol";
import {Gas} from "../libraries/Gas.sol";
import {IPositionManager} from "./interfaces/IPositionManager.sol";
import {IWETH} from "../tokens/interfaces/IWETH.sol";
import {Borrowing} from "../libraries/Borrowing.sol";
import {IVault} from "../markets/interfaces/IVault.sol";

/// @dev Needs PositionManager Role
// All keeper interactions should come through this contract
// Contract picks up and executes all requests, as well as holds intermediary funds.
contract PositionManager is IPositionManager, OwnableRoles, ReentrancyGuard {
    using SafeTransferLib for IERC20;
    using SafeTransferLib for IWETH;
    using SafeTransferLib for IVault;

    IWETH immutable WETH;
    IERC20 immutable USDC;

    uint256 private constant LONG_BASE_UNIT = 1e18;
    uint256 private constant SHORT_BASE_UNIT = 1e6;
    uint256 constant GAS_BUFFER = 10000;
    string private constant LONG_TICKER = "ETH";
    string private constant SHORT_TICKER = "USDC";

    IMarketFactory public marketFactory;
    IReferralStorage public referralStorage;
    IPriceFeed public priceFeed;

    // Base Gas for a TX
    uint256 public baseGasLimit;
    // Upper Bounds to account for fluctuations
    uint256 public averageDepositCost;
    uint256 public averageWithdrawalCost;
    uint256 public averagePositionCost;

    constructor(address _marketFactory, address _referralStorage, address _priceFeed, address _weth, address _usdc) {
        _initializeOwner(msg.sender);
        marketFactory = IMarketFactory(_marketFactory);
        referralStorage = IReferralStorage(_referralStorage);
        priceFeed = IPriceFeed(_priceFeed);
        WETH = IWETH(_weth);
        USDC = IERC20(_usdc);
    }

    receive() external payable {}

    function updateGasEstimates(uint256 _base, uint256 _deposit, uint256 _withdrawal, uint256 _position)
        external
        onlyOwner
    {
        baseGasLimit = _base;
        averageDepositCost = _deposit;
        averageWithdrawalCost = _withdrawal;
        averagePositionCost = _position;
        emit GasLimitsUpdated(_deposit, _withdrawal, _position);
    }

    function updatePriceFeed(IPriceFeed _priceFeed) external onlyOwner {
        priceFeed = _priceFeed;
    }

    function executeDeposit(IMarket market, bytes32 _key) external payable nonReentrant {
        // Get the Starting Gas -> Used to track Gas Used
        uint256 initialGas = gasleft();

        if (_key == bytes32(0)) revert PositionManager_InvalidKey();
        // Fetch the request
        IVault.ExecuteDeposit memory params = MarketUtils.constructDepositParams(priceFeed, market, _key);
        address vault = address(market.VAULT());
        // Approve the Market to spend the Collateral
        if (params.deposit.isLongToken) WETH.approve(address(vault), params.deposit.amountIn);
        else USDC.approve(address(vault), params.deposit.amountIn);

        // Execute the Deposit
        market.executeDeposit(params);

        // Gas Used + Fee Buffer
        uint256 feeForExecutor = ((initialGas - gasleft()) * tx.gasprice) + ((GAS_BUFFER + 21000) * tx.gasprice);
        uint256 feeToRefund;
        if (feeForExecutor > params.deposit.executionFee) feeToRefund = 0;
        else feeToRefund = params.deposit.executionFee - feeForExecutor;

        // Send Execution Fee + Rebate
        SafeTransferLib.safeTransferETH(params.deposit.owner, feeForExecutor);
        if (feeToRefund > 0) {
            SafeTransferLib.safeTransferETH(msg.sender, feeToRefund);
        }
    }

    function executeWithdrawal(IMarket market, bytes32 _key) external payable nonReentrant {
        // Get the Starting Gas -> Used to track Gas Used
        uint256 initialGas = gasleft();

        if (_key == bytes32(0)) revert PositionManager_InvalidKey();
        // Fetch the request
        IVault.ExecuteWithdrawal memory params = MarketUtils.constructWithdrawalParams(priceFeed, market, _key);
        // Calculate amountOut
        params.amountOut = MarketUtils.calculateWithdrawalAmount(
            params.vault,
            params.longPrices,
            params.shortPrices,
            params.withdrawal.amountIn,
            params.longBorrowFeesUsd,
            params.shortBorrowFeesUsd,
            params.cumulativePnl,
            params.withdrawal.isLongToken
        );

        // Approve the Market to spend deposit tokens
        IERC20(params.vault).approve(address(params.vault), params.withdrawal.amountIn);

        // Execute the Withdrawal
        market.executeWithdrawal(params);

        // Send Execution Fee + Rebate
        uint256 feeForExecutor = (initialGas - gasleft()) * tx.gasprice;

        uint256 feeToRefund = params.withdrawal.executionFee - feeForExecutor;

        SafeTransferLib.safeTransferETH(msg.sender, feeForExecutor);

        if (feeToRefund > 0) {
            SafeTransferLib.safeTransferETH(params.withdrawal.owner, feeToRefund);
        }
    }

    function cancelMarketRequest(IMarket market, bytes32 _requestKey) external nonReentrant {
        // Check if the market exists /  is valid on the market maker
        if (!marketFactory.isMarket(address(market))) revert PositionManager_InvalidMarket();
        // Cancel the Request
        (address tokenOut, uint256 amountOut, bool shouldUnwrap) = market.cancelRequest(_requestKey, msg.sender);
        // Transfer out the Tokens from the Request
        if (shouldUnwrap) {
            // If should unwrap, unwrap the WETH and transfer ETH to the user
            WETH.withdraw(amountOut);
            SafeTransferLib.safeTransferETH(msg.sender, amountOut);
        } else {
            IERC20(tokenOut).safeTransfer(msg.sender, amountOut);
        }
        emit MarketRequestCancelled(_requestKey, msg.sender, tokenOut, amountOut);
    }

    /// @dev For market orders, can just pass in bytes32(0) as the request id, as it's only required for limits
    /// @dev If limit, caller needs to call Router.requestExecutionPricing before, and provide the requestKey as input
    function executePosition(IMarket market, bytes32 _orderKey, bytes32 _requestKey, address _feeReceiver)
        external
        payable
        nonReentrant
    {
        // Get the Starting Gas -> Used to track Gas Used
        uint256 initialGas = gasleft();

        // Get the Trade Storage
        ITradeStorage tradeStorage = ITradeStorage(market.tradeStorage());
        // Execute the Request
        (Execution.FeeState memory feeState, Position.Request memory request) =
            tradeStorage.executePositionRequest(_orderKey, _requestKey, _feeReceiver);

        // Emit Trade Executed Event
        emit ExecutePosition(_orderKey, feeState.positionFee, feeState.affiliateRebate);

        // Send Execution Fee + Rebate
        uint256 executionCost = (initialGas - gasleft()) * tx.gasprice;

        uint256 feeToRefund = request.input.executionFee - executionCost;
        SafeTransferLib.safeTransferETH(msg.sender, executionCost);
        if (feeToRefund > 0) {
            SafeTransferLib.safeTransferETH(request.user, feeToRefund);
        }
    }

    // Only person who requested the pricing for an order should be able to initiate the liquidation,
    // up until a certain time buffer. After that time buffer, any user should be able to.
    /// @dev - Caller needs to call Router.requestExecutionPricing before
    function liquidatePosition(IMarket market, bytes32 _positionKey, bytes32 _requestKey) external payable {
        ITradeStorage(market.tradeStorage()).liquidatePosition(_positionKey, _requestKey, msg.sender);
    }

    function cancelOrderRequest(IMarket market, bytes32 _key, bool _isLimit) external payable nonReentrant {
        ITradeStorage tradeStorage = ITradeStorage(market.tradeStorage());
        // Fetch the Request
        Position.Request memory request = tradeStorage.getOrder(_key);
        // Check it exists
        if (request.user == address(0)) revert PositionManager_RequestDoesNotExist();
        // Check the caller is the position owner
        if (msg.sender != request.user) {
            // if caller is not the request owner --> the request must have an invalidated price to cancel it
            if (!priceFeed.isRequestValid(request.requestKey)) revert PositionManager_CancellationFailed();
        }
        // Check sufficient time has passed
        if (block.timestamp < request.requestTimestamp + tradeStorage.minCancellationTime()) {
            revert PositionManager_InsufficientDelay();
        }
        // Cancel the Request
        tradeStorage.cancelOrderRequest(_key, _isLimit);
        // Refund the Collateral
        IERC20(request.input.collateralToken).safeTransfer(request.user, request.input.collateralDelta);
        // Refund the Execution Fee
        (uint256 refundAmount, uint256 amountForExecutor) = Gas.getRefundForCancellation(request.input.executionFee);
        if (msg.sender == request.user) {
            // If user executes their own cancellation, send in a single transaction
            SafeTransferLib.safeTransferETH(msg.sender, refundAmount + amountForExecutor);
        } else {
            SafeTransferLib.safeTransferETH(request.user, refundAmount);
            SafeTransferLib.safeTransferETH(msg.sender, amountForExecutor);
        }
    }

    // Only person who requested the pricing for an order should be able to initiate the adl,
    // up until a certain time buffer. After that time buffer, any user should be able to.
    /// @dev - Caller needs to call Router.requestExecutionPricing before and provide a valid requestKey
    function executeAdl(IMarket market, bytes32 _requestKey, bytes32 _positionKey) external payable {
        ITradeStorage(market.tradeStorage()).executeAdl(_positionKey, _requestKey, msg.sender);
    }

    /// @dev - Should only be callable from the TradeEngine associated with a valid market
    function transferTokensForIncrease(
        IMarket market,
        IVault vault,
        address _collateralToken,
        uint256 _collateralDelta,
        uint256 _affiliateRebate,
        uint256 _feeForExecutor,
        address _executor
    ) external {
        // Market must be valid
        if (!marketFactory.isMarket(address(market))) revert PositionManager_InvalidMarket();
        // Caller must be the Trade Engine associated with that market
        if (OwnableRoles(address(market)).rolesOf(msg.sender) != _ROLE_5) revert PositionManager_AccessDenied();

        uint256 transferAmount = _collateralDelta;
        // Transfer Fee to Executor
        if (_feeForExecutor > 0) {
            transferAmount -= _feeForExecutor;
            IERC20(_collateralToken).safeTransfer(_executor, _feeForExecutor);
        }
        // Transfer Fee Discount to Referral Storage
        if (_affiliateRebate > 0) {
            // Transfer Fee Discount to Referral Storage
            transferAmount -= _affiliateRebate;
            IERC20(_collateralToken).safeTransfer(address(referralStorage), _affiliateRebate);
        }
        // Send Tokens + Fee to the Vault (Will be Accounted for Separately)
        // Subtract Affiliate Rebate -> will go to Referral Storage
        IERC20(_collateralToken).safeTransfer(address(vault), transferAmount);
    }
}
