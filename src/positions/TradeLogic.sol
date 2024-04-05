// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Execution} from "./Execution.sol";
import {Position} from "./Position.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {IPriceFeed} from "../oracle/interfaces/IPriceFeed.sol";
import {IReferralStorage} from "../referrals/interfaces/IReferralStorage.sol";
import {ITradeStorage} from "./interfaces/ITradeStorage.sol";
import {MarketUtils} from "../markets/MarketUtils.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";

library TradeLogic {
    using SignedMath for int256;

    error TradeLogic_InvalidRequestType();
    error TradeLogic_InsufficientFreeLiquidity();
    error TradeLogic_PositionAdditionFailed();
    error TradeLogic_PositionDoesNotExist();
    error TradeLogic_InvalidLiquidationFee();
    error TradeLogic_InvalidTradingFee();
    error TradeLogic_InvalidAdlFee();
    error TradeLogic_InvalidFeeForExecution();
    error TradeLogic_StopLossAlreadySet();
    error TradeLogic_TakeProfitAlreadySet();

    event CollateralEdited(bytes32 indexed _positionKey, uint256 indexed _collateralDelta, bool indexed _isIncrease);
    event PositionCreated(bytes32 indexed _positionKey);
    event IncreasePosition(bytes32 indexed _positionKey, uint256 indexed _collateralDelta, uint256 indexed _sizeDelta);
    event DecreasePosition(bytes32 indexed _positionKey, uint256 indexed _collateralDelta, uint256 indexed _sizeDelta);
    event AdlExecuted(address _market, bytes32 _positionKey, uint256 _sizeDelta, bool _isLong);
    event LiquidatePosition(
        bytes32 indexed _positionKey, address indexed _liquidator, uint256 indexed _amountLiquidated, bool _isLong
    );
    event OrderRequestCancelled(bytes32 indexed _orderKey);

    uint256 private constant MAX_LIQUIDATION_FEE = 0.1e18; // 10%
    uint256 private constant MIN_LIQUIDATION_FEE = 0.001e18; // 1%
    uint256 private constant MAX_TRADING_FEE = 0.01e18; // 1%
    uint256 private constant MIN_TRADING_FEE = 0.00001e18; // 0.001%
    uint256 private constant MAX_ADL_FEE = 0.05e18; // 5%
    uint256 private constant MIN_ADL_FEE = 0.0001e18; // 0.01%
    uint256 private constant MAX_FEE_FOR_EXECUTION = 0.3e18; // 30%
    uint256 private constant MIN_FEE_FOR_EXECUTION = 0.05e18; // 5%

    function validateFees(uint256 _liquidationFee, uint256 _positionFee, uint256 _adlFee, uint256 _feeForExecution)
        external
        pure
    {
        if (_liquidationFee > MAX_LIQUIDATION_FEE || _liquidationFee < MIN_LIQUIDATION_FEE) {
            revert TradeLogic_InvalidLiquidationFee();
        }
        if (_positionFee > MAX_TRADING_FEE || _positionFee < MIN_TRADING_FEE) {
            revert TradeLogic_InvalidTradingFee();
        }
        if (_adlFee > MAX_ADL_FEE || _adlFee < MIN_ADL_FEE) {
            revert TradeLogic_InvalidAdlFee();
        }
        if (_feeForExecution > MAX_FEE_FOR_EXECUTION || _feeForExecution < MIN_FEE_FOR_EXECUTION) {
            revert TradeLogic_InvalidFeeForExecution();
        }
    }

    function createOrderRequest(Position.Request calldata _request) external {
        ITradeStorage tradeStorage = ITradeStorage(address(this));
        // Create the order
        bytes32 orderKey = tradeStorage.createOrder(_request);
        // If SL / TP, tie to the position
        bytes32 positionKey = Position.generateKey(_request);
        Position.Data memory position = tradeStorage.getPosition(positionKey);
        if (position.user == address(0)) revert TradeLogic_PositionDoesNotExist();
        if (_request.requestType == Position.RequestType.STOP_LOSS) {
            if (position.stopLossKey != bytes32(0)) revert TradeLogic_StopLossAlreadySet();
            position.stopLossKey = orderKey;
        } else {
            if (position.takeProfitKey != bytes32(0)) revert TradeLogic_TakeProfitAlreadySet();
            position.takeProfitKey = orderKey;
        }
        tradeStorage.updatePosition(position, positionKey);
    }

    function cancelOrderRequest(bytes32 _orderKey, bool _isLimit) external {
        // Delete the order
        ITradeStorage(address(this)).deleteOrder(_orderKey, _isLimit);
        // Fire Event
        emit OrderRequestCancelled(_orderKey);
    }

    // @gas - for tradeStorage can I just use ITradeStorage(address(this))?
    function executePositionRequest(
        IMarket market,
        IPriceFeed priceFeed,
        IReferralStorage referralStorage,
        bytes32 _orderKey,
        bytes32 _requestId,
        address _feeReceiver
    ) external returns (Execution.State memory state, Position.Request memory request) {
        ITradeStorage tradeStorage = ITradeStorage(address(this));
        (state, request) = Execution.constructParams(
            market, tradeStorage, priceFeed, referralStorage, _orderKey, _requestId, _feeReceiver
        );
        // Fetch the State of the Market Before the Position
        IMarket.MarketStorage memory initialMarket = market.getStorage(request.input.ticker);

        // Delete the Order from Storage
        tradeStorage.deleteOrder(_orderKey, request.input.isLimit);

        // Update the Market State
        tradeStorage.updateMarketState(
            state, request.input.ticker, request.input.sizeDelta, request.input.isLong, request.input.isIncrease
        );

        // Execute Trade
        if (request.requestType == Position.RequestType.CREATE_POSITION) {
            _createNewPosition(
                tradeStorage, market, Position.Settlement(request, _orderKey, _feeReceiver, false), state
            );
        } else if (request.requestType == Position.RequestType.POSITION_INCREASE) {
            _increasePosition(tradeStorage, market, Position.Settlement(request, _orderKey, _feeReceiver, false), state);
        } else if (
            request.requestType == Position.RequestType.POSITION_DECREASE
                || request.requestType == Position.RequestType.TAKE_PROFIT
                || request.requestType == Position.RequestType.STOP_LOSS
        ) {
            _decreasePosition(tradeStorage, market, Position.Settlement(request, _orderKey, _feeReceiver, false), state);
        } else if (request.requestType == Position.RequestType.COLLATERAL_DECREASE) {
            _executeCollateralDecrease(
                tradeStorage, market, Position.Settlement(request, _orderKey, _feeReceiver, false), state
            );
        } else if (request.requestType == Position.RequestType.COLLATERAL_INCREASE) {
            _executeCollateralIncrease(
                tradeStorage, market, Position.Settlement(request, _orderKey, _feeReceiver, false), state
            );
        } else {
            revert TradeLogic_InvalidRequestType();
        }

        // Clear the Signed Prices
        priceFeed.clearSignedPrices(market, request.requestId);

        // Fetch the State of the Market After the Position
        IMarket.MarketStorage memory updatedMarket = market.getStorage(request.input.ticker);

        // Invariant Check
        Position.validateMarketDelta(initialMarket, updatedMarket, request);
    }

    // @audit - needs more constraints before we can make permissionless
    // - only allow adl on profitable positions above a threshold
    // - only allow reduction of the pnl factor by so much
    // - how do we make sure that users can only ADL the most profitable positions?
    function executeAdl(
        IMarket market,
        IPriceFeed priceFeed,
        bytes32 _positionKey,
        bytes32 _requestId,
        address _feeReceiver,
        uint256 _adlFee
    ) external {
        ITradeStorage tradeStorage = ITradeStorage(address(this));
        // Construct the Adl order
        (
            Execution.State memory state,
            Position.Settlement memory params,
            Position.Data memory position,
            int256 startingPnlFactor
        ) = Execution.constructAdlOrder(
            market, tradeStorage, priceFeed, _positionKey, _requestId, _adlFee, _feeReceiver
        );

        // Update the Market State
        tradeStorage.updateMarketState(
            state,
            params.request.input.ticker,
            params.request.input.sizeDelta,
            params.request.input.isLong,
            params.request.input.isIncrease
        );

        // Execute the order
        _decreasePosition(tradeStorage, market, params, state);

        // Clear signed prices
        priceFeed.clearSignedPrices(market, _requestId);

        // Validate the Adl
        Execution.validateAdl(market, state, startingPnlFactor, params.request.input.ticker, position.isLong);

        emit AdlExecuted(address(market), _positionKey, params.request.input.sizeDelta, position.isLong);
    }

    function liquidatePosition(
        IMarket market,
        IPriceFeed priceFeed,
        bytes32 _positionKey,
        bytes32 _requestId,
        address _liquidator
    ) external {
        ITradeStorage tradeStorage = ITradeStorage(address(this));
        // Fetch the Position
        Position.Data memory position = tradeStorage.getPosition(_positionKey);
        // Check the Position Exists
        if (position.user == address(0)) revert TradeLogic_PositionDoesNotExist();
        // Construct the Execution State
        Execution.State memory state;
        state = Execution.cacheTokenPrices(priceFeed, state, position.ticker, _requestId, position.isLong, false);
        // No price impact on Liquidations
        state.impactedPrice = state.indexPrice;
        // Update the Market State
        tradeStorage.updateMarketState(state, position.ticker, position.positionSize, position.isLong, false);
        // Construct Liquidation Order
        Position.Settlement memory params = Position.constructLiquidationOrder(position, _liquidator, _requestId);
        // Execute the Liquidation
        _decreasePosition(tradeStorage, market, params, state);
        // Clear Signed Prices
        // Need request id
        priceFeed.clearSignedPrices(market, _requestId);
        // Fire Event
        emit LiquidatePosition(_positionKey, _liquidator, position.collateralAmount, position.isLong);
    }

    /**
     * ========================= Internal Functions =========================
     */
    function _executeCollateralIncrease(
        ITradeStorage tradeStorage,
        IMarket market,
        Position.Settlement memory _params,
        Execution.State memory _state
    ) internal {
        // Get the Position Key
        bytes32 positionKey = Position.generateKey(_params.request);
        // Perform Execution in Library
        Position.Data memory positionAfter;
        (positionAfter, _state) = Execution.increaseCollateral(market, tradeStorage, _params, _state, positionKey);
        // Add Value to Stored Collateral Amount in Market
        market.updateCollateralAmount(
            _params.request.input.collateralDelta - _state.positionFee - _state.feeForExecutor - _state.affiliateRebate
                - _state.borrowFee,
            _params.request.user,
            _params.request.input.isLong,
            true
        );
        // Account for any Funding
        if (_state.fundingFee < 0) {
            // User Paid Funding
            uint256 absFundingFee = _state.fundingFee.abs();
            market.updatePoolBalance(absFundingFee, positionAfter.isLong, true);
        } else if (_state.fundingFee > 0) {
            // User got Paid Funding
            uint256 absFundingFee = _state.fundingFee.abs();
            market.updatePoolBalance(absFundingFee, positionAfter.isLong, false);
        }
        // Pay Fees
        tradeStorage.payFees(
            _state.borrowFee, _state.positionFee, _state.affiliateRebate, _state.referrer, _params.request.input.isLong
        );
        // Update Final Storage
        tradeStorage.updatePosition(positionAfter, positionKey);
        emit CollateralEdited(positionKey, _params.request.input.collateralDelta, _params.request.input.isIncrease);
    }

    function _executeCollateralDecrease(
        ITradeStorage tradeStorage,
        IMarket market,
        Position.Settlement memory _params,
        Execution.State memory _state
    ) internal {
        // Get the Position Key
        bytes32 positionKey = Position.generateKey(_params.request);
        // Perform Execution in Library
        Position.Data memory positionAfter;
        uint256 amountOut;
        (positionAfter, _state, amountOut) = Execution.decreaseCollateral(
            market,
            tradeStorage,
            _params,
            _state,
            tradeStorage.minCollateralUsd(),
            tradeStorage.liquidationFee(),
            positionKey
        );
        if (_state.fundingFee < 0) {
            // User Paid Funding
            market.updatePoolBalance(_state.fundingFee.abs(), positionAfter.isLong, true);
        } else if (_state.fundingFee > 0) {
            // User got Paid Funding
            market.updatePoolBalance(_state.fundingFee.abs(), positionAfter.isLong, false);
        }
        // Check Market has enough available liquidity for payout
        if (
            MarketUtils.getPoolBalance(market, _params.request.input.ticker, _params.request.input.isLong)
                < amountOut + _state.affiliateRebate
        ) {
            revert TradeLogic_InsufficientFreeLiquidity();
        }
        // Decrease the Collateral Amount in the Market by the full delta
        market.updateCollateralAmount(
            _params.request.input.collateralDelta, _params.request.user, _params.request.input.isLong, false
        );
        // Pay Fees
        tradeStorage.payFees(
            _state.borrowFee, _state.positionFee, _state.affiliateRebate, _state.referrer, _params.request.input.isLong
        );
        // Update Final Storage
        tradeStorage.updatePosition(positionAfter, positionKey);
        // Transfer Rebate to Referrer
        if (_state.affiliateRebate > 0) {
            market.transferOutTokens(
                _state.referrer,
                _state.affiliateRebate,
                _params.request.input.isLong,
                false // Leave unwrapped by default
            );
        }
        // Transfer Execution Fee to Executor
        if (_state.feeForExecutor > 0) {
            market.transferOutTokens(_params.feeReceiver, _state.feeForExecutor, _params.request.input.isLong, true);
        }
        // Transfer Tokens to User
        market.transferOutTokens(
            _params.request.user, amountOut, _params.request.input.isLong, _params.request.input.reverseWrap
        );
        // Fire Event
        emit CollateralEdited(positionKey, _params.request.input.collateralDelta, _params.request.input.isIncrease);
    }

    function _createNewPosition(
        ITradeStorage tradeStorage,
        IMarket market,
        Position.Settlement memory _params,
        Execution.State memory _state
    ) internal {
        // Get the Position Key
        bytes32 positionKey = Position.generateKey(_params.request);
        // Perform Execution in the Library
        Position.Data memory position;
        (position, _state) = Execution.createNewPosition(
            market, tradeStorage, _params, _state, tradeStorage.minCollateralUsd(), positionKey
        );
        // If Request has conditionals, create the SL / TP
        (Position.Request memory stopLoss, Position.Request memory takeProfit) = Position.constructConditionalOrders(
            position, _params.request.input.conditionals, _params.request.input.executionFee
        );
        // If stop loss set, create and store the order
        if (_params.request.input.conditionals.stopLossSet) position.stopLossKey = tradeStorage.createOrder(stopLoss);
        // If take profit set, create and store the order
        if (_params.request.input.conditionals.takeProfitSet) {
            position.takeProfitKey = tradeStorage.createOrder(takeProfit);
        }
        // Pay fees
        tradeStorage.payFees(
            0, _state.positionFee, _state.affiliateRebate, _state.referrer, _params.request.input.isLong
        );
        // Reserve Liquidity Equal to the Position Size
        tradeStorage.reserveLiquidity(
            _params.request.input.sizeDelta,
            position.collateralAmount,
            _state.collateralPrice,
            _state.collateralBaseUnit,
            position.user,
            _params.request.input.isLong
        );
        // Update Final Storage
        tradeStorage.createPosition(position, positionKey);
        // Fire Event
        emit PositionCreated(positionKey);
    }

    function _increasePosition(
        ITradeStorage tradeStorage,
        IMarket market,
        Position.Settlement memory _params,
        Execution.State memory _state
    ) internal {
        // Get the Position Key
        bytes32 positionKey = Position.generateKey(_params.request);
        // Perform Execution in the Library
        Position.Data memory position;
        (position, _state) = Execution.increasePosition(market, tradeStorage, _params, _state, positionKey);
        // Pay Fees
        tradeStorage.payFees(
            _state.borrowFee, _state.positionFee, _state.affiliateRebate, _state.referrer, _params.request.input.isLong
        );
        // Reserve Liquidity Equal to the Position Size
        tradeStorage.reserveLiquidity(
            _params.request.input.sizeDelta,
            _params.request.input.collateralDelta - _state.positionFee - _state.feeForExecutor - _state.affiliateRebate
                - _state.borrowFee,
            _state.collateralPrice,
            _state.collateralBaseUnit,
            position.user,
            _params.request.input.isLong
        );
        // If user's position has increased with positive funding, need to subtract from the pool
        // If user's position has decreased with negative funding, need to add to the pool
        if (_state.fundingFee > 0) market.updatePoolBalance(_state.fundingFee.abs(), position.isLong, false);
        else if (_state.fundingFee < 0) market.updatePoolBalance(_state.fundingFee.abs(), position.isLong, true);
        // Update Final Storage
        tradeStorage.updatePosition(position, positionKey);
        // Fire event
        emit IncreasePosition(positionKey, _params.request.input.collateralDelta, _params.request.input.sizeDelta);
    }

    function _decreasePosition(
        ITradeStorage tradeStorage,
        IMarket market,
        Position.Settlement memory _params,
        Execution.State memory _state
    ) internal {
        // Get the Position Key
        bytes32 positionKey = Position.generateKey(_params.request);
        // Perform Execution in the Library
        Position.Data memory positionAfter;
        Execution.DecreaseState memory decreaseState;
        (positionAfter, decreaseState, _state) = Execution.decreasePosition(
            market,
            tradeStorage,
            _params,
            _state,
            tradeStorage.minCollateralUsd(),
            tradeStorage.liquidationFee(),
            positionKey
        );

        uint256 amountOut;

        if (decreaseState.isLiquidation) {
            // Remanining collateral after fees is added to the relevant pool
            market.updatePoolBalance(positionAfter.collateralAmount, positionAfter.isLong, true);
            // Accumulate the fees to accumulate
            market.accumulateFees(decreaseState.feesToAccumulate, positionAfter.isLong);
            // Set amount out
            amountOut = decreaseState.feesOwedToUser;
            // Decrease the pool amount by the amount being payed out to the user
            if (amountOut > 0) {
                market.updatePoolBalance(amountOut, positionAfter.isLong, false);
            }
        } else {
            // Pay Fees
            tradeStorage.payFees(
                _state.borrowFee,
                _state.positionFee,
                _state.affiliateRebate,
                _state.referrer,
                _params.request.input.isLong
            );
            // Set Amount Out
            amountOut = decreaseState.decreasePnl > 0
                ? decreaseState.afterFeeAmount + decreaseState.decreasePnl.abs() // Profit Case
                : decreaseState.afterFeeAmount; // Loss / Break Even Case -> Losses already deducted in Execution if any
            // Pay any positive funding accrued. Negative Funding Deducted in Execution
            amountOut += _state.fundingFee > 0 ? _state.fundingFee.abs() : 0;
            // If profit being payed out, need to decrease the pool amount by the profit
            if (amountOut > decreaseState.afterFeeAmount) {
                market.updatePoolBalance(amountOut - decreaseState.afterFeeAmount, positionAfter.isLong, false);
            }
        }

        // Unreserve Liquidity
        tradeStorage.unreserveLiquidity(
            _params.request.input.sizeDelta,
            _params.request.input.collateralDelta,
            _state.collateralPrice,
            _state.collateralBaseUnit,
            positionAfter.user,
            _params.request.input.isLong
        );

        // Delete the Position if Full Decrease
        if (positionAfter.positionSize == 0 || positionAfter.collateralAmount == 0) {
            tradeStorage.deletePosition(positionKey, _params.request.input.isLong);
        } else {
            // Update Final Storage
            tradeStorage.updatePosition(positionAfter, positionKey);
        }

        // Check Market has enough available liquidity for payout
        if (market.totalAvailableLiquidity(_params.request.input.isLong) < amountOut + _state.affiliateRebate) {
            revert TradeLogic_InsufficientFreeLiquidity();
        }
        // Transfer Liquidation Fees to the Liquidator
        if (decreaseState.liqFee > 0) {
            // Pay the liquidator
            market.transferOutTokens(
                _params.feeReceiver, // Liquidator
                decreaseState.liqFee,
                positionAfter.isLong,
                true // Unwrap by default
            );
        } else {
            // Transfer the Fee to the Executor
            // Liquidations don't receive additional execution fees as they are already paid out in the liquidation fee
            if (_state.feeForExecutor > 0) {
                market.transferOutTokens(_params.feeReceiver, _state.feeForExecutor, _params.request.input.isLong, true);
            }
        }
        // Transfer Rebate to Referrer
        if (_state.affiliateRebate > 0) {
            market.transferOutTokens(
                _state.referrer,
                _state.affiliateRebate,
                _params.request.input.isLong,
                false // Leave unwrapped by default
            );
        }
        // Transfer Tokens to User
        if (amountOut > 0) {
            market.transferOutTokens(
                _params.request.user, amountOut, _params.request.input.isLong, _params.request.input.reverseWrap
            );
        }
        // Fire Event
        emit DecreasePosition(positionKey, _params.request.input.collateralDelta, _params.request.input.sizeDelta);
    }
}
