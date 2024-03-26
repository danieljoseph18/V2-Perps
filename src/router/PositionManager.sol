// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IMarket} from "../markets/interfaces/IMarket.sol";
import {ITradeStorage} from "../positions/interfaces/ITradeStorage.sol";
import {IMarketMaker} from "../markets/interfaces/IMarketMaker.sol";
import {RoleValidation} from "../access/RoleValidation.sol";
import {ReentrancyGuard} from "@solmate/utils/ReentrancyGuard.sol";
import {Position} from "../positions/Position.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MarketUtils} from "../markets/MarketUtils.sol";
import {Referral} from "../referrals/Referral.sol";
import {IReferralStorage} from "../referrals/interfaces/IReferralStorage.sol";
import {Execution} from "../positions/Execution.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IPriceFeed} from "../oracle/interfaces/IPriceFeed.sol";
import {Oracle} from "../oracle/Oracle.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Gas} from "../libraries/Gas.sol";
import {IPositionManager} from "./interfaces/IPositionManager.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {mulDiv} from "@prb/math/Common.sol";
import {Roles} from "../access/Roles.sol";
import {IWETH} from "../tokens/interfaces/IWETH.sol";
import {Borrowing} from "../libraries/Borrowing.sol";
import {IMarketToken} from "../markets/interfaces/IMarketToken.sol";
import {PositionInvariants} from "../positions/PositionInvariants.sol";

/// @dev Needs PositionManager Role
// All keeper interactions should come through this contract
// Contract picks up and executes all requests, as well as holds intermediary funds.
contract PositionManager is IPositionManager, RoleValidation, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeERC20 for IWETH;
    using SafeERC20 for IMarketToken;
    using SafeCast for uint256;
    using Address for address payable;
    using SignedMath for int256;

    IWETH immutable WETH;
    IERC20 immutable USDC;

    uint256 private LONG_BASE_UNIT = 1e18;
    uint256 private SHORT_BASE_UNIT = 1e6;
    uint256 constant GAS_BUFFER = 10000;

    IMarketMaker public marketMaker;
    IReferralStorage public referralStorage;
    IPriceFeed public priceFeed;

    // Base Gas for a TX
    uint256 public baseGasLimit;
    // Upper Bounds to account for fluctuations
    uint256 public averageDepositCost;
    uint256 public averageWithdrawalCost;
    uint256 public averagePositionCost;

    constructor(
        address _marketMaker,
        address _referralStorage,
        address _priceFeed,
        address _weth,
        address _usdc,
        address _roleStorage
    ) RoleValidation(_roleStorage) {
        marketMaker = IMarketMaker(_marketMaker);
        referralStorage = IReferralStorage(_referralStorage);
        priceFeed = IPriceFeed(_priceFeed);
        WETH = IWETH(_weth);
        USDC = IERC20(_usdc);
    }

    receive() external payable {}

    modifier onlyMarket() {
        if (!marketMaker.isMarket(msg.sender)) revert PositionManager_AccessDenied();
        _;
    }

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

    function executeDeposit(IMarket market, bytes32 _key, Oracle.PriceUpdateData calldata _priceUpdateData)
        external
        payable
        nonReentrant
        onlyKeeper
    {
        // Get the Starting Gas -> Used to track Gas Used
        uint256 initialGas = gasleft();

        // Sign the Latest Oracle Prices
        _signOraclePrices(_priceUpdateData);

        if (_key == bytes32(0)) revert PositionManager_InvalidKey();
        // Fetch the request
        IMarket.ExecuteDeposit memory params;
        params.market = market;
        params.deposit = market.getRequest(_key);
        params.key = _key;
        // Get the signed prices
        (params.longPrices, params.shortPrices) = Oracle.getMarketTokenPrices(priceFeed);
        // Calculate cumulative borrow fees
        params.longBorrowFeesUsd = Borrowing.getTotalFeesOwedByMarkets(market, true);
        params.shortBorrowFeesUsd = Borrowing.getTotalFeesOwedByMarkets(market, false);
        // Calculate Cumulative PNL
        params.cumulativePnl =
            MarketUtils.calculateCumulativeMarketPnl(market, priceFeed, params.deposit.isLongToken, true); // Maximize AUM for deposits
        params.marketToken = market.MARKET_TOKEN();

        // Approve the Market to spend the Collateral
        // @audit - could someone front-run?
        if (params.deposit.isLongToken) WETH.approve(address(market), params.deposit.amountIn);
        else USDC.approve(address(market), params.deposit.amountIn);

        // Execute the Deposit
        market.executeDeposit(params);

        // Clear all previously signed prices
        _clearOraclePrices();

        // Gas Used + Fee Buffer
        uint256 feeForExecutor = ((initialGas - gasleft()) * tx.gasprice) + ((GAS_BUFFER + 21000) * tx.gasprice);
        uint256 feeToRefund;
        if (feeForExecutor > params.deposit.executionFee) feeToRefund = 0;
        else feeToRefund = params.deposit.executionFee - feeForExecutor;

        // Send Execution Fee + Rebate
        payable(params.deposit.owner).sendValue(feeForExecutor);
        if (feeToRefund > 0) payable(msg.sender).sendValue(feeToRefund);
    }

    function cancelDeposit(IMarket market, bytes32 _depositKey) external nonReentrant {
        IMarket.Input memory deposit = market.getRequest(_depositKey);
        if (deposit.owner != msg.sender) revert PositionManager_InvalidDepositOwner();
        if (deposit.expirationTimestamp >= block.timestamp) revert PositionManager_DepositNotExpired();
        if (!deposit.isDeposit) revert PositionManager_InvalidDeposit();
        market.deleteRequest(_depositKey);
        IERC20 tokenOut = deposit.isLongToken ? WETH : USDC;
        tokenOut.safeTransfer(msg.sender, deposit.amountIn);
        emit DepositRequestCancelled(_depositKey, deposit.owner, address(tokenOut), deposit.amountIn);
    }

    function executeWithdrawal(IMarket market, bytes32 _key, Oracle.PriceUpdateData calldata _priceUpdateData)
        external
        payable
        nonReentrant
        onlyKeeper
    {
        // Get the Starting Gas -> Used to track Gas Used
        uint256 initialGas = gasleft();

        // Sign the Latest Oracle Prices
        _signOraclePrices(_priceUpdateData);

        if (_key == bytes32(0)) revert PositionManager_InvalidKey();
        // Fetch the request
        IMarket.ExecuteWithdrawal memory params;
        params.market = market;
        params.withdrawal = market.getRequest(_key);
        params.key = _key;
        params.cumulativePnl =
            MarketUtils.calculateCumulativeMarketPnl(market, priceFeed, params.withdrawal.isLongToken, false); // Minimize AUM for withdrawals
        params.shouldUnwrap = params.withdrawal.reverseWrap;
        // Calculate the amount out
        (params.longPrices, params.shortPrices) = Oracle.getMarketTokenPrices(priceFeed);
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
            LONG_BASE_UNIT,
            params.shortBorrowFeesUsd,
            SHORT_BASE_UNIT,
            params.cumulativePnl,
            params.withdrawal.isLongToken
        );

        // Approve the Market to spend deposit tokens
        // @audit - could someone front-run?
        IERC20(params.marketToken).approve(address(market), params.withdrawal.amountIn);

        // Execute the Withdrawal
        market.executeWithdrawal(params);

        // Clear all previously signed prices
        _clearOraclePrices();

        // Send Execution Fee + Rebate
        uint256 feeForExecutor = (initialGas - gasleft()) * tx.gasprice;

        uint256 feeToRefund = params.withdrawal.executionFee - feeForExecutor;

        payable(params.withdrawal.owner).sendValue(feeForExecutor);

        if (feeToRefund > 0) {
            payable(msg.sender).sendValue(feeToRefund);
        }
    }

    // @audit - feels wrong
    // @audit - can combine with cancel deposit
    function cancelWithdrawal(IMarket market, bytes32 _withdrawalKey) external nonReentrant {
        IMarket.Input memory withdrawal = market.getRequest(_withdrawalKey);
        if (withdrawal.owner != msg.sender) revert PositionManager_InvalidWithdrawalOwner();
        if (withdrawal.expirationTimestamp >= block.timestamp) revert PositionManager_WithdrawalNotExpired();
        if (withdrawal.isDeposit) revert PositionManager_InvalidWithdrawal();
        market.deleteRequest(_withdrawalKey);
        IERC20 tokenOut = withdrawal.isLongToken ? WETH : USDC;
        tokenOut.safeTransfer(msg.sender, withdrawal.amountIn);
        emit WithdrawalRequestCancelled(_withdrawalKey, withdrawal.owner, address(tokenOut), withdrawal.amountIn);
    }

    // Used to transfer intermediary tokens to the market from deposits
    // @audit - permissions -> could someone create a malicious market and transfer tokens from it?
    // how do we make sure only the intended market can call this?
    function transferDepositTokens(address _market, address _token, uint256 _amount) external onlyMarket {
        IERC20(_token).safeTransfer(_market, _amount);
    }

    /// @dev Only Keeper
    function executePosition(
        IMarket market,
        bytes32 _orderKey,
        address _feeReceiver,
        Oracle.PriceUpdateData calldata _priceUpdateData
    ) external payable nonReentrant onlyKeeper {
        // Get the Starting Gas -> Used to track Gas Used
        uint256 initialGas = gasleft();

        // Sign the Latest Oracle Prices
        _signOraclePrices(_priceUpdateData);

        (Execution.State memory state, Position.Request memory request, ITradeStorage tradeStorage) =
            Execution.constructParams(market, marketMaker, priceFeed, _orderKey, _feeReceiver);
        // Fetch the State of the Market Before the Position
        IMarket.MarketStorage memory marketBefore = market.getStorage(request.input.assetId);

        _updateImpactPool(market, request.input.assetId, state.priceImpactUsd);
        _updateMarketState(
            market,
            state,
            request.input.assetId,
            request.input.sizeDelta,
            request.input.isLong,
            request.input.isIncrease
        );

        // Calculate Fee
        state.fee = Position.calculateFee(
            tradeStorage,
            request.input.sizeDelta,
            request.input.collateralDelta,
            state.collateralPrice,
            state.collateralBaseUnit
        );

        // Calculate & Apply Fee Discount for Referral Code
        (state.fee, state.affiliateRebate, state.referrer) =
            Referral.applyFeeDiscount(referralStorage, request.user, state.fee);

        // Execute Trade
        if (request.requestType == Position.RequestType.CREATE_POSITION) {
            tradeStorage.createNewPosition(Position.Settlement(request, _orderKey, _feeReceiver, false), state);
        } else if (request.requestType == Position.RequestType.POSITION_DECREASE) {
            tradeStorage.decreaseExistingPosition(Position.Settlement(request, _orderKey, _feeReceiver, false), state);
        } else if (request.requestType == Position.RequestType.POSITION_INCREASE) {
            tradeStorage.increaseExistingPosition(Position.Settlement(request, _orderKey, _feeReceiver, false), state);
        } else if (request.requestType == Position.RequestType.COLLATERAL_DECREASE) {
            tradeStorage.executeCollateralDecrease(Position.Settlement(request, _orderKey, _feeReceiver, false), state);
        } else if (request.requestType == Position.RequestType.COLLATERAL_INCREASE) {
            tradeStorage.executeCollateralIncrease(Position.Settlement(request, _orderKey, _feeReceiver, false), state);
        } else if (request.requestType == Position.RequestType.TAKE_PROFIT) {
            tradeStorage.decreaseExistingPosition(Position.Settlement(request, _orderKey, _feeReceiver, false), state);
        } else if (request.requestType == Position.RequestType.STOP_LOSS) {
            tradeStorage.decreaseExistingPosition(Position.Settlement(request, _orderKey, _feeReceiver, false), state);
        } else {
            revert PositionManager_InvalidRequestType();
        }

        // Fetch the State of the Market After the Position
        IMarket.MarketStorage memory marketAfter = market.getStorage(request.input.assetId);

        // Invariant Check
        PositionInvariants.validateMarketDeltaPosition(marketBefore, marketAfter, request);

        if (request.input.isIncrease) {
            _transferTokensForIncrease(
                market, request.input.collateralToken, request.input.collateralDelta, state.affiliateRebate
            );
        }

        // Emit Trade Executed Event
        emit ExecutePosition(_orderKey, request, state.fee, state.affiliateRebate);

        // Clear all previously signed prices
        _clearOraclePrices();

        // Send Execution Fee + Rebate
        // Execution Fee reduced to account for value sent to update Pyth prices
        uint256 executionCost = (initialGas - gasleft()) * tx.gasprice;

        uint256 feeToRefund = request.input.executionFee - executionCost;
        payable(msg.sender).sendValue(executionCost);
        if (feeToRefund > 0) {
            payable(request.user).sendValue(feeToRefund);
        }
    }

    function liquidatePosition(IMarket market, bytes32 _positionKey, Oracle.PriceUpdateData calldata _priceUpdateData)
        external
        payable
        onlyLiquidationKeeper
    {
        // Sign the Latest Oracle Prices
        _signOraclePrices(_priceUpdateData);
        // Construct ExecutionState
        Execution.State memory state;
        ITradeStorage tradeStorage = ITradeStorage(market.tradeStorage());
        // fetch position
        Position.Data memory position = tradeStorage.getPosition(_positionKey);

        if (position.isLong) {
            // Min Price -> rounds in favour of the protocol
            state.indexPrice = Oracle.getMinPrice(priceFeed, position.assetId);
            (state.longMarketTokenPrice, state.shortMarketTokenPrice) = Oracle.getMarketTokenPrices(priceFeed, false);
            state.collateralPrice = state.longMarketTokenPrice;
        } else {
            // Max Price -> rounds in favour of the protocol
            state.indexPrice = Oracle.getMaxPrice(priceFeed, position.assetId);
            (state.longMarketTokenPrice, state.shortMarketTokenPrice) = Oracle.getMarketTokenPrices(priceFeed, true);
            state.collateralPrice = state.shortMarketTokenPrice;
        }

        state.indexBaseUnit = Oracle.getBaseUnit(priceFeed, position.assetId);
        // No price impact on Liquidations
        state.impactedPrice = state.indexPrice;

        state.collateralBaseUnit =
            position.isLong ? Oracle.getLongBaseUnit(priceFeed) : Oracle.getShortBaseUnit(priceFeed);

        // Update the state of the market
        _updateMarketState(market, state, position.assetId, position.positionSize, position.isLong, false);
        // liquidate the position
        try tradeStorage.liquidatePosition(state, _positionKey, msg.sender) {}
        catch {
            revert PositionManager_LiquidationFailed();
        }

        // Clear all previously signed prices
        _clearOraclePrices();
    }

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
            if (block.number < request.requestBlock + tradeStorage.minBlockDelay()) {
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

    function executeAdl(
        IMarket market,
        bytes32 _assetId,
        uint256 _sizeDelta,
        bytes32 _positionKey,
        bool _isLong,
        Oracle.PriceUpdateData calldata _priceUpdateData
    ) external payable onlyAdlKeeper {
        // Sign the Latest Oracle Prices
        _signOraclePrices(_priceUpdateData);
        Execution.State memory state;
        IMarket.AdlConfig memory adl = MarketUtils.getAdlConfig(market, _assetId);
        // Get the storage
        ITradeStorage tradeStorage = ITradeStorage(market.tradeStorage());
        // Check the position in question is active
        Position.Data memory position = tradeStorage.getPosition(_positionKey);
        if (position.positionSize == 0) revert PositionManager_PositionNotActive();
        // state the market
        market = market;
        // Get current MarketUtils and token data
        state = Execution.cacheTokenPrices(priceFeed, state, position.assetId, position.isLong, false);

        // Set the impacted price to the index price => 0 price impact on ADLs
        state.impactedPrice = state.indexPrice;
        state.priceImpactUsd = 0;
        // Get starting PNL Factor
        int256 startingPnlFactor = _getPnlFactor(market, state, _assetId, _isLong);
        // fetch max pnl to pool ratio
        uint256 maxPnlFactor = MarketUtils.getMaxPnlFactor(market, _assetId);

        // Check the PNL Factor is greater than the max PNL Factor
        if (startingPnlFactor.abs() <= maxPnlFactor || startingPnlFactor < 0) {
            revert PositionManager_PnlToPoolRatioNotExceeded(startingPnlFactor, maxPnlFactor);
        }

        // Construct an ADL Order
        Position.Settlement memory request = Position.createAdlOrder(position, _sizeDelta);
        // Execute the order
        tradeStorage.decreaseExistingPosition(request, state);
        // Get the new PNL to pool ratio
        int256 newPnlFactor = _getPnlFactor(market, state, _assetId, _isLong);
        // PNL to pool has reduced
        if (newPnlFactor >= startingPnlFactor) revert PositionManager_PNLFactorNotReduced();
        // Check if the new PNL to pool ratio is below the threshold
        // Fire event to alert the keepers
        if (newPnlFactor.abs() <= adl.targetPnlFactor) {
            emit AdlTargetRatioReached(market, newPnlFactor, _isLong);
        }
        emit AdlExecuted(market, _positionKey, _sizeDelta, _isLong);

        // Clear all previously signed prices
        _clearOraclePrices();
    }

    function _signOraclePrices(Oracle.PriceUpdateData calldata _priceUpdateData) internal {
        uint256 updateFee = priceFeed.updateFee(_priceUpdateData.pythData);
        if (msg.value < updateFee) revert PositionManager_PriceUpdateFee();
        priceFeed.setPrimaryPrices{value: msg.value}(
            _priceUpdateData.assetIds, _priceUpdateData.pythData, _priceUpdateData.compactedPrices
        );
    }

    function _clearOraclePrices() internal {
        priceFeed.clearPrimaryPrices();
    }

    function _transferTokensForIncrease(
        IMarket market,
        address _collateralToken,
        uint256 _collateralDelta,
        uint256 _affiliateRebate
    ) internal {
        // Transfer Fee Discount to Referral Storage
        uint256 tokensPlusFee = _collateralDelta;
        if (_affiliateRebate > 0) {
            // Transfer Fee Discount to Referral Storage
            tokensPlusFee -= _affiliateRebate;
            IERC20(_collateralToken).safeTransfer(address(referralStorage), _affiliateRebate);
        }
        // Send Tokens + Fee to the Market (Will be Accounted for Separately)
        // Subtract Affiliate Rebate -> will go to Referral Storage
        IERC20(_collateralToken).safeTransfer(address(market), tokensPlusFee);
    }

    function _updateMarketState(
        IMarket market,
        Execution.State memory _state,
        bytes32 _assetId,
        uint256 _sizeDelta,
        bool _isLong,
        bool _isIncrease
    ) internal {
        market.updateMarketState(
            _assetId,
            _sizeDelta,
            _state.indexPrice,
            _state.impactedPrice,
            _state.indexBaseUnit,
            _state.collateralPrice,
            _isLong,
            _isIncrease
        );
    }

    function _updateImpactPool(IMarket market, bytes32 _assetId, int256 _priceImpactUsd) internal {
        // If Price Impact is Negative, add to the impact Pool
        // If Price Impact is Positive, Subtract from the Impact Pool
        // Impact Pool Delta = -1 * Price Impact
        if (_priceImpactUsd == 0) return;
        market.updateImpactPool(_assetId, -_priceImpactUsd);
    }

    /**
     * Extrapolated into an internal function to prevent STD Errors
     */
    function _getPnlFactor(IMarket market, Execution.State memory _state, bytes32 _assetId, bool _isLong)
        internal
        view
        returns (int256 pnlFactor)
    {
        pnlFactor = MarketUtils.getPnlFactor(
            market,
            _assetId,
            _state.indexPrice,
            _state.indexBaseUnit,
            _state.collateralPrice,
            _state.collateralBaseUnit,
            _isLong
        );
    }
}
