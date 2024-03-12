//  ,----,------------------------------,------.
//   | ## |                              |    - |
//   | ## |                              |    - |
//   |    |------------------------------|    - |
//   |    ||............................||      |
//   |    ||,-                        -.||      |
//   |    ||___                      ___||    ##|
//   |    ||---`--------------------'---||      |
//   `--mb'|_|______________________==__|`------'

//    ____  ____  ___ _   _ _____ _____ ____
//   |  _ \|  _ \|_ _| \ | |_   _|___ /|  _ \
//   | |_) | |_) || ||  \| | | |   |_ \| |_) |
//   |  __/|  _ < | || |\  | | |  ___) |  _ <
//   |_|   |_| \_\___|_| \_| |_| |____/|_| \_\

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {ITradeStorage} from "./interfaces/ITradeStorage.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {RoleValidation} from "../access/RoleValidation.sol";
import {Funding} from "../libraries/Funding.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Position} from "../positions/Position.sol";
import {mulDiv} from "@prb/math/Common.sol";
import {Order} from "./Order.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {Invariant} from "../libraries/Invariant.sol";
import {ReentrancyGuard} from "@solmate/utils/ReentrancyGuard.sol";

/// @dev Needs TradeStorage Role & Fee Accumulator
/// @dev Need to add liquidity reservation for positions
contract TradeStorage is ITradeStorage, RoleValidation, ReentrancyGuard {
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using SignedMath for int256;

    uint256 constant PRECISION = 1e18;
    uint256 constant MAX_LIQUIDATION_FEE = 100e18; // 100 USD
    uint256 constant MAX_TRADING_FEE = 0.01e18; // 1%

    mapping(bytes32 _key => Position.Request _order) private orders;
    EnumerableSet.Bytes32Set private marketOrderKeys;
    EnumerableSet.Bytes32Set private limitOrderKeys;

    mapping(bytes32 _positionKey => Position.Data) private openPositions;
    mapping(address _market => mapping(bool _isLong => EnumerableSet.Bytes32Set _positionKeys)) internal
        openPositionKeys;

    bool private isInitialised;

    uint256 public liquidationFeeUsd;
    uint256 public minCollateralUsd;
    uint256 public tradingFee;
    uint256 public executionFee;
    uint256 public minBlockDelay;

    constructor(address _roleStorage) RoleValidation(_roleStorage) {}

    function initialise(
        uint256 _liquidationFee, // 5e18 = 5 USD
        uint256 _positionFee, // 0.001e18 = 0.1%
        uint256 _executionFee, // 0.001 ether
        uint256 _minCollateralUsd, // 2e18 = 2 USD
        uint256 _minBlockDelay // e.g 1 minutes
    ) external onlyAdmin {
        if (isInitialised) revert TradeStorage_AlreadyInitialised();
        liquidationFeeUsd = _liquidationFee;
        tradingFee = _positionFee;
        executionFee = _executionFee;
        minCollateralUsd = _minCollateralUsd;
        minBlockDelay = _minBlockDelay;
        isInitialised = true;
        emit TradeStorageInitialised(_liquidationFee, _positionFee, _executionFee);
    }

    function setMinBlockDelay(uint256 _minBlockDelay) external onlyConfigurator {
        minBlockDelay = _minBlockDelay;
    }

    function setFees(uint256 _liquidationFee, uint256 _positionFee) external onlyConfigurator {
        if (!(_liquidationFee <= MAX_LIQUIDATION_FEE && _liquidationFee != 0)) {
            revert TradeStorage_InvalidLiquidationFee();
        }
        if (!(_positionFee <= MAX_TRADING_FEE && _positionFee != 0)) revert TradeStorage_InvalidTradingFee();
        liquidationFeeUsd = _liquidationFee;
        tradingFee = _positionFee;
        emit FeesSet(_liquidationFee, _positionFee);
    }

    /// @dev Adds Order to EnumerableSet
    // @audit - Need to distinguish between order key and position key
    // order key needs to include request type to enable simultaneous stop loss and take profit
    function createOrderRequest(Position.Request calldata _request) external onlyRouter {
        // Generate the Key
        bytes32 orderKey = Position.generateOrderKey(_request);
        // Create a Storage Pointer to the Order Set
        EnumerableSet.Bytes32Set storage orderSet = _request.input.isLimit ? limitOrderKeys : marketOrderKeys;
        // Check if the Order already exists
        if (orderSet.contains(orderKey)) revert TradeStorage_OrderAlreadyExists();
        // Add the Order to the Set
        bool success = orderSet.add(orderKey);
        if (!success) revert TradeStorage_OrderAdditionFailed();
        orders[orderKey] = _request;
        // Fire Event
        emit OrderRequestCreated(orderKey, _request);
    }

    /// @dev Create a SL / TP Order or update an existing one
    function createEditOrder(Position.Conditionals memory _conditionals, bytes32 _positionKey) external onlyRouter {
        Position.Data memory position = openPositions[_positionKey];
        if (!Position.exists(position)) revert TradeStorage_PositionDoesNotExist();
        // construct the SL / TP orders
        // Uses WAEP as ref price
        (Position.Request memory stopLoss, Position.Request memory takeProfit) =
            Order.constructConditionalOrders(position, _conditionals, position.weightedAvgEntryPrice);
        // if the position already has a SL / TP, delete them
        // add them to storage
        if (_conditionals.stopLossSet) {
            // If Setting a SL, delete the existing SL
            if (position.stopLossKey != bytes32(0)) {
                _deleteOrder(position.stopLossKey, true);
            }
            // Create and Set SL
            openPositions[_positionKey].stopLossKey = _createStopLoss(stopLoss);

            emit StopLossSet(_positionKey, _conditionals.stopLossPrice, _conditionals.stopLossPercentage);
        }

        if (_conditionals.takeProfitSet) {
            // If Setting a TP, delete the existing TP
            if (position.takeProfitKey != bytes32(0)) {
                _deleteOrder(position.takeProfitKey, true);
            }
            // Create and Set TP
            openPositions[_positionKey].takeProfitKey = _createTakeProfit(takeProfit);

            emit TakeProfitSet(_positionKey, _conditionals.takeProfitPrice, _conditionals.takeProfitPercentage);
        }
    }

    function cancelOrderRequest(bytes32 _orderKey, bool _isLimit) external onlyRouterOrProcessor {
        // Create a Storage Pointer to the Order Set
        EnumerableSet.Bytes32Set storage orderKeys = _isLimit ? limitOrderKeys : marketOrderKeys;
        // Check if the Order exists
        if (!orderKeys.contains(_orderKey)) revert TradeStorage_OrderDoesNotExist();
        // Remove the Order from the Set
        orderKeys.remove(_orderKey);
        delete orders[_orderKey];
        // Fire Event
        emit OrderRequestCancelled(_orderKey);
    }

    // @audit - No funding
    function executeCollateralIncrease(Position.Execution memory _params, Order.ExecutionState memory _state)
        external
        onlyProcessor
        nonReentrant
    {
        // Check the Position exists
        bytes32 positionKey = Position.generateKey(_params.request);
        Position.Data memory positionBefore = openPositions[positionKey];
        if (!Position.exists(positionBefore)) revert TradeStorage_PositionDoesNotExist();
        // Delete the Order from Storage
        _deleteOrder(_params.orderKey, _params.request.input.isLimit);
        // Perform Execution in Library
        Position.Data memory positionAfter;
        (positionAfter, _state) = Order.executeCollateralIncrease(positionBefore, _params, _state);
        // Validate the Position Change
        Invariant.validateCollateralIncrease(
            positionBefore,
            positionAfter,
            _params.request.input.collateralDelta,
            _state.fee,
            _state.borrowFee,
            _state.affiliateRebate
        );
        // Pay Fees -> @audit - units? @audit - accounting
        _payFees(_state.market, _state.borrowFee, _state.fee, _params.request.input.isLong);
        // Update Final Storage
        openPositions[positionKey] = positionAfter;
        emit CollateralEdited(positionKey, _params.request.input.collateralDelta, _params.request.input.isIncrease);
    }

    // @audit - No funding
    function executeCollateralDecrease(Position.Execution memory _params, Order.ExecutionState memory _state)
        external
        onlyProcessor
        nonReentrant
    {
        // Check the Position exists
        bytes32 positionKey = Position.generateKey(_params.request);
        Position.Data memory positionBefore = openPositions[positionKey];
        if (!Position.exists(positionBefore)) revert TradeStorage_PositionDoesNotExist();
        // Delete the Order from Storage
        _deleteOrder(_params.orderKey, _params.request.input.isLimit);
        // Perform Execution in Library
        Position.Data memory positionAfter;
        (positionAfter, _state) =
            Order.executeCollateralDecrease(positionBefore, _params, _state, minCollateralUsd, liquidationFeeUsd);
        // Transfer Tokens to User
        uint256 amountOut =
            _params.request.input.collateralDelta - _state.fee - _state.affiliateRebate - _state.borrowFee;
        // Validate the Position Change
        Invariant.validateCollateralDecrease(
            positionBefore, positionAfter, amountOut, _state.fee, _state.borrowFee, _state.affiliateRebate
        );
        // Pay Fees
        _payFees(_state.market, _state.borrowFee, _state.fee, _params.request.input.isLong);
        // Update Final Storage
        openPositions[positionKey] = positionAfter;
        _state.market.transferOutTokens(
            _params.request.user,
            amountOut,
            _params.request.input.isLong,
            _params.request.input.shouldWrap // @audit - should unwrap
        );
        // Fire Event
        emit CollateralEdited(positionKey, _params.request.input.collateralDelta, _params.request.input.isIncrease);
    }

    // @audit - Set funding entry values
    function createNewPosition(Position.Execution memory _params, Order.ExecutionState memory _state)
        external
        onlyProcessor
        nonReentrant
    {
        // Check the Position doesn't exist
        bytes32 positionKey = Position.generateKey(_params.request);
        if (Position.exists(openPositions[positionKey])) revert TradeStorage_PositionExists();
        // Delete the Order from Storage
        _deleteOrder(_params.orderKey, _params.request.input.isLimit);
        // Perform Execution in the Library
        // @audit - logic?
        Position.Data memory position;
        (position, _state) = Order.createNewPosition(_params, _state, minCollateralUsd);
        // Validate the New Position
        Invariant.validateNewPosition(
            _params.request.input.collateralDelta, position.collateralAmount, _state.fee, _state.affiliateRebate
        );
        // If Request has conditionals, create the SL / TP
        (Position.Request memory stopLoss, Position.Request memory takeProfit) =
            Order.constructConditionalOrders(position, _params.request.input.conditionals, _state.indexPrice);
        // If stop loss set, create and store the order
        if (_params.request.input.conditionals.stopLossSet) position.stopLossKey = _createStopLoss(stopLoss);
        // If take profit set, create and store the order
        if (_params.request.input.conditionals.takeProfitSet) position.takeProfitKey = _createTakeProfit(takeProfit);
        // Pay fees
        _payFees(_state.market, 0, _state.fee, _params.request.input.isLong);
        // Reserve Liquidity Equal to the Position Size
        _reserveLiquidity(
            _state.market,
            _params.request.input.sizeDelta,
            _state.collateralPrice,
            _state.collateralBaseUnit,
            _params.request.input.isLong
        );
        // Update Final Storage
        openPositions[positionKey] = position;
        bool success = openPositionKeys[_params.request.market][position.isLong].add(positionKey);
        if (!success) revert TradeStorage_PositionAdditionFailed();
        // Fire Event
        emit PositionCreated(positionKey, position);
    }

    // @audit - SETTLE ALL PREVIOUS FUNDING AND START ACCUMULATING AT NEW RATE
    function increaseExistingPosition(Position.Execution memory _params, Order.ExecutionState memory _state)
        external
        onlyProcessor
        nonReentrant
    {
        // Check the Position exists
        bytes32 positionKey = Position.generateKey(_params.request);
        Position.Data memory positionBefore = openPositions[positionKey];
        if (!Position.exists(positionBefore)) revert TradeStorage_PositionDoesNotExist();
        // Delete the Order from Storage
        _deleteOrder(_params.orderKey, _params.request.input.isLimit);
        // Perform Execution in the Library
        Position.Data memory positionAfter;
        (positionAfter, _state) = Order.increaseExistingPosition(positionBefore, _params, _state);
        // Validate the Position Change
        Invariant.validateIncreasePosition(
            positionBefore,
            positionAfter,
            _params.request.input.collateralDelta,
            _state.fee,
            _state.affiliateRebate,
            _state.fundingFee,
            _state.borrowFee,
            _params.request.input.sizeDelta
        );
        // Pay Fees
        _payFees(_state.market, _state.borrowFee, _state.fee, _params.request.input.isLong);
        // Reserve Liquidity Equal to the Position Size
        _reserveLiquidity(
            _state.market,
            _params.request.input.sizeDelta,
            _state.collateralPrice,
            _state.collateralBaseUnit,
            _params.request.input.isLong
        );
        // Update Final Storage
        openPositions[positionKey] = positionAfter;
    }

    // @audit - SETTLE ALL PREVIOUS FUNDING AND START ACCUMULATING AT NEW RATE OR CLOSE
    function decreaseExistingPosition(Position.Execution calldata _params, Order.ExecutionState memory _state)
        external
        onlyProcessor
        nonReentrant
    {
        // Check the Position exists
        bytes32 positionKey = Position.generateKey(_params.request);
        Position.Data memory positionBefore = openPositions[positionKey];
        if (!Position.exists(positionBefore)) revert TradeStorage_PositionDoesNotExist();
        // Delete the Order from Storage
        _deleteOrder(_params.orderKey, _params.request.input.isLimit);
        // If SL / TP, clear from the position
        if (_params.request.requestType == Position.RequestType.STOP_LOSS) {
            positionBefore.stopLossKey = bytes32(0);
        } else if (_params.request.requestType == Position.RequestType.TAKE_PROFIT) {
            positionBefore.takeProfitKey = bytes32(0);
        }
        // Perform Execution in the Library
        Position.Data memory positionAfter;
        Order.DecreaseState memory decreaseState;
        (positionAfter, decreaseState, _state) =
            Order.decreaseExistingPosition(positionBefore, _params, _state, minCollateralUsd, liquidationFeeUsd);
        // Validate the Position Change
        Invariant.validateDecreasePosition(
            positionBefore,
            positionAfter,
            decreaseState.afterFeeAmount,
            _state.fee,
            _state.affiliateRebate,
            decreaseState.decreasePnl,
            _state.borrowFee,
            _params.request.input.sizeDelta
        );
        // Pay Fees
        _payFees(_state.market, _state.borrowFee, _state.fee, _params.request.input.isLong);
        // stated to prevent multi conversion
        address market = address(positionBefore.market);
        // Unreserve Liquidity Equal to the Position Size
        _unreserveLiquidity(
            _state.market,
            _params.request.input.sizeDelta,
            _state.collateralPrice,
            _state.collateralBaseUnit,
            _params.request.input.isLong
        );
        // Update Final Storage
        openPositions[positionKey] = positionAfter;
        // Delete the Position if Full Decrease
        if (positionAfter.positionSize == 0 || positionAfter.collateralAmount == 0) {
            _deletePosition(positionKey, market, _params.request.input.isLong);
        }
        // Transfer Tokens to User
        uint256 amountOut = decreaseState.decreasePnl > 0
            ? decreaseState.afterFeeAmount + decreaseState.decreasePnl.abs() // Profit Case
            : decreaseState.afterFeeAmount; // Loss / Break Even Case

        _state.market.transferOutTokens(
            _params.request.user, amountOut, _params.request.input.isLong, _params.request.input.shouldWrap
        );
        // Fire Event
        emit DecreasePosition(positionKey, _params.request.input.collateralDelta, _params.request.input.sizeDelta);
    }

    /// @dev - Borrowing Fees ignored as all liquidated collateral goes to LPs
    // @audit - need to calculate funding fees
    function liquidatePosition(Order.ExecutionState memory _state, bytes32 _positionKey, address _liquidator)
        external
        onlyProcessor
    {
        /* Update Initial Storage */
        Position.Data memory position = openPositions[_positionKey];
        if (!Position.exists(position)) revert TradeStorage_PositionDoesNotExist();
        if (!Position.isLiquidatable(position, _state, liquidationFeeUsd)) revert TradeStorage_NotLiquidatable();

        uint256 remainingCollateral = position.collateralAmount;

        // Calculate the Funding Fee and Pay off all Outstanding
        // @here

        // stated to prevent double conversion
        address market = address(_state.market);

        // delete the position from storage
        delete openPositions[_positionKey];
        openPositionKeys[market][position.isLong].remove(_positionKey);

        // unreserve all of the position liquidity
        _unreserveLiquidity(
            _state.market, position.positionSize, _state.collateralPrice, _state.collateralBaseUnit, position.isLong
        );

        // calculate the liquidation fee to send to the liquidator
        uint256 liqFee =
            Position.calculateLiquidationFee(_state.collateralPrice, _state.collateralBaseUnit, liquidationFeeUsd);
        remainingCollateral -= liqFee;
        // accumulate the rest of the position size as fees
        _state.market.accumulateFees(remainingCollateral, position.isLong);
        // transfer the liquidation fee to the liquidator
        _state.market.transferOutTokens(_liquidator, liqFee, position.isLong, false);
        emit LiquidatePosition(_positionKey, _liquidator, position.collateralAmount, position.isLong);
    }

    function _createStopLoss(Position.Request memory _stopLoss) internal returns (bytes32 stopLossKey) {
        stopLossKey = Position.generateOrderKey(_stopLoss);
        bool success = limitOrderKeys.add(stopLossKey);
        if (!success) revert TradeStorage_KeyAdditionFailed();
        orders[stopLossKey] = _stopLoss;
    }

    function _createTakeProfit(Position.Request memory _takeProfit) internal returns (bytes32 takeProfitKey) {
        takeProfitKey = Position.generateOrderKey(_takeProfit);
        bool success = limitOrderKeys.add(takeProfitKey);
        if (!success) revert TradeStorage_KeyAdditionFailed();
        orders[takeProfitKey] = _takeProfit;
    }

    function _deletePosition(bytes32 _positionKey, address _market, bool _isLong) internal {
        delete openPositions[_positionKey];
        openPositionKeys[_market][_isLong].remove(_positionKey);
    }

    function _deleteOrder(bytes32 _orderKey, bool _isLimit) internal {
        _isLimit ? limitOrderKeys.remove(_orderKey) : marketOrderKeys.remove(_orderKey);
        delete orders[_orderKey];
    }

    function _reserveLiquidity(
        IMarket market,
        uint256 _sizeDeltaUsd,
        uint256 _collateralPrice,
        uint256 _collateralBaseUnit,
        bool _isLong
    ) internal {
        // Convert Size Delta USD to Collateral Tokens
        uint256 reserveDelta = (mulDiv(_sizeDeltaUsd, _collateralBaseUnit, _collateralPrice));
        market.reserveLiquidity(reserveDelta, _isLong);
    }

    function _unreserveLiquidity(
        IMarket market,
        uint256 _sizeDeltaUsd,
        uint256 _collateralPrice,
        uint256 _collateralBaseUnit,
        bool _isLong
    ) internal {
        // Convert Size Delta USD to Collateral Tokens
        uint256 reserveDelta = (mulDiv(_sizeDeltaUsd, _collateralBaseUnit, _collateralPrice));
        market.unreserveLiquidity(reserveDelta, _isLong);
    }

    // funding and borrow amounts should be in collateral tokens
    // @audit - should funding fees be accounted for or go directly through LPs?
    function _payFees(IMarket market, uint256 _borrowAmount, uint256 _positionFee, bool _isLong) internal {
        // decrease the user's reserved amount // @audit???
        // market.unreserveLiquidity(_borrowAmount, _isLong);
        // Pay borrowing fees to LPs
        market.accumulateFees(_borrowAmount + _positionFee, _isLong);
    }

    function getOpenPositionKeys(address _market, bool _isLong) external view returns (bytes32[] memory) {
        return openPositionKeys[_market][_isLong].values();
    }

    function getOrderKeys(bool _isLimit) external view returns (bytes32[] memory orderKeys) {
        orderKeys = _isLimit ? limitOrderKeys.values() : marketOrderKeys.values();
    }

    function getRequestQueueLengths() external view returns (uint256 marketLen, uint256 limitLen) {
        marketLen = marketOrderKeys.length();
        limitLen = limitOrderKeys.length();
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
