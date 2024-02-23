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
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ILiquidityVault} from "../liquidity/interfaces/ILiquidityVault.sol";
import {RoleValidation} from "../access/RoleValidation.sol";
import {Borrowing} from "../libraries/Borrowing.sol";
import {Funding} from "../libraries/Funding.sol";
import {Pricing} from "../libraries/Pricing.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {Position} from "../positions/Position.sol";
import {mulDiv} from "@prb/math/Common.sol";
import {MarketUtils} from "../markets/MarketUtils.sol";
import {Order} from "./Order.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IPriceFeed} from "../oracle/interfaces/IPriceFeed.sol";
import {Oracle} from "../oracle/Oracle.sol";

/// @dev Needs TradeStorage Role
/// @dev Need to add liquidity reservation for positions
contract TradeStorage is ITradeStorage, RoleValidation {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using SignedMath for int256;
    using SafeCast for uint256;
    using SafeCast for int256;

    IPriceFeed priceFeed;
    ILiquidityVault liquidityVault;

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

    constructor(address _liquidityVault, address _priceFeed, address _roleStorage) RoleValidation(_roleStorage) {
        liquidityVault = ILiquidityVault(_liquidityVault);
        priceFeed = IPriceFeed(_priceFeed);
    }

    function initialise(
        uint256 _liquidationFee, // 5e18 = 5 USD
        uint256 _tradingFee, // 0.001e18 = 0.1%
        uint256 _executionFee, // 0.001 ether
        uint256 _minCollateralUsd, // 2e18 = 2 USD
        uint256 _minBlockDelay // e.g 1 minutes
    ) external onlyAdmin {
        require(!isInitialised, "TradeStorage: Already Initialised");
        liquidationFeeUsd = _liquidationFee;
        tradingFee = _tradingFee;
        executionFee = _executionFee;
        minCollateralUsd = _minCollateralUsd;
        minBlockDelay = _minBlockDelay;
        isInitialised = true;
        emit TradeStorageInitialised(_liquidationFee, _tradingFee, _executionFee);
    }

    function updatePriceFeed(IPriceFeed _priceFeed) external onlyConfigurator {
        priceFeed = _priceFeed;
    }

    function setMinBlockDelay(uint256 _minBlockDelay) external onlyConfigurator {
        minBlockDelay = _minBlockDelay;
    }

    function setFees(uint256 _liquidationFee, uint256 _tradingFee) external onlyConfigurator {
        require(_liquidationFee <= MAX_LIQUIDATION_FEE && _liquidationFee != 0, "TradeStorage: Invalid Liquidation Fee");
        require(_tradingFee <= MAX_TRADING_FEE && _tradingFee != 0, "TradeStorage: Invalid Trading Fee");
        liquidationFeeUsd = _liquidationFee;
        tradingFee = _tradingFee;
        emit FeesSet(_liquidationFee, _tradingFee);
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
        require(!orderSet.contains(orderKey), "TradeStorage: Order Already Exists");
        // Add the Order to the Set
        orderSet.add(orderKey);
        orders[orderKey] = _request;
        // Fire Event
        emit OrderRequestCreated(orderKey, _request);
    }

    /// @dev Create a SL / TP Order or update an existing one
    function createEditOrder(Position.Conditionals memory _conditionals, bytes32 _positionKey) external onlyRouter {
        Position.Data memory position = openPositions[_positionKey];
        require(Position.exists(position), "TradeStorage: Position Doesn't Exist");
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
        require(orderKeys.contains(_orderKey), "TradeStorage: Order Doesn't Exist");
        // Remove the Order from the Set
        orderKeys.remove(_orderKey);
        delete orders[_orderKey];
        // Fire Event
        emit OrderRequestCancelled(_orderKey);
    }

    function executeCollateralIncrease(Position.Execution memory _params, Order.ExecuteCache memory _cache)
        external
        onlyProcessor
    {
        // Check the Position exists
        bytes32 positionKey = Position.generateKey(_params.request);
        Position.Data memory position = openPositions[positionKey];
        require(Position.exists(position), "TradeStorage: Position Doesn't Exist");
        // Delete the Order from Storage
        _deleteOrder(_params.orderKey, _params.request.input.isLimit);
        // Perform Execution in Library
        uint256 fundingFee;
        uint256 borrowFee;
        (position, fundingFee, borrowFee) = Order.executeCollateralIncrease(position, _params, _cache);
        // Pay Fees -> @audit - units?
        _payFees(fundingFee, borrowFee, position.isLong);
        // Update Final Storage
        openPositions[positionKey] = position;
        emit CollateralEdited(positionKey, _params.request.input.collateralDelta, _params.request.input.isIncrease);
    }

    function executeCollateralDecrease(Position.Execution memory _params, Order.ExecuteCache memory _cache)
        external
        onlyProcessor
    {
        // Check the Position exists
        bytes32 positionKey = Position.generateKey(_params.request);
        Position.Data memory position = openPositions[positionKey];
        require(Position.exists(position), "TradeStorage: Position Doesn't Exist");
        // Delete the Order from Storage
        _deleteOrder(_params.orderKey, _params.request.input.isLimit);
        // Perform Execution in Library
        uint256 fundingFee;
        uint256 borrowFee;
        (position, fundingFee, borrowFee) =
            Order.executeCollateralDecrease(position, _params, _cache, minCollateralUsd, liquidationFeeUsd);
        // Pay Fees
        _payFees(fundingFee, borrowFee, position.isLong);
        // Update Final Storage
        openPositions[positionKey] = position;
        // Transfer Tokens to User
        liquidityVault.transferOutTokens(
            _params.request.user,
            _params.request.input.collateralDelta,
            _params.request.input.isLong,
            _params.request.input.shouldWrap // @audit - should unwrap
        );
        // Fire Event
        emit CollateralEdited(positionKey, _params.request.input.collateralDelta, _params.request.input.isIncrease);
    }

    function createNewPosition(Position.Execution memory _params, Order.ExecuteCache memory _cache)
        external
        onlyProcessor
    {
        // Check the Position doesn't exist
        bytes32 positionKey = Position.generateKey(_params.request);
        require(!Position.exists(openPositions[positionKey]), "TradeStorage: Position Exists");
        // Delete the Order from Storage
        _deleteOrder(_params.orderKey, _params.request.input.isLimit);
        // Perform Execution in the Library
        (Position.Data memory position, uint256 absSizeDelta) =
            Order.createNewPosition(_params, _cache, minCollateralUsd);
        // If Request has conditionals, create the SL / TP
        (Position.Request memory stopLoss, Position.Request memory takeProfit) =
            Order.constructConditionalOrders(position, _params.request.input.conditionals, _cache.indexPrice);
        // If stop loss set, create and store the order
        if (_params.request.input.conditionals.stopLossSet) position.stopLossKey = _createStopLoss(stopLoss);
        // If take profit set, create and store the order
        if (_params.request.input.conditionals.takeProfitSet) position.takeProfitKey = _createTakeProfit(takeProfit);
        // Reserve Liquidity Equal to the Position Size
        _reserveLiquidity(absSizeDelta, _cache.collateralPrice, _cache.collateralBaseUnit, _params.request.input.isLong);
        // Update Final Storage
        openPositions[positionKey] = position;
        openPositionKeys[_params.request.market][position.isLong].add(positionKey);
        // Fire Event
        emit PositionCreated(positionKey, position);
    }

    function increaseExistingPosition(Position.Execution memory _params, Order.ExecuteCache memory _cache)
        external
        onlyProcessor
    {
        // Check the Position exists
        bytes32 positionKey = Position.generateKey(_params.request);
        Position.Data memory position = openPositions[positionKey];
        require(Position.exists(position), "TradeStorage: Position Doesn't Exist");
        // Delete the Order from Storage
        _deleteOrder(_params.orderKey, _params.request.input.isLimit);
        // Perform Execution in the Library
        uint256 sizeDeltaUsd;
        uint256 fundingFee;
        uint256 borrowFee;
        (position, sizeDeltaUsd, fundingFee, borrowFee) = Order.increaseExistingPosition(position, _params, _cache);
        // Pay Fees
        _payFees(fundingFee, borrowFee, position.isLong);
        // Reserve Liquidity Equal to the Position Size
        _reserveLiquidity(sizeDeltaUsd, _cache.collateralPrice, _cache.collateralBaseUnit, position.isLong);
        // Update Final Storage
        openPositions[positionKey] = position;
    }

    // @audit - Need to Pay the Funding Fee
    function decreaseExistingPosition(Position.Execution memory _params, Order.ExecuteCache memory _cache)
        external
        onlyProcessor
    {
        // Check the Position exists
        bytes32 positionKey = Position.generateKey(_params.request);
        Position.Data memory position = openPositions[positionKey];
        require(Position.exists(position), "TradeStorage: Position Doesn't Exist");
        // Delete the Order from Storage
        _deleteOrder(_params.orderKey, _params.request.input.isLimit);
        // If SL / TP, clear from the position
        if (_params.request.requestType == Position.RequestType.STOP_LOSS) {
            position.stopLossKey = bytes32(0);
        } else if (_params.request.requestType == Position.RequestType.TAKE_PROFIT) {
            position.takeProfitKey = bytes32(0);
        }
        // Perform Execution in the Library
        Order.DecreaseCache memory decreaseCache;
        (position, decreaseCache) =
            Order.decreaseExistingPosition(position, _params, _cache, minCollateralUsd, liquidationFeeUsd);
        // Pay Fees
        _payFees(decreaseCache.fundingFee, decreaseCache.borrowFee, position.isLong);
        // Cached to prevent multi conversion
        address market = address(position.market);
        // Reserve Liquidity Equal to the Position Size
        _unreserveLiquidity(
            _cache.sizeDeltaUsd.abs(), _cache.collateralPrice, _cache.collateralBaseUnit, position.isLong
        );
        // Update Final Storage
        openPositions[positionKey] = position;
        // Delete the Position if Full Decrease
        if (position.positionSize == 0 || position.collateralAmount == 0) {
            _deletePosition(positionKey, market, position.isLong);
        }
        // Handle PNL
        if (decreaseCache.decreasePnl < 0) {
            // Loss scenario
            uint256 lossAmount = decreaseCache.decreasePnl.abs(); // Convert the negative decreaseCache.decreasePnl to a positive value for calculations
            require(decreaseCache.afterFeeAmount >= lossAmount, "TradeStorage: Loss > Principle");

            uint256 userAmount = decreaseCache.afterFeeAmount - lossAmount;
            liquidityVault.accumulateFees(lossAmount, position.isLong);
            liquidityVault.transferOutTokens(
                _params.request.user, userAmount, _params.request.input.isLong, _params.request.input.shouldWrap
            ); // @audit - should unwrap
        } else {
            // Profit scenario
            if (decreaseCache.decreasePnl > 0) {
                decreaseCache.afterFeeAmount += decreaseCache.decreasePnl.abs();
            }
            liquidityVault.transferOutTokens(
                _params.request.user,
                decreaseCache.afterFeeAmount,
                _params.request.input.isLong,
                _params.request.input.shouldWrap
            );
        }
        // Fire Event
        emit DecreasePosition(positionKey, _params.request.input.collateralDelta, _params.request.input.sizeDelta);
    }

    /// @dev - Borrowing Fees ignored as all liquidated collateral goes to LPs
    function liquidatePosition(Order.ExecuteCache memory _cache, bytes32 _positionKey, address _liquidator)
        external
        onlyProcessor
    {
        /* Update Initial Storage */
        Position.Data memory position = openPositions[_positionKey];
        require(Position.exists(position), "TradeStorage: Position Doesn't Exist");
        require(Position.isLiquidatable(position, _cache, liquidationFeeUsd), "TradeStorage: Not Liquidatable");

        uint256 remainingCollateral = position.collateralAmount;

        // Calculate the Funding Fee and Pay off all Outstanding
        (uint256 fundingEarned, uint256 fundingOwed) = Funding.getTotalPositionFees(position, _cache);

        // Pay off Outstanding Funding Fees
        remainingCollateral -= fundingOwed;
        // Pay off Outstanding Funding Fees to Opposite Side
        liquidityVault.accumulateFundingFees(fundingOwed, !position.isLong);
        // Accumulate earned Funding Fees from Opposite Side
        liquidityVault.increaseUserClaimableFunding(fundingEarned, !position.isLong);

        // Cached to prevent double conversion
        address market = address(_cache.market);

        // delete the position from storage
        delete openPositions[_positionKey];
        openPositionKeys[market][position.isLong].remove(_positionKey);

        // unreserve all of the position liquidity
        _unreserveLiquidity(
            _cache.sizeDeltaUsd.abs(), _cache.collateralPrice, _cache.collateralBaseUnit, position.isLong
        );

        // calculate the liquidation fee to send to the liquidator
        uint256 liqFee =
            Position.calculateLiquidationFee(_cache.collateralPrice, _cache.collateralBaseUnit, liquidationFeeUsd);
        remainingCollateral -= liqFee;
        // accumulate the rest of the position size as fees
        liquidityVault.accumulateFees(remainingCollateral, position.isLong);
        // transfer the liquidation fee to the liquidator
        liquidityVault.transferOutTokens(_liquidator, liqFee, position.isLong, false);
        emit LiquidatePosition(_positionKey, _liquidator, position.collateralAmount, position.isLong);
    }

    function _createStopLoss(Position.Request memory _stopLoss) internal returns (bytes32 stopLossKey) {
        stopLossKey = Position.generateOrderKey(_stopLoss);
        limitOrderKeys.add(stopLossKey);
        orders[stopLossKey] = _stopLoss;
    }

    function _createTakeProfit(Position.Request memory _takeProfit) internal returns (bytes32 takeProfitKey) {
        takeProfitKey = Position.generateOrderKey(_takeProfit);
        limitOrderKeys.add(takeProfitKey);
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
        uint256 _sizeDeltaUsd,
        uint256 _collateralPrice,
        uint256 _collateralBaseUnit,
        bool _isLong
    ) internal {
        // Convert Size Delta USD to Collateral Tokens
        uint256 reserveDelta = (mulDiv(_sizeDeltaUsd, _collateralBaseUnit, _collateralPrice));
        liquidityVault.reserveLiquidity(reserveDelta, _isLong);
    }

    function _unreserveLiquidity(
        uint256 _sizeDeltaUsd,
        uint256 _collateralPrice,
        uint256 _collateralBaseUnit,
        bool _isLong
    ) internal {
        // Convert Size Delta USD to Collateral Tokens
        uint256 reserveDelta = (mulDiv(_sizeDeltaUsd, _collateralBaseUnit, _collateralPrice));
        liquidityVault.unreserveLiquidity(reserveDelta, _isLong);
    }

    // funding and borrow amounts should be in collateral tokens
    function _payFees(uint256 _fundingAmount, uint256 _borrowAmount, bool _isLong) internal {
        // decrease the user's reserved amount
        liquidityVault.unreserveLiquidity(_fundingAmount + _borrowAmount, _isLong);
        // increase the funding pool
        liquidityVault.accumulateFundingFees(_fundingAmount, _isLong);
        // Pay borrowing fees to LPs
        liquidityVault.accumulateFees(_borrowAmount, _isLong);
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
