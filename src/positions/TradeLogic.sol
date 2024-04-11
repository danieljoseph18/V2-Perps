// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Execution} from "./Execution.sol";
import {Position} from "./Position.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {IPriceFeed} from "../oracle/interfaces/IPriceFeed.sol";
import {IReferralStorage} from "../referrals/interfaces/IReferralStorage.sol";
import {ITradeStorage} from "./interfaces/ITradeStorage.sol";
import {IPositionManager} from "../router/interfaces/IPositionManager.sol";
import {MarketUtils} from "../markets/MarketUtils.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {MathUtils} from "../libraries/MathUtils.sol";
import {console2} from "forge-std/Test.sol";

library TradeLogic {
    using SignedMath for int256;
    using MathUtils for uint256;

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
    error TradeLogic_InvalidPosition();

    event CollateralEdited(bytes32 indexed _positionKey, uint256 indexed _collateralDelta, bool indexed _isIncrease);
    event PositionCreated(bytes32 indexed _positionKey);
    event IncreasePosition(bytes32 indexed _positionKey, uint256 indexed _collateralDelta, uint256 indexed _sizeDelta);
    event DecreasePosition(bytes32 indexed _positionKey, uint256 indexed _collateralDelta, uint256 indexed _sizeDelta);
    event AdlExecuted(address _market, bytes32 _positionKey, uint256 _sizeDelta, bool _isLong);
    event LiquidatePosition(bytes32 indexed _positionKey, address indexed _liquidator, bool _isLong);

    uint256 private constant MAX_LIQUIDATION_FEE = 0.1e18; // 10%
    uint256 private constant MIN_LIQUIDATION_FEE = 0.001e18; // 1%
    uint256 private constant MAX_TRADING_FEE = 0.01e18; // 1%
    uint256 private constant MIN_TRADING_FEE = 0.00001e18; // 0.001%
    uint256 private constant MAX_ADL_FEE = 0.05e18; // 5%
    uint256 private constant MIN_ADL_FEE = 0.0001e18; // 0.01%
    uint256 private constant MAX_FEE_FOR_EXECUTION = 0.3e18; // 30%
    uint256 private constant MIN_FEE_FOR_EXECUTION = 0.05e18; // 5%

    struct Invariants {
        IMarket.MarketStorage initialStorage;
        IMarket.MarketStorage updatedStorage;
        IMarket.State initialState;
        IMarket.State updatedState;
        uint256 storedCollateral;
    }

    /**
     * ========================= Validation Functions =========================
     */
    function validateFees(uint256 _liquidationFee, uint256 _positionFee, uint256 _adlFee, uint256 _feeForExecution)
        internal
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

    /**
     * ========================= Core Execution Functions =========================
     */

    /// @notice Creates a new Order Request
    function createOrderRequest(Position.Request calldata _request) internal {
        ITradeStorage tradeStorage = ITradeStorage(address(this));
        // Create the order
        bytes32 orderKey = tradeStorage.createOrder(_request);
        // If SL / TP, tie to the position
        _attachConditionalOrder(tradeStorage, _request, orderKey);
    }

    /// @notice Executes a Request for a Position
    /// Called by keepers --> Routes the execution down the correct path.
    function executePositionRequest(
        IMarket market,
        IPriceFeed priceFeed,
        IPositionManager positionManager,
        IReferralStorage referralStorage,
        bytes32 _orderKey,
        bytes32 _requestId,
        address _feeReceiver
    ) internal returns (Execution.FeeState memory feeState, Position.Request memory request) {
        ITradeStorage tradeStorage = ITradeStorage(address(this));
        // Initiate the execution
        Execution.Prices memory prices;
        (prices, request) = Execution.initiate(tradeStorage, market, priceFeed, _orderKey, _requestId, _feeReceiver);
        // Cache the State of the Market Before the Position
        Invariants memory invariants = _getInvariants(market, request.input.ticker, request.user, request.input.isLong);
        // Delete the Order from Storage
        tradeStorage.deleteOrder(_orderKey, request.input.isLimit);
        // Update the Market State for the Request
        _updateMarketState(
            market,
            prices,
            request.input.ticker,
            request.input.sizeDelta,
            request.input.isLong,
            request.input.isIncrease
        );
        // Execute Trade
        if (request.requestType == Position.RequestType.CREATE_POSITION) {
            feeState = _createNewPosition(
                tradeStorage,
                market,
                positionManager,
                referralStorage,
                Position.Settlement(request, _orderKey, _feeReceiver, false),
                prices
            );
        } else if (request.requestType == Position.RequestType.POSITION_INCREASE) {
            feeState = _increasePosition(
                tradeStorage,
                market,
                positionManager,
                referralStorage,
                Position.Settlement(request, _orderKey, _feeReceiver, false),
                prices
            );
        } else if (
            request.requestType == Position.RequestType.POSITION_DECREASE
                || request.requestType == Position.RequestType.TAKE_PROFIT
                || request.requestType == Position.RequestType.STOP_LOSS
        ) {
            feeState = _decreasePosition(
                tradeStorage,
                market,
                referralStorage,
                Position.Settlement(request, _orderKey, _feeReceiver, false),
                prices,
                tradeStorage.minCollateralUsd(),
                tradeStorage.liquidationFee()
            );
        } else if (request.requestType == Position.RequestType.COLLATERAL_DECREASE) {
            feeState = _decreaseCollateral(
                tradeStorage,
                market,
                referralStorage,
                Position.Settlement(request, _orderKey, _feeReceiver, false),
                prices
            );
        } else if (request.requestType == Position.RequestType.COLLATERAL_INCREASE) {
            feeState = _increaseCollateral(
                tradeStorage,
                market,
                positionManager,
                referralStorage,
                Position.Settlement(request, _orderKey, _feeReceiver, false),
                prices
            );
        } else {
            revert TradeLogic_InvalidRequestType();
        }

        // Clear the Signed Prices
        priceFeed.clearSignedPrices(market, request.requestId);

        // Cache the State of the Market After the Position
        invariants.updatedStorage = market.getStorage(request.input.ticker);
        invariants.updatedState = market.getState(request.input.isLong);

        // Invariant Checks
        Position.validateMarketDelta(invariants.initialStorage, invariants.updatedStorage, request);
        Position.validatePoolDelta(
            feeState,
            invariants.initialState,
            invariants.updatedState,
            request.input.collateralDelta,
            invariants.storedCollateral,
            request.input.isIncrease,
            feeState.isFullDecrease
        );
    }

    function executeAdl(
        IMarket market,
        IReferralStorage referralStorage,
        IPriceFeed priceFeed,
        bytes32 _positionKey,
        bytes32 _requestId,
        address _feeReceiver
    ) internal {
        ITradeStorage tradeStorage = ITradeStorage(address(this));
        // Initiate the Adl order
        // @audit - fee for executor isn't stored anywhere -> should be maintained for the decrease
        (Execution.Prices memory prices, Position.Settlement memory params, int256 startingPnlFactor) =
            Execution.initiateAdlOrder(market, tradeStorage, priceFeed, _positionKey, _requestId, _feeReceiver);

        console2.log("Adl Size Delta: ", params.request.input.sizeDelta);
        console2.log("Market: ", address(market));
        console2.log("Ticker: ", params.request.input.ticker);
        console2.log("Size Delta: ", params.request.input.sizeDelta);

        // Update the Market State
        _updateMarketState(
            market,
            prices,
            params.request.input.ticker,
            params.request.input.sizeDelta,
            params.request.input.isLong,
            false
        );

        // Execute the order
        _decreasePosition(
            tradeStorage,
            market,
            referralStorage,
            params,
            prices,
            tradeStorage.minCollateralUsd(),
            tradeStorage.liquidationFee()
        );

        // Clear signed prices
        priceFeed.clearSignedPrices(market, _requestId);

        // Validate the Adl
        Execution.validateAdl(
            market, prices, startingPnlFactor, params.request.input.ticker, params.request.input.isLong
        );

        emit AdlExecuted(address(market), _positionKey, params.request.input.sizeDelta, params.request.input.isLong);
    }

    // @audit - need to make it so liquidations happen slightly before losses > collateral
    // otherwise we'll be left paying for insolvent liqs every time.
    function liquidatePosition(
        IMarket market,
        IReferralStorage referralStorage,
        IPriceFeed priceFeed,
        bytes32 _positionKey,
        bytes32 _requestId,
        address _liquidator
    ) internal {
        ITradeStorage tradeStorage = ITradeStorage(address(this));
        // Fetch the Position
        Position.Data memory position = tradeStorage.getPosition(_positionKey);
        // Check the Position Exists
        if (position.user == address(0)) revert TradeLogic_PositionDoesNotExist();
        // Get the Prices
        Execution.Prices memory prices =
            Execution.getTokenPrices(priceFeed, position.ticker, _requestId, position.isLong, false);
        // No price impact on Liquidations
        prices.impactedPrice = prices.indexPrice;
        // Update the Market State
        _updateMarketState(market, prices, position.ticker, position.size, position.isLong, false);
        // Construct Liquidation Order
        Position.Settlement memory params = Position.createLiquidationOrder(
            position, prices.collateralPrice, prices.collateralBaseUnit, _liquidator, _requestId
        );

        // Execute the Liquidation
        _decreasePosition(
            tradeStorage,
            market,
            referralStorage,
            params,
            prices,
            tradeStorage.minCollateralUsd(),
            tradeStorage.liquidationFee()
        );
        // Clear Signed Prices
        // Need request id
        priceFeed.clearSignedPrices(market, _requestId);
        // Fire Event
        emit LiquidatePosition(_positionKey, _liquidator, position.isLong);
    }

    /**
     * ========================= Core Function Implementations =========================
     */
    function _increaseCollateral(
        ITradeStorage tradeStorage,
        IMarket market,
        IPositionManager positionManager,
        IReferralStorage referralStorage,
        Position.Settlement memory _params,
        Execution.Prices memory _prices
    ) private returns (Execution.FeeState memory feeState) {
        // Get the Position Key
        bytes32 positionKey = Position.generateKey(_params.request);
        // Perform Execution in Library
        Position.Data memory position;
        (position, feeState) =
            Execution.increaseCollateral(market, tradeStorage, referralStorage, _params, _prices, positionKey);
        // Add Value to Stored Collateral Amount in Market
        market.updateCollateralAmount(
            feeState.afterFeeAmount, _params.request.user, _params.request.input.isLong, true, false
        );
        // Account for Fees in Storage
        _accumulateFees(market, referralStorage, feeState, position.isLong);
        // Update Final Storage
        tradeStorage.updatePosition(position, positionKey);
        // Handle Token Transfers
        positionManager.transferTokensForIncrease(
            market,
            _params.request.input.collateralToken,
            _params.request.input.collateralDelta,
            feeState.affiliateRebate,
            feeState.feeForExecutor
        );
        emit CollateralEdited(positionKey, _params.request.input.collateralDelta, _params.request.input.isIncrease);
    }

    function _decreaseCollateral(
        ITradeStorage tradeStorage,
        IMarket market,
        IReferralStorage referralStorage,
        Position.Settlement memory _params,
        Execution.Prices memory _prices
    ) private returns (Execution.FeeState memory feeState) {
        // Get the Position Key
        bytes32 positionKey = Position.generateKey(_params.request);
        // Perform Execution in Library
        Position.Data memory position;
        (position, feeState) = Execution.decreaseCollateral(
            market, tradeStorage, referralStorage, _params, _prices, tradeStorage.minCollateralUsd(), positionKey
        );

        // Decrease the Collateral Amount in the Market by the full delta
        market.updateCollateralAmount(
            _params.request.input.collateralDelta, _params.request.user, _params.request.input.isLong, false, false
        );
        // Account for Fees in Storage
        _accumulateFees(market, referralStorage, feeState, position.isLong);
        // Update Final Storage
        tradeStorage.updatePosition(position, positionKey);

        // Handle Token Transfers
        _transferTokensForDecrease(
            market,
            feeState,
            feeState.afterFeeAmount,
            _params.feeReceiver,
            _params.request.user,
            _params.request.input.isLong,
            _params.request.input.reverseWrap
        );

        // Fire Event
        emit CollateralEdited(positionKey, _params.request.input.collateralDelta, _params.request.input.isIncrease);
    }

    function _createNewPosition(
        ITradeStorage tradeStorage,
        IMarket market,
        IPositionManager positionManager,
        IReferralStorage referralStorage,
        Position.Settlement memory _params,
        Execution.Prices memory _prices
    ) private returns (Execution.FeeState memory feeState) {
        // Get the Position Key
        bytes32 positionKey = Position.generateKey(_params.request);
        // Perform Execution in the Library
        Position.Data memory position;
        (position, feeState) = Execution.createNewPosition(
            market, tradeStorage, referralStorage, _params, _prices, tradeStorage.minCollateralUsd(), positionKey
        );
        // Create Conditional Orders
        position = _createConditionalOrders(
            tradeStorage, position, _params.request.conditionals, _prices, _params.request.input.executionFee
        );
        // Account for Fees in Storage
        _accumulateFees(market, referralStorage, feeState, position.isLong);
        // Reserve Liquidity Equal to the Position Size
        _updateLiquidity(
            market,
            _params.request.input.sizeDelta,
            feeState.afterFeeAmount,
            _prices.collateralPrice,
            _prices.collateralBaseUnit,
            position.user,
            _params.request.input.isLong,
            true,
            false
        );
        // Update Final Storage
        tradeStorage.createPosition(position, positionKey);
        // Handle Token Transfers
        positionManager.transferTokensForIncrease(
            market,
            _params.request.input.collateralToken,
            _params.request.input.collateralDelta,
            feeState.affiliateRebate,
            feeState.feeForExecutor
        );
        // Fire Event
        emit PositionCreated(positionKey);
    }

    function _increasePosition(
        ITradeStorage tradeStorage,
        IMarket market,
        IPositionManager positionManager,
        IReferralStorage referralStorage,
        Position.Settlement memory _params,
        Execution.Prices memory _prices
    ) private returns (Execution.FeeState memory feeState) {
        // Get the Position Key
        bytes32 positionKey = Position.generateKey(_params.request);
        // Perform Execution in the Library
        Position.Data memory position;
        (feeState, position) =
            Execution.increasePosition(market, tradeStorage, referralStorage, _params, _prices, positionKey);

        // Account for Fees in Storage
        _accumulateFees(market, referralStorage, feeState, position.isLong);
        // Reserve Liquidity Equal to the Position Size
        _updateLiquidity(
            market,
            _params.request.input.sizeDelta,
            feeState.afterFeeAmount,
            _prices.collateralPrice,
            _prices.collateralBaseUnit,
            position.user,
            _params.request.input.isLong,
            true,
            false
        );
        // Update Final Storage
        tradeStorage.updatePosition(position, positionKey);
        // Handle Token Transfers
        positionManager.transferTokensForIncrease(
            market,
            _params.request.input.collateralToken,
            _params.request.input.collateralDelta,
            feeState.affiliateRebate,
            feeState.feeForExecutor
        );
        // Fire event
        emit IncreasePosition(positionKey, _params.request.input.collateralDelta, _params.request.input.sizeDelta);
    }

    function _decreasePosition(
        ITradeStorage tradeStorage,
        IMarket market,
        IReferralStorage referralStorage,
        Position.Settlement memory _params,
        Execution.Prices memory _prices,
        uint256 _minCollateralUsd,
        uint256 _liquidationFee
    ) private returns (Execution.FeeState memory feeState) {
        // Get the Position Key
        bytes32 positionKey = Position.generateKey(_params.request);
        // Perform Execution in the Library
        Position.Data memory position;
        (position, feeState) = Execution.decreasePosition(
            market, tradeStorage, referralStorage, _params, _prices, _minCollateralUsd, _liquidationFee, positionKey
        );

        // Unreserve Liquidity for the position
        _updateLiquidity(
            market,
            _params.request.input.sizeDelta,
            _params.request.input.collateralDelta,
            _prices.collateralPrice,
            _prices.collateralBaseUnit,
            position.user,
            _params.request.input.isLong,
            false,
            feeState.isFullDecrease
        );

        if (feeState.isLiquidation) {
            // Liquidate the Position
            feeState = _handleLiquidation(
                market, referralStorage, position, feeState, _prices, positionKey, _params.request.user
            );
        } else {
            // Decrease the Position
            _handlePositionDecrease(
                market,
                referralStorage,
                position,
                feeState,
                positionKey,
                _params.feeReceiver,
                _params.request.input.reverseWrap
            );
        }

        // Fire Event
        emit DecreasePosition(positionKey, _params.request.input.collateralDelta, _params.request.input.sizeDelta);
    }

    /**
     * To handle insolvency case for liquidations, we do the following:
     * - Pay fees in order of importance, each time checking if the remaining amount is sufficient.
     * - Once the remaining amount is used up, stop paying fees.
     * - If any is remaining after paying all fees, add to pool.
     */
    function _handleLiquidation(
        IMarket market,
        IReferralStorage referralStorage,
        Position.Data memory _position,
        Execution.FeeState memory _feeState,
        Execution.Prices memory _prices,
        bytes32 _positionKey,
        address _liquidator
    ) private returns (Execution.FeeState memory) {
        // Re-cache trade storage to avoid STD Err
        ITradeStorage tradeStorage = ITradeStorage(address(this));
        // Delete the position from storage
        tradeStorage.deletePosition(_positionKey, _position.isLong);

        // Adjust Fees to handle insolvent liquidation case
        _feeState = _adjustFeesForInsolvency(
            _feeState, _position.collateral.fromUsd(_prices.collateralPrice, _prices.collateralBaseUnit)
        );

        // Account for Fees in Storage
        _accumulateFees(market, referralStorage, _feeState, _position.isLong);

        // Update the Pool Balance for any Remaining Collateral
        market.updatePoolBalance(_feeState.afterFeeAmount, _position.isLong, true);

        // Pay the Liquidated User if owed anything
        if (_feeState.amountOwedToUser > 0) {
            // Decrease the pool amount by the amount being payed out to the user
            market.updatePoolBalance(_feeState.amountOwedToUser, _position.isLong, false);
        }

        _transferTokensForDecrease(
            market,
            _feeState,
            _feeState.amountOwedToUser,
            _liquidator,
            _position.user,
            _position.isLong,
            false // Leave unwrapped by default
        );

        return _feeState;
    }

    function _handlePositionDecrease(
        IMarket market,
        IReferralStorage referralStorage,
        Position.Data memory _position,
        Execution.FeeState memory _feeState,
        bytes32 _positionKey,
        address _executor,
        bool _reverseWrap
    ) private {
        // Re-cache trade storage to avoid STD Err
        ITradeStorage tradeStorage = ITradeStorage(address(this));
        // Account for Fees in Storage
        _accumulateFees(market, referralStorage, _feeState, _position.isLong);

        // Update Pool for Profit / Loss -> Loss = Decrease Pool, Profit = Increase Pool
        console2.log("Trader Pnl: ", _feeState.realizedPnl);

        market.updatePoolBalance(_feeState.realizedPnl.abs(), _position.isLong, _feeState.realizedPnl < 0);

        // Delete the Position if Full Decrease
        if (_position.size == 0 || _position.collateral == 0) {
            tradeStorage.deletePosition(_positionKey, _position.isLong);
        } else {
            // Update Final Storage if Partial Decrease
            tradeStorage.updatePosition(_position, _positionKey);
        }

        // Check Market has enough available liquidity for all transfers out.
        // In cases where the market is insolvent, there may not be enough in the pool to pay out a profitable position.
        MarketUtils.hasSufficientLiquidity(
            market, _feeState.afterFeeAmount + _feeState.affiliateRebate + _feeState.feeForExecutor, _position.isLong
        );

        // Handle Token Transfers
        _transferTokensForDecrease(
            market, _feeState, _feeState.afterFeeAmount, _executor, _position.user, _position.isLong, _reverseWrap
        );
    }

    /**
     * ========================= Private Helper Functions =========================
     */

    /// @dev - Can fail on insolvency.
    function _transferTokensForDecrease(
        IMarket market,
        Execution.FeeState memory _feeState,
        uint256 _amountOut,
        address _executor,
        address _user,
        bool _isLong,
        bool _reverseWrap
    ) private {
        // Transfer the Fee to the Executor
        if (_feeState.feeForExecutor > 0) {
            market.transferOutTokens(_executor, _feeState.feeForExecutor, _isLong, true);
        }
        // Transfer Rebate to Referrer
        if (_feeState.affiliateRebate > 0) {
            market.transferOutTokens(
                _feeState.referrer,
                _feeState.affiliateRebate,
                _isLong,
                false // Leave unwrapped by default
            );
        }
        // Transfer Tokens to User
        if (_amountOut > 0) {
            market.transferOutTokens(_user, _amountOut, _isLong, _reverseWrap);
        }
    }

    function _updateMarketState(
        IMarket market,
        Execution.Prices memory _prices,
        string memory _ticker,
        uint256 _sizeDelta,
        bool _isLong,
        bool _isIncrease
    ) private {
        // Update the Market State
        market.updateMarketState(_ticker, _sizeDelta, _prices.indexPrice, _prices.impactedPrice, _isLong, _isIncrease);
        // If Price Impact is Negative, add to the impact Pool
        // If Price Impact is Positive, Subtract from the Impact Pool
        // Impact Pool Delta = -1 * Price Impact
        if (_prices.priceImpactUsd == 0) return;
        market.updateImpactPool(_ticker, -_prices.priceImpactUsd);
    }

    function _updateLiquidity(
        IMarket market,
        uint256 _sizeDeltaUsd,
        uint256 _collateralDelta,
        uint256 _collateralPrice,
        uint256 _collateralBaseUnit,
        address _user,
        bool _isLong,
        bool _isReserve,
        bool _isFullDecrease
    ) private {
        // Units Size Delta USD to Collateral Tokens
        uint256 reserveDelta = _sizeDeltaUsd.fromUsd(_collateralPrice, _collateralBaseUnit);
        // Reserve an Amount of Liquidity Equal to the Position Size
        market.updateLiquidityReservation(reserveDelta, _isLong, _isReserve);
        // Register the Collateral in
        /**
         * Store collateral for the user. Let's us keep track of any collateral as it may
         * fluctuate in price.
         * When the user creates a position, a snapshot is taken of the collateral amount.
         * Excess gained / loss needs to be tracked here, and realized into the pool
         * @audit
         */
        market.updateCollateralAmount(_collateralDelta, _user, _isLong, _isReserve, _isFullDecrease);
    }

    /**
     * For Increase:
     * - Borrow & Position Fee --> LPs
     * - Affiliate Rebate --> Referrer
     * - Fee For Executor --> Executor
     * - Funding Fee --> Pool
     */
    function _accumulateFees(
        IMarket market,
        IReferralStorage referralStorage,
        Execution.FeeState memory _feeState,
        bool _isLong
    ) private {
        // Account for Fees in Storage to LPs for Side (Position + Borrow)
        market.accumulateFees(_feeState.borrowFee + _feeState.positionFee, _isLong);
        // Pay Affiliate Rebate to Referrer
        if (_feeState.affiliateRebate > 0) {
            referralStorage.accumulateAffiliateRewards(
                address(market), _feeState.referrer, _isLong, _feeState.affiliateRebate
            );
        }
        // If user's position has increased with positive funding, need to subtract from the pool
        // If user's position has decreased with negative funding, need to add to the pool
        market.updatePoolBalance(_feeState.fundingFee.abs(), _isLong, _feeState.fundingFee < 0);
    }

    /// @dev - Attaches a Conditional Order to a Position --> Let's us ensure SL / TP orders only affect the position they're assigned to.
    function _attachConditionalOrder(ITradeStorage tradeStorage, Position.Request calldata _request, bytes32 _orderKey)
        private
    {
        bytes32 positionKey = Position.generateKey(_request);
        Position.Data memory position = tradeStorage.getPosition(positionKey);
        // If Request is a SL, tie to the Stop Loss Key for the Position
        if (_request.requestType == Position.RequestType.STOP_LOSS) {
            if (position.stopLossKey != bytes32(0)) revert TradeLogic_StopLossAlreadySet();
            if (position.user == address(0)) revert TradeLogic_PositionDoesNotExist();
            position.stopLossKey = _orderKey;
            tradeStorage.updatePosition(position, positionKey);
        } else if (_request.requestType == Position.RequestType.TAKE_PROFIT) {
            // If Request is a TP, tie to the Take Profit Key for the Position
            if (position.takeProfitKey != bytes32(0)) revert TradeLogic_TakeProfitAlreadySet();
            if (position.user == address(0)) revert TradeLogic_PositionDoesNotExist();
            position.takeProfitKey = _orderKey;
            tradeStorage.updatePosition(position, positionKey);
        }
    }

    function _createConditionalOrders(
        ITradeStorage tradeStorage,
        Position.Data memory position,
        Position.Conditionals memory _conditionals,
        Execution.Prices memory _prices,
        uint256 _executionFee
    ) private returns (Position.Data memory) {
        if (!_conditionals.stopLossSet && !_conditionals.takeProfitSet) return position;
        // If Request has conditionals, create the SL / TP
        (Position.Request memory stopLoss, Position.Request memory takeProfit) =
            Position.createConditionalOrders(position, _conditionals, _prices, _executionFee);
        // If stop loss set, create and store the order
        if (_conditionals.stopLossSet) position.stopLossKey = tradeStorage.createOrder(stopLoss);
        // If take profit set, create and store the order
        if (_conditionals.takeProfitSet) {
            position.takeProfitKey = tradeStorage.createOrder(takeProfit);
        }
        return position;
    }

    // Use remaining collateral as a decreasing incrementer -> pay fees until all used up, adjust fees as necessary
    function _adjustFeesForInsolvency(Execution.FeeState memory _feeState, uint256 _remainingCollateral)
        private
        pure
        returns (Execution.FeeState memory)
    {
        // Subtract Liq Fee --> Liq Fee is a % of the collateral, so can never be >
        // Paid first to always incentivize liquidations.
        _remainingCollateral -= _feeState.feeForExecutor;

        if (_feeState.borrowFee > _remainingCollateral) _feeState.borrowFee = _remainingCollateral;
        _remainingCollateral -= _feeState.borrowFee;

        if (_feeState.positionFee > _remainingCollateral) _feeState.positionFee = _remainingCollateral;
        _remainingCollateral -= _feeState.positionFee;

        if (_feeState.affiliateRebate > _remainingCollateral) _feeState.affiliateRebate = _remainingCollateral;
        _remainingCollateral -= _feeState.affiliateRebate;

        // Set the remaining collateral as the after fee amount
        _feeState.afterFeeAmount = _remainingCollateral;

        return _feeState;
    }

    function _getInvariants(IMarket market, string memory _ticker, address _user, bool _isLong)
        private
        view
        returns (Invariants memory invariants)
    {
        invariants.initialStorage = market.getStorage(_ticker);
        invariants.initialState = market.getState(_isLong);
        invariants.storedCollateral = market.collateralAmounts(_user, _isLong);
    }
}
