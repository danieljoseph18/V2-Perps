// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IMarket} from "../markets/interfaces/IMarket.sol";
import {ITradeStorage} from "../positions/interfaces/ITradeStorage.sol";
import {IMarketFactory} from "../markets/interfaces/IMarketFactory.sol";
import {RoleValidation} from "../access/RoleValidation.sol";
import {ReentrancyGuard} from "@solmate/utils/ReentrancyGuard.sol";
import {Position} from "../positions/Position.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MarketUtils} from "../markets/MarketUtils.sol";
import {IReferralStorage} from "../referrals/interfaces/IReferralStorage.sol";
import {Execution} from "../positions/Execution.sol";
import {IPriceFeed} from "../oracle/interfaces/IPriceFeed.sol";
import {Oracle} from "../oracle/Oracle.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Gas} from "../libraries/Gas.sol";
import {IPositionManager} from "./interfaces/IPositionManager.sol";
import {Roles} from "../access/Roles.sol";
import {IWETH} from "../tokens/interfaces/IWETH.sol";
import {Borrowing} from "../libraries/Borrowing.sol";
import {IMarketToken} from "../markets/interfaces/IMarketToken.sol";

/// @dev Needs PositionManager Role
// All keeper interactions should come through this contract
// Contract picks up and executes all requests, as well as holds intermediary funds.
contract PositionManager is IPositionManager, RoleValidation, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeERC20 for IWETH;
    using SafeERC20 for IMarketToken;
    using Address for address payable;

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

    constructor(
        address _marketFactory,
        address _referralStorage,
        address _priceFeed,
        address _weth,
        address _usdc,
        address _roleStorage
    ) RoleValidation(_roleStorage) {
        marketFactory = IMarketFactory(_marketFactory);
        referralStorage = IReferralStorage(_referralStorage);
        priceFeed = IPriceFeed(_priceFeed);
        WETH = IWETH(_weth);
        USDC = IERC20(_usdc);
    }

    receive() external payable {}

    function updateGasEstimates(uint256 _base, uint256 _deposit, uint256 _withdrawal, uint256 _position)
        external
        onlyAdmin
    {
        baseGasLimit = _base;
        averageDepositCost = _deposit;
        averageWithdrawalCost = _withdrawal;
        averagePositionCost = _position;
        emit GasLimitsUpdated(_deposit, _withdrawal, _position);
    }

    function updatePriceFeed(IPriceFeed _priceFeed) external onlyAdmin {
        priceFeed = _priceFeed;
    }

    function executeDeposit(IMarket market, bytes32 _key) external payable nonReentrant onlyKeeper {
        // Get the Starting Gas -> Used to track Gas Used
        uint256 initialGas = gasleft();

        if (_key == bytes32(0)) revert PositionManager_InvalidKey();
        // Fetch the request
        IMarket.ExecuteDeposit memory params;
        params.market = market;
        params.deposit = market.getRequest(_key);
        params.key = _key;
        // Get the signed prices
        (params.longPrices, params.shortPrices) = Oracle.getMarketTokenPrices(priceFeed, params.deposit.priceRequestId);
        // Calculate cumulative borrow fees
        params.longBorrowFeesUsd = Borrowing.getTotalFeesOwedByMarkets(market, true);
        params.shortBorrowFeesUsd = Borrowing.getTotalFeesOwedByMarkets(market, false);
        // Calculate Cumulative PNL
        params.cumulativePnl = priceFeed.getCumulativePnl(params.deposit.pnlRequestId);
        params.marketToken = market.MARKET_TOKEN();

        // Approve the Market to spend the Collateral
        if (params.deposit.isLongToken) WETH.approve(address(market), params.deposit.amountIn);
        else USDC.approve(address(market), params.deposit.amountIn);

        // Execute the Deposit
        market.executeDeposit(params);

        // Gas Used + Fee Buffer
        uint256 feeForExecutor = ((initialGas - gasleft()) * tx.gasprice) + ((GAS_BUFFER + 21000) * tx.gasprice);
        uint256 feeToRefund;
        if (feeForExecutor > params.deposit.executionFee) feeToRefund = 0;
        else feeToRefund = params.deposit.executionFee - feeForExecutor;

        // Send Execution Fee + Rebate
        payable(params.deposit.owner).sendValue(feeForExecutor);
        if (feeToRefund > 0) payable(msg.sender).sendValue(feeToRefund);
    }

    function executeWithdrawal(IMarket market, bytes32 _key) external payable nonReentrant onlyKeeper {
        // Get the Starting Gas -> Used to track Gas Used
        uint256 initialGas = gasleft();

        if (_key == bytes32(0)) revert PositionManager_InvalidKey();
        // Fetch the request
        IMarket.ExecuteWithdrawal memory params;
        params.market = market;
        params.withdrawal = market.getRequest(_key);
        params.key = _key;
        params.cumulativePnl = priceFeed.getCumulativePnl(params.withdrawal.pnlRequestId);
        params.shouldUnwrap = params.withdrawal.reverseWrap;
        // Calculate the amount out
        (params.longPrices, params.shortPrices) =
            Oracle.getMarketTokenPrices(priceFeed, params.withdrawal.priceRequestId);
        // Calculate cumulative borrow fees
        params.longBorrowFeesUsd = Borrowing.getTotalFeesOwedByMarkets(market, true);
        params.shortBorrowFeesUsd = Borrowing.getTotalFeesOwedByMarkets(market, false);
        params.marketToken = market.MARKET_TOKEN();
        // Calculate amountOut
        params.amountOut = MarketUtils.calculateWithdrawalAmount(
            market,
            params.marketToken,
            params.longPrices,
            params.shortPrices,
            params.withdrawal.amountIn,
            params.longBorrowFeesUsd,
            params.shortBorrowFeesUsd,
            params.cumulativePnl,
            params.withdrawal.isLongToken
        );

        // Approve the Market to spend deposit tokens
        IERC20(params.marketToken).approve(address(market), params.withdrawal.amountIn);

        // Execute the Withdrawal
        market.executeWithdrawal(params);

        // Send Execution Fee + Rebate
        uint256 feeForExecutor = (initialGas - gasleft()) * tx.gasprice;

        uint256 feeToRefund = params.withdrawal.executionFee - feeForExecutor;

        payable(params.withdrawal.owner).sendValue(feeForExecutor);

        if (feeToRefund > 0) {
            payable(msg.sender).sendValue(feeToRefund);
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
            payable(msg.sender).sendValue(amountOut);
        } else {
            IERC20(tokenOut).safeTransfer(msg.sender, amountOut);
        }
        emit MarketRequestCancelled(_requestKey, msg.sender, tokenOut, amountOut);
    }

    /// @dev For market orders, can just pass in bytes32(0) as the request id, as it's only required for limits
    /// @dev If limit, caller needs to call Router.requestExecutionPricing before, and provide the requestId as input
    function executePosition(IMarket market, bytes32 _orderKey, bytes32 _requestId, address _feeReceiver)
        external
        payable
        nonReentrant
        onlyKeeper
    {
        // Get the Starting Gas -> Used to track Gas Used
        uint256 initialGas = gasleft();

        // Get the Trade Storage
        ITradeStorage tradeStorage = ITradeStorage(market.tradeStorage());
        // Execute the Request
        (Execution.FeeState memory feeState, Position.Request memory request) =
            tradeStorage.executePositionRequest(_orderKey, _requestId, _feeReceiver);

        // Emit Trade Executed Event
        emit ExecutePosition(_orderKey, feeState.positionFee, feeState.affiliateRebate);

        // Send Execution Fee + Rebate
        uint256 executionCost = (initialGas - gasleft()) * tx.gasprice;

        uint256 feeToRefund = request.input.executionFee - executionCost;
        payable(msg.sender).sendValue(executionCost);
        if (feeToRefund > 0) {
            payable(request.user).sendValue(feeToRefund);
        }
    }

    // Only person who requested the pricing for an order should be able to initiate the liquidation,
    // up until a certain time buffer. After that time buffer, any user should be able to.
    /// @dev - Caller needs to call Router.requestExecutionPricing before
    function liquidatePosition(IMarket market, bytes32 _positionKey, bytes32 _requestId)
        external
        payable
        onlyLiquidationKeeper
    {
        ITradeStorage tradeStorage = ITradeStorage(market.tradeStorage());
        // liquidate the position
        try tradeStorage.liquidatePosition(_positionKey, _requestId, msg.sender) {}
        catch {
            revert PositionManager_LiquidationFailed();
        }
    }

    /// @dev - Only callable from Keeper or Request Owner
    function cancelOrderRequest(IMarket market, bytes32 _key, bool _isLimit) external payable nonReentrant {
        ITradeStorage tradeStorage = ITradeStorage(market.tradeStorage());
        // Fetch the Request
        Position.Request memory request = tradeStorage.getOrder(_key);
        // Check it exists
        if (request.user == address(0)) revert PositionManager_RequestDoesNotExist();
        // Check if the caller's permissions
        if (!roleStorage.hasRole(Roles.KEEPER, msg.sender)) {
            // Check the caller is the position owner
            if (msg.sender != request.user) revert PositionManager_NotPositionOwner();
            // Check sufficient time has passed
            if (block.timestamp < request.requestTimestamp + tradeStorage.minCancellationTime()) {
                revert PositionManager_InsufficientDelay();
            }
        }
        // Cancel the Request
        tradeStorage.cancelOrderRequest(_key, _isLimit);
        // Refund the Collateral
        IERC20(request.input.collateralToken).safeTransfer(msg.sender, request.input.collateralDelta);
        // Refund the Execution Fee
        uint256 refundAmount = Gas.getRefundForCancellation(request.input.executionFee);
        payable(msg.sender).sendValue(refundAmount);
    }

    // Only person who requested the pricing for an order should be able to initiate the adl,
    // up until a certain time buffer. After that time buffer, any user should be able to.
    /// @dev - Caller needs to call Router.requestExecutionPricing before and provide a valid requestId
    function executeAdl(IMarket market, bytes32 _requestId, bytes32 _positionKey) external payable onlyAdlKeeper {
        ITradeStorage tradeStorage = ITradeStorage(market.tradeStorage());
        // Execute the ADL
        tradeStorage.executeAdl(_positionKey, _requestId, msg.sender);
    }

    function transferTokensForIncrease(
        IMarket market,
        address _collateralToken,
        uint256 _collateralDelta,
        uint256 _affiliateRebate,
        uint256 _feeForExecutor
    ) external onlyTradeStorage(address(market)) {
        uint256 transferAmount = _collateralDelta;
        // Transfer Fee to Executor
        if (_feeForExecutor > 0) {
            transferAmount -= _feeForExecutor;
            IERC20(_collateralToken).safeTransfer(msg.sender, _feeForExecutor);
        }
        // Transfer Fee Discount to Referral Storage
        if (_affiliateRebate > 0) {
            // Transfer Fee Discount to Referral Storage
            transferAmount -= _affiliateRebate;
            IERC20(_collateralToken).safeTransfer(address(referralStorage), _affiliateRebate);
        }
        // Send Tokens + Fee to the Market (Will be Accounted for Separately)
        // Subtract Affiliate Rebate -> will go to Referral Storage
        IERC20(_collateralToken).safeTransfer(address(market), transferAmount);
    }
}
