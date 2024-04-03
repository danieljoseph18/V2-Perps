// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {ITradeStorage} from "./interfaces/ITradeStorage.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {RoleValidation} from "../access/RoleValidation.sol";
import {Funding} from "../libraries/Funding.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Position} from "../positions/Position.sol";
import {mulDiv} from "@prb/math/Common.sol";
import {Execution} from "./Execution.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {ReentrancyGuard} from "@solmate/utils/ReentrancyGuard.sol";
import {IReferralStorage} from "../referrals/interfaces/IReferralStorage.sol";
import {MarketUtils} from "../markets/MarketUtils.sol";
import {Referral} from "../referrals/Referral.sol";
import {IPriceFeed} from "../oracle/interfaces/IPriceFeed.sol";

contract TradeStorage is ITradeStorage, RoleValidation, ReentrancyGuard {
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using SignedMath for int256;

    IMarket public market;
    IReferralStorage public referralStorage;
    IPriceFeed public priceFeed;

    uint256 private constant MAX_LIQUIDATION_FEE = 0.5e18; // 50%
    uint256 private constant MAX_TRADING_FEE = 0.01e18; // 1%

    mapping(bytes32 _key => Position.Request _order) private orders;
    EnumerableSet.Bytes32Set private marketOrderKeys;
    EnumerableSet.Bytes32Set private limitOrderKeys;

    mapping(bytes32 _positionKey => Position.Data) private openPositions;
    mapping(bool _isLong => EnumerableSet.Bytes32Set _positionKeys) internal openPositionKeys;

    bool private isInitialized;
    uint256 private liquidationFee; // Stored as a percentage with 18 D.P (e.g 0.05e18 = 5%)
    uint256 private minCollateralUsd;

    uint256 public tradingFee;
    // @gas - consider changing to uint64
    uint256 public minCancellationTime;
    // Minimum time a keeper must execute their reserved transaction before it is
    // made available to the broader network.
    uint256 public minTimeForExecution;

    constructor(IMarket _market, IReferralStorage _referralStorage, IPriceFeed _priceFeed, address _roleStorage)
        RoleValidation(_roleStorage)
    {
        market = _market;
        referralStorage = _referralStorage;
        priceFeed = _priceFeed;
    }

    /**
     * ===================================== Setter Functions =====================================
     */
    function initialize(
        uint256 _liquidationFee, // 0.05e18 = 5%
        uint256 _positionFee, // 0.001e18 = 0.1%
        uint256 _minCollateralUsd, // 2e30 = 2 USD
        uint256 _minCancellationTime, // e.g 1 minutes
        uint256 _minTimeForExecution // e.g 1 minutes
    ) external onlyMarketMaker {
        if (isInitialized) revert TradeStorage_AlreadyInitialized();
        liquidationFee = _liquidationFee;
        tradingFee = _positionFee;
        minCollateralUsd = _minCollateralUsd;
        minCancellationTime = _minCancellationTime;
        minTimeForExecution = _minTimeForExecution;
        isInitialized = true;
        emit TradeStorageInitialized(_liquidationFee, _positionFee);
    }

    // Time until a position request can be cancelled by a user
    function setMinCancellationTime(uint256 _minCancellationTime) external onlyConfigurator(address(market)) {
        minCancellationTime = _minCancellationTime;
    }

    // Time until a position request can be executed by the broader keeper network
    function setMinTimeForExecution(uint256 _minTimeForExecution) external onlyConfigurator(address(market)) {
        minTimeForExecution = _minTimeForExecution;
    }

    function setFees(uint256 _liquidationFee, uint256 _positionFee) external onlyConfigurator(address(market)) {
        if (!(_liquidationFee <= MAX_LIQUIDATION_FEE && _liquidationFee != 0)) {
            revert TradeStorage_InvalidLiquidationFee();
        }
        if (!(_positionFee <= MAX_TRADING_FEE && _positionFee != 0)) revert TradeStorage_InvalidTradingFee();
        liquidationFee = _liquidationFee;
        tradingFee = _positionFee;
        emit FeesSet(_liquidationFee, _positionFee);
    }

    /**
     * ===================================== Order Functions =====================================
     */

    /// @dev Adds Order to EnumerableSet
    function createOrderRequest(Position.Request calldata _request) external onlyRouter {
        // Create the order
        bytes32 orderKey = _createOrder(_request);
        // If SL / TP, tie to the position
        Position.Data storage position = openPositions[Position.generateKey(_request)];
        if (position.user == address(0)) revert TradeStorage_PositionDoesNotExist();
        if (_request.requestType == Position.RequestType.STOP_LOSS) {
            if (position.stopLossKey != bytes32(0)) revert TradeStorage_StopLossAlreadySet();
            position.stopLossKey = orderKey;
        } else {
            if (position.takeProfitKey != bytes32(0)) revert TradeStorage_TakeProfitAlreadySet();
            position.takeProfitKey = orderKey;
        }
    }

    function cancelOrderRequest(bytes32 _orderKey, bool _isLimit) external onlyPositionManager {
        // Delete the order
        _deleteOrder(_orderKey, _isLimit);
        // Fire Event
        emit OrderRequestCancelled(_orderKey);
    }

    /**
     * ===================================== Execution Functions =====================================
     */
    // @audit - needs to accept request id for limit order cases
    // the request id at request time won't be the same as the request id at execution time
    function executePositionRequest(bytes32 _orderKey, bytes32 _requestId, address _feeReceiver)
        external
        onlyPositionManager
        nonReentrant
        returns (Execution.State memory state, Position.Request memory request)
    {
        (state, request) =
            Execution.constructParams(market, this, priceFeed, referralStorage, _orderKey, _requestId, _feeReceiver);
        // Fetch the State of the Market Before the Position
        IMarket.MarketStorage memory initialMarket = market.getStorage(request.input.ticker);

        // Delete the Order from Storage
        _deleteOrder(_orderKey, request.input.isLimit);

        // Update the Market State
        _updateMarketState(
            state, request.input.ticker, request.input.sizeDelta, request.input.isLong, request.input.isIncrease
        );

        // Execute Trade
        if (request.requestType == Position.RequestType.CREATE_POSITION) {
            _createNewPosition(Position.Settlement(request, _orderKey, _feeReceiver, false), state);
        } else if (request.requestType == Position.RequestType.POSITION_INCREASE) {
            _increasePosition(Position.Settlement(request, _orderKey, _feeReceiver, false), state);
        } else if (
            request.requestType == Position.RequestType.POSITION_DECREASE
                || request.requestType == Position.RequestType.TAKE_PROFIT
                || request.requestType == Position.RequestType.STOP_LOSS
        ) {
            _decreasePosition(Position.Settlement(request, _orderKey, _feeReceiver, false), state);
        } else if (request.requestType == Position.RequestType.COLLATERAL_DECREASE) {
            _executeCollateralDecrease(Position.Settlement(request, _orderKey, _feeReceiver, false), state);
        } else if (request.requestType == Position.RequestType.COLLATERAL_INCREASE) {
            _executeCollateralIncrease(Position.Settlement(request, _orderKey, _feeReceiver, false), state);
        } else {
            revert TradeStorage_InvalidRequestType();
        }

        // Clear the Signed Prices
        priceFeed.clearSignedPrices(market, request.requestId);

        // Fetch the State of the Market After the Position
        IMarket.MarketStorage memory updatedMarket = market.getStorage(request.input.ticker);

        // Invariant Check
        Position.validateMarketDelta(initialMarket, updatedMarket, request);
    }

    function liquidatePosition(bytes32 _positionKey, bytes32 _requestId, address _liquidator)
        external
        onlyPositionManager
        nonReentrant
    {
        // Fetch the Position
        Position.Data memory position = openPositions[_positionKey];
        // Check the Position Exists
        if (position.user == address(0)) revert TradeStorage_PositionDoesNotExist();
        // Construct the Execution State
        Execution.State memory state;
        // @audit - is this the right price returned ? (min vs max vs med)
        state = Execution.cacheTokenPrices(priceFeed, state, position.ticker, _requestId, position.isLong, false);
        // No price impact on Liquidations
        state.impactedPrice = state.indexPrice;
        // Update the Market State
        _updateMarketState(state, position.ticker, position.positionSize, position.isLong, false);
        // Construct Liquidation Order
        Position.Settlement memory params = Position.constructLiquidationOrder(position, _liquidator);
        // Execute the Liquidation
        _decreasePosition(params, state);
        // Clear Signed Prices
        // Need request id
        priceFeed.clearSignedPrices(market, _requestId);
        // Fire Event
        emit LiquidatePosition(_positionKey, _liquidator, position.collateralAmount, position.isLong);
    }

    // @audit - as we scale, may become hard to keep on top of so many markets
    // need to consider how this would function if permissionless
    // probably need to add incentives for keepers to execute, similar to liquidations
    // @audit - make sure that the funds are going to the position owner, not the ADLer
    function executeAdl(bytes32 _positionKey, bytes32 _requestId, uint256 _sizeDelta)
        external
        onlyPositionManager
        nonReentrant
    {
        // Construct the Adl order
        (
            Execution.State memory state,
            Position.Settlement memory params,
            Position.Data memory position,
            uint256 targetPnlFactor,
            int256 startingPnlFactor
        ) = Execution.constructAdlOrder(market, this, priceFeed, _positionKey, _requestId, _sizeDelta);

        // Update the Market State
        _updateMarketState(
            state,
            params.request.input.ticker,
            params.request.input.sizeDelta,
            params.request.input.isLong,
            params.request.input.isIncrease
        );

        // Execute the order
        _decreasePosition(params, state);

        // Clear signed prices
        priceFeed.clearSignedPrices(market, _requestId);

        // Validate the Adl
        Execution.validateAdl(
            market, state, startingPnlFactor, targetPnlFactor, params.request.input.ticker, position.isLong
        );

        emit AdlExecuted(address(market), _positionKey, _sizeDelta, position.isLong);
    }

    /**
     * ===================================== Internal Functions =====================================
     */
    function _executeCollateralIncrease(Position.Settlement memory _params, Execution.State memory _state) internal {
        // Get the Position Key
        bytes32 positionKey = Position.generateKey(_params.request);
        // Perform Execution in Library
        Position.Data memory positionAfter;
        (positionAfter, _state) = Execution.increaseCollateral(market, this, _params, _state, positionKey);
        // Add Value to Stored Collateral Amount in Market
        market.updateCollateralAmount(
            _params.request.input.collateralDelta - _state.fee - _state.affiliateRebate - _state.borrowFee,
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
        _payFees(_state.borrowFee, _state.fee, _state.affiliateRebate, _state.referrer, _params.request.input.isLong);
        // Update Final Storage
        openPositions[positionKey] = positionAfter;
        emit CollateralEdited(positionKey, _params.request.input.collateralDelta, _params.request.input.isIncrease);
    }

    function _executeCollateralDecrease(Position.Settlement memory _params, Execution.State memory _state) internal {
        // Get the Position Key
        bytes32 positionKey = Position.generateKey(_params.request);
        // Perform Execution in Library
        Position.Data memory positionAfter;
        uint256 amountOut;
        (positionAfter, _state, amountOut) =
            Execution.decreaseCollateral(market, this, _params, _state, minCollateralUsd, liquidationFee, positionKey);
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
            revert TradeStorage_InsufficientFreeLiquidity();
        }
        // Decrease the Collateral Amount in the Market by the full delta
        market.updateCollateralAmount(
            _params.request.input.collateralDelta, _params.request.user, _params.request.input.isLong, false
        );
        // Pay Fees
        _payFees(_state.borrowFee, _state.fee, _state.affiliateRebate, _state.referrer, _params.request.input.isLong);
        // Update Final Storage
        openPositions[positionKey] = positionAfter;
        // Transfer Tokens to User
        market.transferOutTokens(
            _params.request.user, amountOut, _params.request.input.isLong, _params.request.input.reverseWrap
        );
        // Transfer Rebate to Referrer
        if (_state.affiliateRebate > 0) {
            market.transferOutTokens(
                _state.referrer,
                _state.affiliateRebate,
                _params.request.input.isLong,
                false // Leave unwrapped by default
            );
        }
        // Fire Event
        emit CollateralEdited(positionKey, _params.request.input.collateralDelta, _params.request.input.isIncrease);
    }

    function _createNewPosition(Position.Settlement memory _params, Execution.State memory _state) internal {
        // Get the Position Key
        bytes32 positionKey = Position.generateKey(_params.request);
        // Perform Execution in the Library
        Position.Data memory position;
        (position, _state) = Execution.createNewPosition(market, this, _params, _state, minCollateralUsd, positionKey);
        // If Request has conditionals, create the SL / TP
        (Position.Request memory stopLoss, Position.Request memory takeProfit) = Position.constructConditionalOrders(
            position, _params.request.input.conditionals, _params.request.input.executionFee
        );
        // If stop loss set, create and store the order
        if (_params.request.input.conditionals.stopLossSet) position.stopLossKey = _createOrder(stopLoss);
        // If take profit set, create and store the order
        if (_params.request.input.conditionals.takeProfitSet) {
            position.takeProfitKey = _createOrder(takeProfit);
        }
        // Pay fees
        _payFees(0, _state.fee, _state.affiliateRebate, _state.referrer, _params.request.input.isLong);
        // Reserve Liquidity Equal to the Position Size
        _reserveLiquidity(
            _params.request.input.sizeDelta,
            position.collateralAmount,
            _state.collateralPrice,
            _state.collateralBaseUnit,
            position.user,
            _params.request.input.isLong
        );
        // Update Final Storage
        openPositions[positionKey] = position;
        bool success = openPositionKeys[position.isLong].add(positionKey);
        if (!success) revert TradeStorage_PositionAdditionFailed();
        // Fire Event
        emit PositionCreated(positionKey);
    }

    function _increasePosition(Position.Settlement memory _params, Execution.State memory _state) internal {
        // Get the Position Key
        bytes32 positionKey = Position.generateKey(_params.request);
        // Perform Execution in the Library
        Position.Data memory position;
        (position, _state) = Execution.increasePosition(market, this, _params, _state, positionKey);
        // Pay Fees
        _payFees(_state.borrowFee, _state.fee, _state.affiliateRebate, _state.referrer, _params.request.input.isLong);
        // Reserve Liquidity Equal to the Position Size
        _reserveLiquidity(
            _params.request.input.sizeDelta,
            _params.request.input.collateralDelta - _state.fee - _state.affiliateRebate - _state.borrowFee,
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
        openPositions[positionKey] = position;
        // Fire event
        emit IncreasePosition(positionKey, _params.request.input.collateralDelta, _params.request.input.sizeDelta);
    }

    function _decreasePosition(Position.Settlement memory _params, Execution.State memory _state) internal {
        // Get the Position Key
        bytes32 positionKey = Position.generateKey(_params.request);
        // Perform Execution in the Library
        Position.Data memory positionAfter;
        Execution.DecreaseState memory decreaseState;
        (positionAfter, decreaseState, _state) =
            Execution.decreasePosition(market, this, _params, _state, minCollateralUsd, liquidationFee, positionKey);

        uint256 amountOut;

        // @audit - state changes correct?
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
            _payFees(
                _state.borrowFee, _state.fee, _state.affiliateRebate, _state.referrer, _params.request.input.isLong
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
        _unreserveLiquidity(
            _params.request.input.sizeDelta,
            _params.request.input.collateralDelta,
            _state.collateralPrice,
            _state.collateralBaseUnit,
            positionAfter.user,
            _params.request.input.isLong
        );

        // Delete the Position if Full Decrease
        if (positionAfter.positionSize == 0 || positionAfter.collateralAmount == 0) {
            _deletePosition(positionKey, _params.request.input.isLong);
        } else {
            // Update Final Storage
            openPositions[positionKey] = positionAfter;
        }

        // Check Market has enough available liquidity for payout
        if (market.totalAvailableLiquidity(_params.request.input.isLong) < amountOut + _state.affiliateRebate) {
            revert TradeStorage_InsufficientFreeLiquidity();
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
        }
        // Transfer Tokens to User
        if (amountOut > 0) {
            market.transferOutTokens(
                _params.request.user, amountOut, _params.request.input.isLong, _params.request.input.reverseWrap
            );
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
        // Fire Event
        emit DecreasePosition(positionKey, _params.request.input.collateralDelta, _params.request.input.sizeDelta);
    }

    function _createOrder(Position.Request memory _request) internal returns (bytes32 orderKey) {
        // Generate the Key
        orderKey = Position.generateOrderKey(_request);
        // Create a Storage Pointer to the Order Set
        EnumerableSet.Bytes32Set storage orderSet = _request.input.isLimit ? limitOrderKeys : marketOrderKeys;
        // Check if the Order already exists
        if (orderSet.contains(orderKey)) revert TradeStorage_OrderAlreadyExists();
        // Add the Order to the Set
        bool success = orderSet.add(orderKey);
        if (!success) revert TradeStorage_OrderAdditionFailed();
        orders[orderKey] = _request;
    }

    function _deletePosition(bytes32 _positionKey, bool _isLong) internal {
        delete openPositions[_positionKey];
        bool success = openPositionKeys[_isLong].remove(_positionKey);
        if (!success) revert TradeStorage_PositionRemovalFailed();
    }

    function _deleteOrder(bytes32 _orderKey, bool _isLimit) internal {
        bool success = _isLimit ? limitOrderKeys.remove(_orderKey) : marketOrderKeys.remove(_orderKey);
        if (!success) revert TradeStorage_OrderRemovalFailed();
        delete orders[_orderKey];
    }

    function _reserveLiquidity(
        uint256 _sizeDeltaUsd,
        uint256 _collateralDelta,
        uint256 _collateralPrice,
        uint256 _collateralBaseUnit,
        address _user,
        bool _isLong
    ) internal {
        // Convert Size Delta USD to Collateral Tokens
        uint256 reserveDelta = mulDiv(_sizeDeltaUsd, _collateralBaseUnit, _collateralPrice);
        // Reserve an Amount of Liquidity Equal to the Position Size
        market.updateLiquidityReservation(reserveDelta, _isLong, true);
        // Register the Collateral in
        market.updateCollateralAmount(_collateralDelta, _user, _isLong, true);
    }

    function _unreserveLiquidity(
        uint256 _sizeDeltaUsd,
        uint256 _collateralDelta,
        uint256 _collateralPrice,
        uint256 _collateralBaseUnit,
        address _user,
        bool _isLong
    ) internal {
        // Convert Size Delta USD to Collateral Tokens
        uint256 reserveDelta = (mulDiv(_sizeDeltaUsd, _collateralBaseUnit, _collateralPrice)); // Could use collateral delta * leverage for gas savings?
        // Unreserve an Amount of Liquidity Equal to the Position Size
        market.updateLiquidityReservation(reserveDelta, _isLong, false);
        // Register the Collateral out
        market.updateCollateralAmount(_collateralDelta, _user, _isLong, false);
    }

    function _updateMarketState(
        Execution.State memory _state,
        string memory _ticker,
        uint256 _sizeDelta,
        bool _isLong,
        bool _isIncrease
    ) internal {
        // Update the Market State
        market.updateMarketState(
            _ticker, _sizeDelta, _state.indexPrice, _state.impactedPrice, _state.collateralPrice, _isLong, _isIncrease
        );
        // If Price Impact is Negative, add to the impact Pool
        // If Price Impact is Positive, Subtract from the Impact Pool
        // Impact Pool Delta = -1 * Price Impact
        if (_state.priceImpactUsd == 0) return;
        market.updateImpactPool(_ticker, -_state.priceImpactUsd);
    }

    function _payFees(
        uint256 _borrowAmount,
        uint256 _positionFee,
        uint256 _affiliateRebate,
        address _referrer,
        bool _isLong
    ) internal {
        // Pay Fees to LPs for Side (Position + Borrow)
        market.accumulateFees(_borrowAmount + _positionFee, _isLong);
        // Pay Affiliate Rebate to Referrer
        if (_affiliateRebate > 0) {
            referralStorage.accumulateAffiliateRewards(address(market), _referrer, _isLong, _affiliateRebate);
        }
    }

    /**
     * ===================================== Getter Functions =====================================
     */
    function getOpenPositionKeys(bool _isLong) external view returns (bytes32[] memory) {
        return openPositionKeys[_isLong].values();
    }

    function getOrderKeys(bool _isLimit) external view returns (bytes32[] memory orderKeys) {
        orderKeys = _isLimit ? limitOrderKeys.values() : marketOrderKeys.values();
    }

    function getPosition(bytes32 _positionKey) external view returns (Position.Data memory) {
        return openPositions[_positionKey];
    }

    function getOrder(bytes32 _orderKey) external view returns (Position.Request memory) {
        return orders[_orderKey];
    }

    function getOrderAtIndex(uint256 _index, bool _isLimit) external view returns (bytes32) {
        return _isLimit ? limitOrderKeys.at(_index) : marketOrderKeys.at(_index);
    }
}
