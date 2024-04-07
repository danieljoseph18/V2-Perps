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
import {mulDiv} from "@prb/math/Common.sol";

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

    /// @notice Creates a new Order Request
    function createOrderRequest(Position.Request calldata _request) external {
        ITradeStorage tradeStorage = ITradeStorage(address(this));
        // Create the order
        bytes32 orderKey = tradeStorage.createOrder(_request);
        // If SL / TP, tie to the position
        _attachConditionalOrder(tradeStorage, _request, orderKey);
    }

    /// @notice Executes a Request for a Position
    /// Called by keepers -> Routes the execution down the correct path.
    function executePositionRequest(
        IMarket market,
        IPriceFeed priceFeed,
        IReferralStorage referralStorage,
        bytes32 _orderKey,
        bytes32 _requestId,
        address _feeReceiver
    ) external returns (Execution.State memory state, Position.Request memory request) {
        ITradeStorage tradeStorage = ITradeStorage(address(this));
        // Initiate the execution
        (state, request) =
            Execution.initiate(tradeStorage, market, priceFeed, referralStorage, _orderKey, _requestId, _feeReceiver);
        // Fetch the State of the Market Before the Position
        IMarket.MarketStorage memory initialStorage = market.getStorage(request.input.ticker);
        // Delete the Order from Storage
        tradeStorage.deleteOrder(_orderKey, request.input.isLimit);
        // Update the Market State for the Request
        _updateMarketState(
            market, state, request.input.ticker, request.input.sizeDelta, request.input.isLong, request.input.isIncrease
        );
        // Execute Trade
        if (request.requestType == Position.RequestType.CREATE_POSITION) {
            _createNewPosition(
                tradeStorage,
                market,
                referralStorage,
                Position.Settlement(request, _orderKey, _feeReceiver, false),
                state
            );
        } else if (request.requestType == Position.RequestType.POSITION_INCREASE) {
            _increasePosition(
                tradeStorage,
                market,
                referralStorage,
                Position.Settlement(request, _orderKey, _feeReceiver, false),
                state
            );
        } else if (
            request.requestType == Position.RequestType.POSITION_DECREASE
                || request.requestType == Position.RequestType.TAKE_PROFIT
                || request.requestType == Position.RequestType.STOP_LOSS
        ) {
            _decreasePosition(
                tradeStorage,
                market,
                referralStorage,
                Position.Settlement(request, _orderKey, _feeReceiver, false),
                state
            );
        } else if (request.requestType == Position.RequestType.COLLATERAL_DECREASE) {
            _executeCollateralDecrease(
                tradeStorage,
                market,
                referralStorage,
                Position.Settlement(request, _orderKey, _feeReceiver, false),
                state
            );
        } else if (request.requestType == Position.RequestType.COLLATERAL_INCREASE) {
            _executeCollateralIncrease(
                tradeStorage,
                market,
                referralStorage,
                Position.Settlement(request, _orderKey, _feeReceiver, false),
                state
            );
        } else {
            revert TradeLogic_InvalidRequestType();
        }

        // Clear the Signed Prices
        priceFeed.clearSignedPrices(market, request.requestId);

        // Fetch the State of the Market After the Position
        IMarket.MarketStorage memory updatedStorage = market.getStorage(request.input.ticker);

        // Invariant Check
        Position.validateMarketDelta(initialStorage, updatedStorage, request);
    }

    // @audit - needs more constraints before we can make permissionless
    // - only allow adl on profitable positions above a threshold
    // - only allow reduction of the pnl factor by so much
    // - how do we make sure that users can only ADL the most profitable positions?
    function executeAdl(
        IMarket market,
        IReferralStorage referralStorage,
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
        _updateMarketState(
            market,
            state,
            params.request.input.ticker,
            params.request.input.sizeDelta,
            params.request.input.isLong,
            params.request.input.isIncrease
        );

        // Execute the order
        _decreasePosition(tradeStorage, market, referralStorage, params, state);

        // Clear signed prices
        priceFeed.clearSignedPrices(market, _requestId);

        // Validate the Adl
        Execution.validateAdl(market, state, startingPnlFactor, params.request.input.ticker, position.isLong);

        emit AdlExecuted(address(market), _positionKey, params.request.input.sizeDelta, position.isLong);
    }

    function liquidatePosition(
        IMarket market,
        IReferralStorage referralStorage,
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
        _updateMarketState(market, state, position.ticker, position.positionSize, position.isLong, false);
        // Construct Liquidation Order
        Position.Settlement memory params = Position.constructLiquidationOrder(position, _liquidator, _requestId);
        // Execute the Liquidation
        _decreasePosition(tradeStorage, market, referralStorage, params, state);
        // Clear Signed Prices
        // Need request id
        priceFeed.clearSignedPrices(market, _requestId);
        // Fire Event
        emit LiquidatePosition(_positionKey, _liquidator, position.collateralAmount, position.isLong);
    }

    /**
     * ========================= private Functions =========================
     */
    function _executeCollateralIncrease(
        ITradeStorage tradeStorage,
        IMarket market,
        IReferralStorage referralStorage,
        Position.Settlement memory _params,
        Execution.State memory _state
    ) private {
        // Get the Position Key
        bytes32 positionKey = Position.generateKey(_params.request);
        // Perform Execution in Library
        Position.Data memory position;
        (position, _state) = Execution.increaseCollateral(market, tradeStorage, _params, _state, positionKey);
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
            market.updatePoolBalance(absFundingFee, position.isLong, true);
        } else if (_state.fundingFee > 0) {
            // User got Paid Funding
            uint256 absFundingFee = _state.fundingFee.abs();
            market.updatePoolBalance(absFundingFee, position.isLong, false);
        }
        // Pay Fees
        _payFees(
            market,
            referralStorage,
            _state.borrowFee,
            _state.positionFee,
            _state.affiliateRebate,
            _state.referrer,
            _params.request.input.isLong
        );
        // Update Final Storage
        tradeStorage.updatePosition(position, positionKey);
        emit CollateralEdited(positionKey, _params.request.input.collateralDelta, _params.request.input.isIncrease);
    }

    function _executeCollateralDecrease(
        ITradeStorage tradeStorage,
        IMarket market,
        IReferralStorage referralStorage,
        Position.Settlement memory _params,
        Execution.State memory _state
    ) private {
        // Get the Position Key
        bytes32 positionKey = Position.generateKey(_params.request);
        // Perform Execution in Library
        Position.Data memory position;
        uint256 amountOut;
        (position, _state, amountOut) = Execution.decreaseCollateral(
            market, tradeStorage, _params, _state, tradeStorage.minCollateralUsd(), positionKey
        );
        if (_state.fundingFee < 0) {
            // User Paid Funding
            market.updatePoolBalance(_state.fundingFee.abs(), position.isLong, true);
        } else if (_state.fundingFee > 0) {
            // User got Paid Funding
            market.updatePoolBalance(_state.fundingFee.abs(), position.isLong, false);
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
        _payFees(
            market,
            referralStorage,
            _state.borrowFee,
            _state.positionFee,
            _state.affiliateRebate,
            _state.referrer,
            _params.request.input.isLong
        );
        // Update Final Storage
        tradeStorage.updatePosition(position, positionKey);
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
        IReferralStorage referralStorage,
        Position.Settlement memory _params,
        Execution.State memory _state
    ) private {
        // Get the Position Key
        bytes32 positionKey = Position.generateKey(_params.request);
        // Perform Execution in the Library
        Position.Data memory position;
        (position, _state) = Execution.createNewPosition(
            market, tradeStorage, _params, _state, tradeStorage.minCollateralUsd(), positionKey
        );
        // Create Conditional Orders
        position = _createConditionalOrders(
            tradeStorage, position, _params.request.conditionals, _params.request.input.executionFee
        );
        // Pay fees
        _payFees(
            market,
            referralStorage,
            0,
            _state.positionFee,
            _state.affiliateRebate,
            _state.referrer,
            _params.request.input.isLong
        );
        // Reserve Liquidity Equal to the Position Size
        _reserveLiquidity(
            market,
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

    function _createConditionalOrders(
        ITradeStorage tradeStorage,
        Position.Data memory position,
        Position.Conditionals memory _conditionals,
        uint256 _executionFee
    ) private returns (Position.Data memory) {
        if (!_conditionals.stopLossSet && !_conditionals.takeProfitSet) return position;
        // If Request has conditionals, create the SL / TP
        (Position.Request memory stopLoss, Position.Request memory takeProfit) =
            Position.constructConditionalOrders(position, _conditionals, _executionFee);
        // If stop loss set, create and store the order
        if (_conditionals.stopLossSet) position.stopLossKey = tradeStorage.createOrder(stopLoss);
        // If take profit set, create and store the order
        if (_conditionals.takeProfitSet) {
            position.takeProfitKey = tradeStorage.createOrder(takeProfit);
        }
        return position;
    }

    function _increasePosition(
        ITradeStorage tradeStorage,
        IMarket market,
        IReferralStorage referralStorage,
        Position.Settlement memory _params,
        Execution.State memory _state
    ) private {
        // Get the Position Key
        bytes32 positionKey = Position.generateKey(_params.request);
        // Perform Execution in the Library
        Position.Data memory position;
        (position, _state) = Execution.increasePosition(market, tradeStorage, _params, _state, positionKey);
        // Pay Fees
        _payFees(
            market,
            referralStorage,
            _state.borrowFee,
            _state.positionFee,
            _state.affiliateRebate,
            _state.referrer,
            _params.request.input.isLong
        );
        // Reserve Liquidity Equal to the Position Size
        _reserveLiquidity(
            market,
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
        IReferralStorage referralStorage,
        Position.Settlement memory _params,
        Execution.State memory _state
    ) private {
        // Get the Position Key
        bytes32 positionKey = Position.generateKey(_params.request);
        // Perform Execution in the Library
        Position.Data memory position;
        Execution.DecreaseState memory decreaseState;
        (position, decreaseState, _state) = Execution.decreasePosition(
            market,
            tradeStorage,
            _params,
            _state,
            tradeStorage.minCollateralUsd(),
            tradeStorage.liquidationFee(),
            positionKey
        );

        // Unreserve Liquidity for the position
        _unreserveLiquidity(
            market,
            _params.request.input.sizeDelta,
            _params.request.input.collateralDelta,
            _state.collateralPrice,
            _state.collateralBaseUnit,
            position.user,
            _params.request.input.isLong
        );

        /**
         * To handle insolvency case for liquidations, we do the following:
         * - Pay fees in order of important, each time checking if the remaining amount is sufficient.
         * - Once the remaining amount is used up, stop paying fees.
         * - If any is remaining after paying all fees, add to pool.
         */
        // @audit - are we ignoring fee for executor?
        if (decreaseState.isLiquidation) {
            // Liquidate the Position
            _handleLiquidation(
                tradeStorage,
                market,
                position,
                _state,
                decreaseState,
                positionKey,
                _params.request.user,
                _params.request.input.reverseWrap
            );
        } else {
            // Decrease the Position
            _handlePositionDecrease(
                tradeStorage,
                market,
                referralStorage,
                position,
                _state,
                decreaseState,
                positionKey,
                _params.feeReceiver,
                _params.request.input.reverseWrap
            );
        }

        // Fire Event
        emit DecreasePosition(positionKey, _params.request.input.collateralDelta, _params.request.input.sizeDelta);
    }

    function _handleLiquidation(
        ITradeStorage tradeStorage,
        IMarket market,
        Position.Data memory _position,
        Execution.State memory _state,
        Execution.DecreaseState memory _decreaseState,
        bytes32 _positionKey,
        address _liquidator,
        bool _reverseWrap
    ) private {
        // Delete the position from storage
        tradeStorage.deletePosition(_positionKey, _position.isLong);
        // Start Tracking Remaining Collateral for Payours
        uint256 remainingCollateral = _position.collateralAmount;
        // Pay the liquidator
        remainingCollateral -= _decreaseState.liqFee;
        market.transferOutTokens(
            _liquidator, // Liquidator
            _decreaseState.liqFee,
            _position.isLong,
            true // Unwrap by default
        );
        // Pay the Borrowing Fee
        if (_state.borrowFee > remainingCollateral) _state.borrowFee = remainingCollateral;
        remainingCollateral -= _state.borrowFee;
        market.accumulateFees(_state.borrowFee, _position.isLong);
        // Pay the Position Fee if any remaining collateral -> Fee For Executor is ignored in Liquidation
        if (_state.positionFee > remainingCollateral) _state.positionFee = remainingCollateral;
        remainingCollateral -= _state.positionFee;
        market.accumulateFees(_state.positionFee, _position.isLong);
        // Pay the Affiliate Rebate
        if (_state.affiliateRebate > remainingCollateral) _state.affiliateRebate = remainingCollateral;
        remainingCollateral -= _state.affiliateRebate;
        market.transferOutTokens(
            _state.referrer,
            _state.affiliateRebate,
            _position.isLong,
            false // Leave unwrapped by default
        );
        // Pay the Liquidated User if owed anything
        if (_decreaseState.feesOwedToUser > 0) {
            // Decrease the pool amount by the amount being payed out to the user
            market.updatePoolBalance(_decreaseState.feesOwedToUser, _position.isLong, false);
            // Transfer the User's Tokens
            market.transferOutTokens(_position.user, _decreaseState.feesOwedToUser, _position.isLong, _reverseWrap);
        }
        // Accumulate the remaining collateral into the pool
        market.updatePoolBalance(remainingCollateral, _position.isLong, true);
    }

    function _handlePositionDecrease(
        ITradeStorage tradeStorage,
        IMarket market,
        IReferralStorage referralStorage,
        Position.Data memory _position,
        Execution.State memory _state,
        Execution.DecreaseState memory _decreaseState,
        bytes32 _positionKey,
        address _executor,
        bool _reverseWrap
    ) private {
        // Pay Fees
        _payFees(
            market,
            referralStorage,
            _state.borrowFee,
            _state.positionFee,
            _state.affiliateRebate,
            _state.referrer,
            _position.isLong
        );
        // Set Amount Out
        uint256 amountOut = _decreaseState.decreasePnl > 0
            ? _decreaseState.afterFeeAmount + _decreaseState.decreasePnl.abs() // Profit Case
            : _decreaseState.afterFeeAmount; // Loss / Break Even Case -> Losses already deducted in Execution if any
        // Pay any positive funding accrued. Negative Funding Deducted in Execution
        amountOut += _state.fundingFee > 0 ? _state.fundingFee.abs() : 0;
        // If profit being payed out, need to decrease the pool amount by the profit
        if (amountOut > _decreaseState.afterFeeAmount) {
            market.updatePoolBalance(amountOut - _decreaseState.afterFeeAmount, _position.isLong, false);
        }
        // Delete the Position if Full Decrease
        if (_position.positionSize == 0 || _position.collateralAmount == 0) {
            tradeStorage.deletePosition(_positionKey, _position.isLong);
        } else {
            // Update Final Storage
            tradeStorage.updatePosition(_position, _positionKey);
        }
        // Check Market has enough available liquidity for payout (@audit - only check if profitable)
        if (market.totalAvailableLiquidity(_position.isLong) < amountOut + _state.affiliateRebate) {
            revert TradeLogic_InsufficientFreeLiquidity();
        }

        // Transfer the Fee to the Executor
        if (_state.feeForExecutor > 0) {
            market.transferOutTokens(_executor, _state.feeForExecutor, _position.isLong, true);
        }

        // Transfer Rebate to Referrer
        if (_state.affiliateRebate > 0) {
            market.transferOutTokens(
                _state.referrer,
                _state.affiliateRebate,
                _position.isLong,
                false // Leave unwrapped by default
            );
        }
        // Transfer Tokens to User
        if (amountOut > 0) {
            market.transferOutTokens(_position.user, amountOut, _position.isLong, _reverseWrap);
        }
    }

    function _updateMarketState(
        IMarket market,
        Execution.State memory _state,
        string memory _ticker,
        uint256 _sizeDelta,
        bool _isLong,
        bool _isIncrease
    ) private {
        // Update the Market State
        market.updateMarketState(
            _ticker,
            _sizeDelta,
            _state.indexPrice,
            _state.impactedPrice,
            _state.collateralPrice,
            _state.indexBaseUnit,
            _isLong,
            _isIncrease
        );
        // If Price Impact is Negative, add to the impact Pool
        // If Price Impact is Positive, Subtract from the Impact Pool
        // Impact Pool Delta = -1 * Price Impact
        if (_state.priceImpactUsd == 0) return;
        market.updateImpactPool(_ticker, -_state.priceImpactUsd);
    }

    function _reserveLiquidity(
        IMarket market,
        uint256 _sizeDeltaUsd,
        uint256 _collateralDelta,
        uint256 _collateralPrice,
        uint256 _collateralBaseUnit,
        address _user,
        bool _isLong
    ) private {
        // Convert Size Delta USD to Collateral Tokens
        uint256 reserveDelta = mulDiv(_sizeDeltaUsd, _collateralBaseUnit, _collateralPrice);
        // Reserve an Amount of Liquidity Equal to the Position Size
        market.updateLiquidityReservation(reserveDelta, _isLong, true);
        // Register the Collateral in
        market.updateCollateralAmount(_collateralDelta, _user, _isLong, true);
    }

    function _unreserveLiquidity(
        IMarket market,
        uint256 _sizeDeltaUsd,
        uint256 _collateralDelta,
        uint256 _collateralPrice,
        uint256 _collateralBaseUnit,
        address _user,
        bool _isLong
    ) private {
        // Convert Size Delta USD to Collateral Tokens
        uint256 reserveDelta = (mulDiv(_sizeDeltaUsd, _collateralBaseUnit, _collateralPrice)); // Could use collateral delta * leverage for gas savings?
        // Unreserve an Amount of Liquidity Equal to the Position Size
        market.updateLiquidityReservation(reserveDelta, _isLong, false);
        // Register the Collateral out
        market.updateCollateralAmount(_collateralDelta, _user, _isLong, false);
    }

    function _payFees(
        IMarket market,
        IReferralStorage referralStorage,
        uint256 _borrowAmount,
        uint256 _positionFee,
        uint256 _affiliateRebate,
        address _referrer,
        bool _isLong
    ) private {
        // Pay Fees to LPs for Side (Position + Borrow)
        market.accumulateFees(_borrowAmount + _positionFee, _isLong);
        // Pay Affiliate Rebate to Referrer
        if (_affiliateRebate > 0) {
            referralStorage.accumulateAffiliateRewards(address(market), _referrer, _isLong, _affiliateRebate);
        }
    }

    function _attachConditionalOrder(ITradeStorage tradeStorage, Position.Request calldata _request, bytes32 _orderKey)
        private
    {
        bytes32 positionKey = Position.generateKey(_request);
        Position.Data memory position = tradeStorage.getPosition(positionKey);
        if (_request.requestType == Position.RequestType.STOP_LOSS) {
            if (position.stopLossKey != bytes32(0)) revert TradeLogic_StopLossAlreadySet();
            if (position.user == address(0)) revert TradeLogic_PositionDoesNotExist();
            position.stopLossKey = _orderKey;
            tradeStorage.updatePosition(position, positionKey);
        } else if (_request.requestType == Position.RequestType.TAKE_PROFIT) {
            if (position.takeProfitKey != bytes32(0)) revert TradeLogic_TakeProfitAlreadySet();
            if (position.user == address(0)) revert TradeLogic_PositionDoesNotExist();
            position.takeProfitKey = _orderKey;
            tradeStorage.updatePosition(position, positionKey);
        }
    }
}
