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
import {IPriceOracle} from "../oracle/interfaces/IPriceOracle.sol";
import {IDataOracle} from "../oracle/interfaces/IDataOracle.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {Position} from "../positions/Position.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IMarketMaker} from "../markets/interfaces/IMarketMaker.sol";
import {MarketUtils} from "../markets/MarketUtils.sol";
import {Trade} from "./Trade.sol";

/// @dev Needs TradeStorage Role
/// @dev Need to add liquidity reservation for positions
contract TradeStorage is ITradeStorage, RoleValidation {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.Bytes32Set;

    IMarketMaker public marketMaker;
    IPriceOracle priceOracle;
    ILiquidityVault liquidityVault;
    IDataOracle dataOracle;

    uint256 constant PRECISION = 1e18;
    uint256 constant MAX_LIQUIDATION_FEE = 100e18; // 100 USD
    uint256 constant MAX_TRADING_FEE = 0.01e18; // 1%

    mapping(bytes32 _key => Position.RequestData _order) private orders;
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

    constructor(
        address _marketMaker,
        address _liquidityVault,
        address _priceOracle,
        address _dataOracle,
        address _roleStorage
    ) RoleValidation(_roleStorage) {
        marketMaker = IMarketMaker(_marketMaker);
        liquidityVault = ILiquidityVault(_liquidityVault);
        priceOracle = IPriceOracle(_priceOracle);
        dataOracle = IDataOracle(_dataOracle);
    }

    function initialise(
        uint256 _liquidationFee, // 5e18 = 5 USD
        uint256 _tradingFee, // 0.001e18 = 0.1%
        uint256 _executionFee, // 0.001 ether
        uint256 _minCollateralUsd
    ) external onlyAdmin {
        require(!isInitialised, "TS: Already Initialised");
        liquidationFeeUsd = _liquidationFee;
        tradingFee = _tradingFee;
        executionFee = _executionFee;
        minCollateralUsd = _minCollateralUsd;
        isInitialised = true;
        emit TradeStorageInitialised(_liquidationFee, _tradingFee, _executionFee);
    }

    /// @dev Adds Order to EnumerableSet
    // STACK TOO DEEP
    function createOrderRequest(Position.RequestData calldata _request) external onlyRouter {
        // Generate the Key
        bytes32 orderKey = Position.generateKey(_request);
        // Create a Storage Pointer to the Order Set
        EnumerableSet.Bytes32Set storage orderSet = _request.input.isLimit ? limitOrderKeys : marketOrderKeys;
        // Check if the Order already exists
        require(!orderSet.contains(orderKey), "TS: Order Already Exists");
        // Request the price from the oracle to be signed on the current block
        priceOracle.requestSignedPrice(_request.input.indexToken, block.timestamp);
        // Add the Order to the Set
        orderSet.add(orderKey);
        orders[orderKey] = _request;
        // Fire Event
        emit OrderRequestCreated(orderKey, _request);
    }

    function cancelOrderRequest(bytes32 _orderKey, bool _isLimit) external onlyRouterOrExecutor {
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

    function executeCollateralIncrease(Position.RequestExecution calldata _params) external onlyExecutor {
        /* Update Initial Storage */

        // Check the Position exists
        bytes32 positionKey = Position.generateKey(_params.requestData);
        Position.Data memory position = openPositions[positionKey];

        require(Position.exists(position), "TS: Position Doesn't Exist");

        // Delete the Orders from Storage
        _deleteOrder(positionKey, _params.requestData.input.isLimit);

        /* Perform Execution in Library */
        position = Trade.executeCollateralIncrease(dataOracle, position, _params);

        /* Update Final Storage */
        openPositions[positionKey] = position;
        liquidityVault.sendExecutionFee(payable(_params.feeReceiver), executionFee);
        emit CollateralEdited(
            positionKey, _params.requestData.input.collateralDelta, _params.requestData.input.isIncrease
        );
    }

    function executeCollateralDecrease(Position.RequestExecution calldata _params) external onlyExecutor {
        /* Update Initial Storage */

        // Check the Position exists
        bytes32 positionKey = Position.generateKey(_params.requestData);
        Position.Data memory position = openPositions[positionKey];

        require(Position.exists(position), "TS: Position Doesn't Exist");

        // Delete the Orders from Storage
        _deleteOrder(positionKey, _params.requestData.input.isLimit);

        /* Perform Execution in Library */

        position = Trade.executeCollateralDecrease(dataOracle, position, _params, minCollateralUsd, liquidationFeeUsd);

        /* Update Final Storage */
        openPositions[positionKey] = position;
        liquidityVault.sendExecutionFee(payable(_params.feeReceiver), executionFee);
        liquidityVault.transferOutTokens(
            address(position.market),
            _params.requestData.user,
            _params.requestData.input.collateralDelta,
            _params.requestData.input.isLong
        );
        emit CollateralEdited(
            positionKey, _params.requestData.input.collateralDelta, _params.requestData.input.isIncrease
        );
    }

    function createNewPosition(Position.RequestExecution calldata _params) external onlyExecutor {
        /* Update Initial Storage */

        bytes32 positionKey = Position.generateKey(_params.requestData);
        // Make sure the Position doesn't exist
        require(!Position.exists(openPositions[positionKey]), "TS: Position Exists");
        // Delete the Orders from Storage
        _deleteOrder(positionKey, _params.requestData.input.isLimit);

        /* Perform Execution in the Library */
        (Position.Data memory position, uint256 sizeUsd, uint256 collateralPrice) =
            Trade.createNewPosition(dataOracle, marketMaker, _params, minCollateralUsd);

        /* Update Final Storage */

        // Reserve Liquidity Equal to the Position Size
        _updateLiquidityReservation(
            positionKey,
            _params.requestData.user,
            _params.requestData.input.sizeDelta,
            sizeUsd,
            collateralPrice,
            true,
            _params.requestData.input.isLong
        );
        openPositions[positionKey] = position;
        openPositionKeys[address(position.market)][position.isLong].add(positionKey);
        liquidityVault.sendExecutionFee(payable(_params.feeReceiver), executionFee);
        // Fire Event
        emit PositionCreated(positionKey, position);
    }

    function increaseExistingPosition(Position.RequestExecution calldata _params) external onlyExecutor {
        /* Update Initial Storage */

        bytes32 positionKey = Position.generateKey(_params.requestData);
        // Check the Position exists
        Position.Data memory position = openPositions[positionKey];
        require(Position.exists(position), "TS: Position Doesn't Exist");
        // Delete the Orders from Storage
        _deleteOrder(positionKey, _params.requestData.input.isLimit);

        /* Perform Execution in the Library */
        uint256 sizeDelta;
        uint256 sizeDeltaUsd;
        (position, sizeDelta, sizeDeltaUsd) = Trade.increaseExistingPosition(dataOracle, position, _params);

        /* Update Final Storage */
        openPositions[positionKey] = position;
        _updateLiquidityReservation(
            positionKey,
            _params.requestData.user,
            sizeDelta,
            sizeDeltaUsd,
            _params.collateralPrice,
            true,
            _params.requestData.input.isLong
        );
        liquidityVault.sendExecutionFee(payable(_params.feeReceiver), executionFee);
    }

    function decreaseExistingPosition(Position.RequestExecution calldata _params) external onlyExecutorOrAdl {
        /* Update Initial Storage */

        bytes32 positionKey = Position.generateKey(_params.requestData);
        // Check the Position exists
        Position.Data memory position = openPositions[positionKey];
        require(Position.exists(position), "TS: Position Doesn't Exist");
        // Delete the Orders from Storage
        _deleteOrder(positionKey, _params.requestData.input.isLimit);

        /* Perform Execution in the Library */
        Trade.DecreaseCache memory decreaseCache;
        (position, decreaseCache) = Trade.decreaseExistingPosition(dataOracle, position, _params);

        /* Update Final Storage */
        openPositions[positionKey] = position;
        _updateLiquidityReservation(
            positionKey,
            _params.requestData.user,
            _params.requestData.input.sizeDelta,
            Position.getTradeValueUsd(
                _params.requestData.input.sizeDelta,
                _params.indexPrice,
                dataOracle.getBaseUnits(_params.requestData.input.indexToken)
            ),
            _params.collateralPrice,
            false,
            position.isLong
        );
        if (position.positionSize == 0 || position.collateralAmount == 0) {
            _deletePosition(positionKey, address(position.market), position.isLong);
        }
        if (decreaseCache.borrowFee > 0) {
            // accumulate borrow fee in liquidity vault
            liquidityVault.accumulateFees(decreaseCache.borrowFee, position.isLong);
        }
        if (decreaseCache.decreasePnl < 0) {
            // Loss scenario
            uint256 lossAmount = uint256(-decreaseCache.decreasePnl); // Convert the negative decreaseCache.decreasePnl to a positive value for calculations
            require(decreaseCache.afterFeeAmount >= lossAmount, "TS: Loss > Principle");

            uint256 userAmount = decreaseCache.afterFeeAmount - lossAmount;
            liquidityVault.accumulateFees(lossAmount, position.isLong);
            liquidityVault.transferOutTokens(
                address(position.market), _params.requestData.user, userAmount, _params.requestData.input.isLong
            );
        } else {
            // Profit scenario
            liquidityVault.transferOutTokens(
                address(position.market),
                _params.requestData.user,
                decreaseCache.afterFeeAmount,
                _params.requestData.input.isLong
            );
            if (decreaseCache.decreasePnl > 0) {
                liquidityVault.transferPositionProfit(
                    _params.requestData.user, uint256(decreaseCache.decreasePnl), _params.requestData.input.isLong
                );
            }
        }
        liquidityVault.swapFundingAmount(address(position.market), decreaseCache.fundingFee, position.isLong);
        liquidityVault.sendExecutionFee(payable(_params.feeReceiver), executionFee);

        emit DecreasePosition(
            positionKey, _params.requestData.input.collateralDelta, _params.requestData.input.sizeDelta
        );
    }

    function liquidatePosition(
        bytes32 _positionKey,
        address _liquidator,
        uint256 _collateralPrice,
        uint256 _signedBlockPrice,
        uint256 _longTokenPrice,
        uint256 _shortTokenPrice
    ) external onlyLiquidator {
        /* Update Initial Storage */
        Position.Data memory position = openPositions[_positionKey];
        require(Position.exists(position), "TS: Position Doesn't Exist");
        require(
            Position.isLiquidatable(dataOracle, position, _collateralPrice, _signedBlockPrice, liquidationFeeUsd),
            "TS: Not Liquidatable"
        );

        // Get the position fees in index tokens
        (, uint256 indexFundingFee) = Funding.getTotalPositionFees(position.market, position);
        // Convert index funding fee to collateral
        uint256 collateralfundingFee = Position.convertIndexAmountToCollateral(
            indexFundingFee,
            _signedBlockPrice,
            dataOracle.getBaseUnits(position.indexToken),
            position.isLong ? _longTokenPrice : _shortTokenPrice
        );

        // delete the position from storage
        delete openPositions[_positionKey];
        openPositionKeys[address(position.market)][position.isLong].remove(_positionKey);

        liquidityVault.liquidatePositionCollateral(
            _liquidator,
            Position.calculateLiquidationFee(priceOracle, liquidationFeeUsd, position.collateralToken),
            address(position.market),
            position.collateralAmount,
            collateralfundingFee,
            position.isLong
        );

        emit LiquidatePosition(_positionKey, _liquidator, position.collateralAmount, position.isLong);
    }

    function setFees(uint256 _liquidationFee, uint256 _tradingFee) external onlyConfigurator {
        require(_liquidationFee <= MAX_LIQUIDATION_FEE && _liquidationFee != 0, "TS: Invalid Liquidation Fee");
        require(_tradingFee <= MAX_TRADING_FEE && _tradingFee != 0, "TS: Invalid Trading Fee");
        liquidationFeeUsd = _liquidationFee;
        tradingFee = _tradingFee;
        emit FeesSet(_liquidationFee, _tradingFee);
    }

    function claimFundingFees(bytes32 _positionKey) external {
        // get the position
        Position.Data memory position = openPositions[_positionKey];
        // check that the position exists
        require(position.user != address(0), "TS: Position Doesn't Exist");
        // Check the user is the owner of the position
        require(position.user == msg.sender, "TS: Not Position Owner");
        // update the market for which the user is claiming fees
        position.market.updateFundingRate();
        // get the funding fees a user is eligible to claim for that position
        _updateFeeParameters(_positionKey);
        // if none, revert
        uint256 claimable = position.fundingParams.feesEarned;
        require(claimable != 0, "TS: No Fees To Claim");

        // Realise all fees
        openPositions[_positionKey].fundingParams.feesEarned = 0;

        liquidityVault.claimFundingFees(address(position.market), position.user, claimable, position.isLong);

        emit FundingFeesClaimed(position.user, claimable);
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

    function getOrder(bytes32 _orderKey) external view returns (Position.RequestData memory) {
        return orders[_orderKey];
    }

    function _deletePosition(bytes32 _positionKey, address _market, bool _isLong) internal {
        delete openPositions[_positionKey];
        openPositionKeys[_market][_isLong].remove(_positionKey);
    }

    function _deleteOrder(bytes32 _orderKey, bool _isLimit) internal {
        if (_isLimit) {
            limitOrderKeys.remove(_orderKey);
        } else {
            marketOrderKeys.remove(_orderKey);
        }
        delete orders[_orderKey];
    }

    function _updateFeeParameters(bytes32 _positionKey) internal {
        Position.Data storage position = openPositions[_positionKey];
        IMarket market = IMarket(position.market);
        // Borrowing Fees
        position.borrowingParams.feesOwed = Borrowing.getTotalPositionFeesOwed(market, position);
        position.borrowingParams.lastLongCumulativeBorrowFee = market.longCumulativeBorrowFees();
        position.borrowingParams.lastShortCumulativeBorrowFee = market.shortCumulativeBorrowFees();
        position.borrowingParams.lastBorrowUpdate = block.timestamp;
        // Funding Fees
        (position.fundingParams.feesEarned, position.fundingParams.feesOwed) =
            Funding.getTotalPositionFees(market, position);
        position.fundingParams.lastLongCumulativeFunding = market.longCumulativeFundingFees();
        position.fundingParams.lastShortCumulativeFunding = market.shortCumulativeFundingFees();
        position.fundingParams.lastFundingUpdate = block.timestamp;

        emit BorrowingParamsUpdated(_positionKey, position.borrowingParams);
        emit FundingParamsUpdated(_positionKey, position.fundingParams);
    }

    function _updateLiquidityReservation(
        bytes32 _positionKey,
        address _user,
        uint256 _sizeDelta,
        uint256 _sizeDeltaUsd,
        uint256 _collateralPrice,
        bool _isIncrease,
        bool _isLong
    ) internal {
        int256 reserveDelta;
        if (_isIncrease) {
            reserveDelta = int256(Math.mulDiv(_sizeDelta, PRECISION, _collateralPrice));
        } else {
            uint256 reserved = liquidityVault.reservedAmounts(_user, _isLong);
            uint256 realisedAmount = Math.mulDiv(_sizeDeltaUsd, reserved, openPositions[_positionKey].positionSize);
            reserveDelta = -int256(realisedAmount);
        }
        liquidityVault.updateReservation(_user, reserveDelta, _isLong);
    }
}
