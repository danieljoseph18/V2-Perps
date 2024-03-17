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
import {Invariant} from "../libraries/Invariant.sol";
import {ReentrancyGuard} from "@solmate/utils/ReentrancyGuard.sol";
import {IReferralStorage} from "../referrals/interfaces/IReferralStorage.sol";

/// @dev Needs TradeStorage Role & Fee Accumulator
/// @dev Need to add liquidity reservation for positions
contract TradeStorage is ITradeStorage, RoleValidation, ReentrancyGuard {
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using SignedMath for int256;

    IReferralStorage referralStorage;

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

    constructor(IReferralStorage _referralStorage, address _roleStorage) RoleValidation(_roleStorage) {
        referralStorage = _referralStorage;
    }

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
    // @audit - REVAMP
    function createEditOrder(Position.Conditionals memory _conditionals, bytes32 _positionKey) external onlyRouter {
        Position.Data memory position = openPositions[_positionKey];
        if (!Position.exists(position)) revert TradeStorage_PositionDoesNotExist();
        // construct the SL / TP orders
        // Uses WAEP as ref price
        (Position.Request memory stopLoss, Position.Request memory takeProfit) =
            Position.constructConditionalOrders(position, _conditionals);
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


    function executeCollateralIncrease(Position.Settlement memory _params, Execution.State memory _state)
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
        (positionAfter, _state) = Execution.increaseCollateral(positionBefore, _params, _state);
        // Validate the Position Change
        Invariant.validateCollateralIncrease(
            positionBefore,
            positionAfter,
            _params.request.input.collateralDelta,
            _state.fee,
            _state.borrowFee,
            _state.affiliateRebate
        );
        // Add Value to Stored Collateral Amount in Market
        _state.market.increaseCollateralAmount(
            _params.request.input.collateralDelta - _state.fee - _state.affiliateRebate - _state.borrowFee, // @audit - correct? I think affiliate rebate needs to be removed.
            _params.request.user,
            _params.request.input.isLong
        );
        // Pay Fees -> @audit - units? @audit - accounting
        _payFees(
            _state.market,
            _state.borrowFee,
            _state.fee,
            _state.affiliateRebate,
            _state.referrer,
            _params.request.input.isLong
        );
        // Update Final Storage
        openPositions[positionKey] = positionAfter;
        emit CollateralEdited(positionKey, _params.request.input.collateralDelta, _params.request.input.isIncrease);
    }


    function executeCollateralDecrease(Position.Settlement memory _params, Execution.State memory _state)
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
            Execution.decreaseCollateral(positionBefore, _params, _state, minCollateralUsd, liquidationFeeUsd);
        // Transfer Tokens to User
        uint256 amountOut =
            _params.request.input.collateralDelta - _state.fee - _state.affiliateRebate - _state.borrowFee;
        // Validate the Position Change
        Invariant.validateCollateralDecrease(
            positionBefore, positionAfter, amountOut, _state.fee, _state.borrowFee, _state.affiliateRebate
        );
        // Check Market has enough available liquidity for payout
        if (_state.market.totalAvailableLiquidity(_params.request.input.isLong) < amountOut + _state.affiliateRebate) {
            revert TradeStorage_InsufficientFreeLiquidity();
        }
        // Decrease the Collateral Amount in the Market by the full delta
        _state.market.decreaseCollateralAmount(
            _params.request.input.collateralDelta, _params.request.user, _params.request.input.isLong
        );
        // Pay Fees
        _payFees(
            _state.market,
            _state.borrowFee,
            _state.fee,
            _state.affiliateRebate,
            _state.referrer,
            _params.request.input.isLong
        );
        // Update Final Storage
        openPositions[positionKey] = positionAfter;
        // Transfer Tokens to User
        _state.market.transferOutTokens(
            _params.request.user, amountOut, _params.request.input.isLong, _params.request.input.reverseWrap
        );
        // Transfer Rebate to Referrer
        if (_state.affiliateRebate > 0) {
            referralStorage.accumulateAffiliateRewards(
                _state.referrer, _params.request.input.isLong, _state.affiliateRebate
            );
            _state.market.transferOutTokens(
                _state.referrer,
                _state.affiliateRebate,
                _params.request.input.isLong,
                false // Leave unwrapped by default
            );
        }
        // Fire Event
        emit CollateralEdited(positionKey, _params.request.input.collateralDelta, _params.request.input.isIncrease);
    }

    // @audit - Set funding entry values
    function createNewPosition(Position.Settlement memory _params, Execution.State memory _state)
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
        (position, _state) = Execution.createNewPosition(_params, _state, minCollateralUsd);
        // Validate the New Position
        Invariant.validateNewPosition(
            _params.request.input.collateralDelta, position.collateralAmount, _state.fee, _state.affiliateRebate
        );
        // If Request has conditionals, create the SL / TP
        (Position.Request memory stopLoss, Position.Request memory takeProfit) =
            Position.constructConditionalOrders(position, _params.request.input.conditionals);
        // If stop loss set, create and store the order
        if (_params.request.input.conditionals.stopLossSet) position.stopLossKey = _createStopLoss(stopLoss);
        // If take profit set, create and store the order
        if (_params.request.input.conditionals.takeProfitSet) position.takeProfitKey = _createTakeProfit(takeProfit);
        // Pay fees
        _payFees(_state.market, 0, _state.fee, _state.affiliateRebate, _state.referrer, _params.request.input.isLong);
        // Reserve Liquidity Equal to the Position Size
        _reserveLiquidity(
            _state.market,
            _params.request.input.sizeDelta,
            position.collateralAmount,
            _state.collateralPrice,
            _state.collateralBaseUnit,
            position.user,
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
    function increaseExistingPosition(Position.Settlement memory _params, Execution.State memory _state)
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
        (positionAfter, _state) = Execution.increasePosition(positionBefore, _params, _state);
        // Validate the Position Change
        Invariant.validateIncreasePosition(
            positionBefore,
            positionAfter,
            _params.request.input.collateralDelta,
            _state.fee,
            _state.affiliateRebate,
            _state.borrowFee,
            _params.request.input.sizeDelta
        );
        // Pay Fees
        _payFees(
            _state.market,
            _state.borrowFee,
            _state.fee,
            _state.affiliateRebate,
            _state.referrer,
            _params.request.input.isLong
        );
        // Reserve Liquidity Equal to the Position Size
        _reserveLiquidity(
            _state.market,
            _params.request.input.sizeDelta,
            _params.request.input.collateralDelta - _state.fee - _state.affiliateRebate - _state.borrowFee, // @audit - verify
            _state.collateralPrice,
            _state.collateralBaseUnit,
            positionBefore.user,
            _params.request.input.isLong
        );
        // Update Final Storage
        openPositions[positionKey] = positionAfter;
    }

    // @audit - SETTLE ALL PREVIOUS FUNDING AND START ACCUMULATING AT NEW RATE OR CLOSE
    function decreaseExistingPosition(Position.Settlement calldata _params, Execution.State memory _state)
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
        Execution.DecreaseState memory decreaseState;
        (positionAfter, decreaseState, _state) =
            Execution.decreasePosition(positionBefore, _params, _state, minCollateralUsd, liquidationFeeUsd);
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
        _payFees(
            _state.market,
            _state.borrowFee,
            _state.fee,
            _state.affiliateRebate,
            _state.referrer,
            _params.request.input.isLong
        );
        // stated to prevent multi conversion
        address market = address(positionBefore.market);
        // Unreserve Liquidity Equal to the Position Size
        _unreserveLiquidity(
            _state.market,
            _params.request.input.sizeDelta,
            _params.request.input.collateralDelta, // Full Amount
            _state.collateralPrice,
            _state.collateralBaseUnit,
            positionBefore.user,
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
            : decreaseState.afterFeeAmount; // Loss / Break Even Case -> Losses already deducted in Execution if any

        // Check Market has enough available liquidity for payout
        if (_state.market.totalAvailableLiquidity(_params.request.input.isLong) < amountOut + _state.affiliateRebate) {
            revert TradeStorage_InsufficientFreeLiquidity();
        }
        // Transfer Tokens to User
        _state.market.transferOutTokens(
            _params.request.user, amountOut, _params.request.input.isLong, _params.request.input.reverseWrap
        );
        // Transfer Rebate to Referrer
        if (_state.affiliateRebate > 0) {
            referralStorage.accumulateAffiliateRewards(
                _state.referrer, _params.request.input.isLong, _state.affiliateRebate
            );
            _state.market.transferOutTokens(
                _state.referrer,
                _state.affiliateRebate,
                _params.request.input.isLong,
                false // Leave unwrapped by default
            );
        }
        // Fire Event
        emit DecreasePosition(positionKey, _params.request.input.collateralDelta, _params.request.input.sizeDelta);
    }

    /// @dev - Borrowing Fees ignored as all liquidated collateral goes to LPs
    // @audit - need to calculate funding fees
    function liquidatePosition(Execution.State memory _state, bytes32 _positionKey, address _liquidator)
        external
        onlyProcessor
    {
        /* Update Initial Storage */
        Position.Data memory position = openPositions[_positionKey];
        if (!Position.exists(position)) revert TradeStorage_PositionDoesNotExist();

        uint256 remainingCollateral = position.collateralAmount;
        // cached to prevent double conversion
        address market = address(_state.market);
        // delete the position from storage
        delete openPositions[_positionKey];
        openPositionKeys[market][position.isLong].remove(_positionKey);

        // Calculate the Funding Fee and Pay off all Outstanding
        // @here
        // @audit - need to pay all of users fees, positive or negative
        // need to prioritize the liquidation fee to the liquidator
        // handle case for insolvent liquidations
        // Use Position.liquidate
        (uint256 feesOwedToUser, uint256 feesToAccumulate, uint256 liqFeeInCollateral) =
            Position.liquidate(position, _state, liquidationFeeUsd);

        // unreserve all of the position's liquidity
        _unreserveLiquidity(
            _state.market,
            position.positionSize,
            remainingCollateral,
            _state.collateralPrice,
            _state.collateralBaseUnit,
            position.user,
            position.isLong
        );
        // Remanining collateral after fees is added to the relevant pool
        _state.market.increasePoolBalance(remainingCollateral, position.isLong);
        // Accumulate the fees to accumulate
        _state.market.accumulateFees(feesToAccumulate, position.isLong);

        // Pay the liquidator
        _state.market.transferOutTokens(
            _liquidator,
            liqFeeInCollateral,
            position.isLong,
            true // Unwrap by default
        );
        // Pay the fees owed to the user
        _state.market.transferOutTokens(
            position.user,
            feesOwedToUser,
            position.isLong,
            true // Unwrap by default
        );

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
        uint256 _collateralDelta,
        uint256 _collateralPrice,
        uint256 _collateralBaseUnit,
        address _user,
        bool _isLong
    ) internal {
        // Convert Size Delta USD to Collateral Tokens
        uint256 reserveDelta = mulDiv(_sizeDeltaUsd, _collateralBaseUnit, _collateralPrice);
        // Reserve an Amount of Liquidity Equal to the Position Size
        market.reserveLiquidity(reserveDelta, _isLong);
        // Register the Collateral in
        market.increaseCollateralAmount(_collateralDelta, _user, _isLong);
    }

    function _unreserveLiquidity(
        IMarket market,
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
        market.unreserveLiquidity(reserveDelta, _isLong);
        // Register the Collateral out
        market.decreaseCollateralAmount(_collateralDelta, _user, _isLong);
    }

    // funding and borrow amounts should be in collateral tokens
    // @audit - should funding fees be accounted for or go directly through LPs?
    function _payFees(
        IMarket market,
        uint256 _borrowAmount,
        uint256 _positionFee,
        uint256 _affiliateRebate,
        address _referrer,
        bool _isLong
    ) internal {
        // Pay Fees to LPs for Side (Position + Borrow)
        market.accumulateFees(_borrowAmount + _positionFee, _isLong);
        // Pay Affiliate Rebate to Referrer
        referralStorage.accumulateAffiliateRewards(_referrer, _isLong, _affiliateRebate);
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
