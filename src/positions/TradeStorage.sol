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

    constructor(address _liquidityVault, address _priceFeed, address _roleStorage) RoleValidation(_roleStorage) {
        liquidityVault = ILiquidityVault(_liquidityVault);
        priceFeed = IPriceFeed(_priceFeed);
    }

    //////////////////////////////
    // CONFIGURATIONS FUNCTIONS //
    //////////////////////////////

    function initialise(
        uint256 _liquidationFee, // 5e18 = 5 USD
        uint256 _tradingFee, // 0.001e18 = 0.1%
        uint256 _executionFee, // 0.001 ether
        uint256 _minCollateralUsd // 2e18 = 2 USD
    ) external onlyAdmin {
        require(!isInitialised, "TS: Already Initialised");
        liquidationFeeUsd = _liquidationFee;
        tradingFee = _tradingFee;
        executionFee = _executionFee;
        minCollateralUsd = _minCollateralUsd;
        isInitialised = true;
        emit TradeStorageInitialised(_liquidationFee, _tradingFee, _executionFee);
    }

    function setFees(uint256 _liquidationFee, uint256 _tradingFee) external onlyConfigurator {
        require(_liquidationFee <= MAX_LIQUIDATION_FEE && _liquidationFee != 0, "TS: Invalid Liquidation Fee");
        require(_tradingFee <= MAX_TRADING_FEE && _tradingFee != 0, "TS: Invalid Trading Fee");
        liquidationFeeUsd = _liquidationFee;
        tradingFee = _tradingFee;
        emit FeesSet(_liquidationFee, _tradingFee);
    }

    ////////////////////////////////
    // REQUEST CREATION FUNCTIONS //
    ////////////////////////////////

    /// @dev Adds Order to EnumerableSet
    // @audit - Need to distinguish between order key and position key
    // order key needs to include request type to enable simultaneous stop loss and take profit
    function createOrderRequest(Position.Request calldata _request) external onlyRouter {
        // Generate the Key
        bytes32 orderKey = Position.generateOrderKey(_request);
        // Create a Storage Pointer to the Order Set
        EnumerableSet.Bytes32Set storage orderSet = _request.input.isLimit ? limitOrderKeys : marketOrderKeys;
        // Check if the Order already exists
        require(!orderSet.contains(orderKey), "TS: Order Already Exists");
        // Add the Order to the Set
        orderSet.add(orderKey);
        orders[orderKey] = _request;
        // Fire Event
        emit OrderRequestCreated(orderKey, _request);
    }

    function cancelOrderRequest(bytes32 _orderKey, bool _isLimit) external onlyRouterOrProcessor {
        // Create a Storage Pointer to the Order Set
        EnumerableSet.Bytes32Set storage orderKeys = _isLimit ? limitOrderKeys : marketOrderKeys;
        // Check if the Order exists
        require(orderKeys.contains(_orderKey), "TS: Order Doesn't Exist");
        // Remove the Order from the Set
        orderKeys.remove(_orderKey);
        delete orders[_orderKey];
        // Fire Event
        emit OrderRequestCancelled(_orderKey);
    }

    //////////////////////////////////
    // POSITION EXECUTION FUNCTIONS //
    //////////////////////////////////

    function executeCollateralIncrease(Position.Execution memory _params, Order.ExecuteCache memory _cache)
        external
        onlyProcessor
    {
        // Check the Position exists
        bytes32 positionKey = Position.generateKey(_params.request);
        Position.Data memory position = openPositions[positionKey];
        require(Position.exists(position), "TS: Position Doesn't Exist");
        // Delete the Order from Storage
        _deleteOrder(positionKey, _params.request.input.isLimit);
        // Perform Execution in Library
        uint256 fundingFee;
        uint256 borrowFee;
        (position, fundingFee, borrowFee) = Order.executeCollateralIncrease(position, _params, _cache);
        // Pay Fees
        _payFees(_params.request.user, fundingFee, borrowFee, position.isLong);
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
        require(Position.exists(position), "TS: Position Doesn't Exist");
        // Delete the Order from Storage
        _deleteOrder(positionKey, _params.request.input.isLimit);
        // Perform Execution in Library
        uint256 fundingFee;
        uint256 borrowFee;
        (position, fundingFee, borrowFee) =
            Order.executeCollateralDecrease(position, _params, _cache, minCollateralUsd, liquidationFeeUsd);
        // Pay Fees
        _payFees(_params.request.user, fundingFee, borrowFee, position.isLong);
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
        require(!Position.exists(openPositions[positionKey]), "TS: Position Exists");
        // Delete the Order from Storage
        _deleteOrder(positionKey, _params.request.input.isLimit);
        // Perform Execution in the Library
        (Position.Data memory position, uint256 sizeUsd) = Order.createNewPosition(_params, _cache, minCollateralUsd);
        // Reserve Liquidity Equal to the Position Size
        _reserveLiquidity(_params.request.user, sizeUsd, _params.collateralPrice, _params.request.input.isLong);
        // Update Final Storage
        openPositions[positionKey] = position;
        openPositionKeys[address(position.market)][position.isLong].add(positionKey);
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
        require(Position.exists(position), "TS: Position Doesn't Exist");
        // Delete the Order from Storage
        _deleteOrder(positionKey, _params.request.input.isLimit);
        // Perform Execution in the Library
        uint256 sizeDelta;
        uint256 sizeDeltaUsd;
        uint256 fundingFee;
        uint256 borrowFee;
        (position, sizeDelta, sizeDeltaUsd, fundingFee, borrowFee) =
            Order.increaseExistingPosition(position, _params, _cache);
        // Pay Fees
        _payFees(_params.request.user, fundingFee, borrowFee, position.isLong);
        // Reserve Liquidity Equal to the Position Size
        _reserveLiquidity(_params.request.user, sizeDeltaUsd, _params.collateralPrice, position.isLong);
        // Update Final Storage
        openPositions[positionKey] = position;
    }

    // @audit - Need to Pay the Funding Fee
    function decreaseExistingPosition(Position.Execution memory _params, Order.ExecuteCache memory _cache)
        external
        onlyProcessorOrAdl
    {
        // Check the Position exists
        bytes32 positionKey = Position.generateKey(_params.request);
        Position.Data memory position = openPositions[positionKey];
        require(Position.exists(position), "TS: Position Doesn't Exist");
        // Delete the Order from Storage
        _deleteOrder(positionKey, _params.request.input.isLimit);
        // Perform Execution in the Library
        Order.DecreaseCache memory decreaseCache;
        (position, decreaseCache) = Order.decreaseExistingPosition(position, _params, _cache);
        // Pay Fees
        _payFees(_params.request.user, decreaseCache.fundingFee, decreaseCache.borrowFee, position.isLong);
        // Cached to prevent multi conversion
        address market = address(position.market);
        // Reserve Liquidity Equal to the Position Size
        _unreserveLiquidity(
            _params.request.user, _params.request.input.sizeDelta, position.positionSize, position.isLong
        );
        // Update Final Storage
        openPositions[positionKey] = position;
        // Delete the Position if Necessary
        if (position.positionSize == 0 || position.collateralAmount == 0) {
            _deletePosition(positionKey, market, position.isLong);
        }
        // Accumulate the Borrow Fees
        if (decreaseCache.borrowFee > 0) {
            // accumulate borrow fee in liquidity vault
            liquidityVault.accumulateFees(decreaseCache.borrowFee, position.isLong);
        }
        // Handle PNL
        if (decreaseCache.decreasePnl < 0) {
            // Loss scenario
            uint256 lossAmount = decreaseCache.decreasePnl.abs(); // Convert the negative decreaseCache.decreasePnl to a positive value for calculations
            require(decreaseCache.afterFeeAmount >= lossAmount, "TS: Loss > Principle");

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
        onlyLiquidator
    {
        /* Update Initial Storage */
        Position.Data memory position = openPositions[_positionKey];
        require(Position.exists(position), "TS: Position Doesn't Exist");
        require(Position.isLiquidatable(position, _cache, liquidationFeeUsd), "TS: Not Liquidatable");

        // Calculate the Funding Fee and Pay off all Outstanding

        // Cached to prevent double conversion
        address market = address(position.market);

        // delete the position from storage
        delete openPositions[_positionKey];
        openPositionKeys[market][position.isLong].remove(_positionKey);

        // unreserve all of the position liquidity

        // calculate the liquidation fee to send to the liquidator

        // accumulate the rest of the position size as fees

        // transfer the liquidation fee to the liquidator

        emit LiquidatePosition(_positionKey, _liquidator, position.collateralAmount, position.isLong);
    }

    ////////////////////////
    // INTERNAL FUNCTIONS //
    ////////////////////////

    function _deletePosition(bytes32 _positionKey, address _market, bool _isLong) internal {
        delete openPositions[_positionKey];
        openPositionKeys[_market][_isLong].remove(_positionKey);
    }

    function _deleteOrder(bytes32 _orderKey, bool _isLimit) internal {
        _isLimit ? limitOrderKeys.remove(_orderKey) : marketOrderKeys.remove(_orderKey);
        delete orders[_orderKey];
    }

    function _reserveLiquidity(address _user, uint256 _sizeDeltaUsd, uint256 _collateralPrice, bool _isLong) internal {
        // Convert Size Delta USD to Collateral Tokens
        uint256 collateralBaseUnit = _isLong ? Oracle.getLongBaseUnit(priceFeed) : Oracle.getShortBaseUnit(priceFeed);
        uint256 reserveDelta = (mulDiv(_sizeDeltaUsd, collateralBaseUnit, _collateralPrice));
        liquidityVault.reserveLiquidity(_user, reserveDelta, _isLong);
    }

    function _unreserveLiquidity(address _user, uint256 _sizeDelta, uint256 _positionSize, bool _isLong) internal {
        // Unreserve an equal proportion of the position's liquidity
        uint256 reserved = liquidityVault.reservedAmounts(_user, _isLong);
        uint256 reserveDelta = mulDiv(_sizeDelta, reserved, _positionSize);
        liquidityVault.unreserveLiquidity(_user, reserveDelta, _isLong);
    }

    function _payFees(address _user, uint256 _fundingAmount, uint256 _borrowAmount, bool _isLong) internal {
        // decrease the user's reserved amount
        liquidityVault.unreserveLiquidity(_user, _fundingAmount + _borrowAmount, _isLong);
        // increase the funding pool
        liquidityVault.accumulateFundingFees(_fundingAmount, _isLong);
        // Pay borrowing fees to LPs
        liquidityVault.accumulateFees(_borrowAmount, _isLong);
    }

    //////////////////////
    // GETTER FUNCTIONS //
    //////////////////////

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
}
