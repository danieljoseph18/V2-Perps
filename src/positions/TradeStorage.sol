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
pragma solidity 0.8.22;

import {MarketStructs} from "../markets/MarketStructs.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {IMarketStorage} from "../markets/interfaces/IMarketStorage.sol";
import {ITradeVault} from "./interfaces/ITradeVault.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ILiquidityVault} from "../markets/interfaces/ILiquidityVault.sol";
import {RoleValidation} from "../access/RoleValidation.sol";
import {ImpactCalculator} from "./ImpactCalculator.sol";
import {BorrowingCalculator} from "./BorrowingCalculator.sol";
import {FundingCalculator} from "./FundingCalculator.sol";
import {TradeHelper} from "./TradeHelper.sol";
import {PricingCalculator} from "./PricingCalculator.sol";
import {IWUSDC} from "../token/interfaces/IWUSDC.sol";
import {IPriceOracle} from "../oracle/interfaces/IPriceOracle.sol";
import {IDataOracle} from "../oracle/interfaces/IDataOracle.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/// @dev Needs TradeStorage Role
/// @dev Need to add liquidity reservation for positions
contract TradeStorage is RoleValidation {
    using SafeERC20 for IERC20;
    using SafeERC20 for IWUSDC;
    using MarketStructs for MarketStructs.Position;
    using MarketStructs for MarketStructs.Request;
    using EnumerableSet for EnumerableSet.Bytes32Set;

    IWUSDC immutable WUSDC;

    IPriceOracle priceOracle;
    IMarketStorage marketStorage;
    ILiquidityVault liquidityVault;
    ITradeVault tradeVault;
    IDataOracle dataOracle;

    uint256 constant PRECISION = 1e18;

    mapping(bytes32 _key => MarketStructs.Request _order) public orders;
    EnumerableSet.Bytes32Set private marketOrderKeys;
    EnumerableSet.Bytes32Set private limitOrderKeys;

    mapping(bytes32 _positionKey => MarketStructs.Position) public openPositions;
    mapping(bytes32 _marketKey => mapping(bool _isLong => EnumerableSet.Bytes32Set _positionKeys)) internal
        openPositionKeys;

    bool private isInitialised;

    uint256 public liquidationFeeUsd;
    uint256 public minCollateralUsd;
    uint256 public tradingFee;
    uint256 public executionFee;

    event OrderRequestCreated(bytes32 indexed _orderKey, MarketStructs.Request indexed _request);
    event OrderRequestCancelled(bytes32 indexed _orderKey);
    event TradeExecuted(MarketStructs.ExecutionParams indexed _executionParams);
    event DecreaseTokenTransfer(address indexed _user, uint256 indexed _principle, int256 indexed _pnl);
    event LiquidatePosition(
        bytes32 indexed _positionKey, address indexed _liquidator, uint256 indexed _amountLiquidated, bool _isLong
    );
    event FeesProcessed(bytes32 indexed _positionKey, uint256 indexed _fundingFee, uint256 indexed _borrowFee);
    event FundingFeesClaimed(address _user, uint256 _fundingFees);
    event TradeStorageInitialised(
        uint256 indexed _liquidationFee, uint256 indexed _tradingFee, uint256 indexed _executionFee
    );
    event FeesSet(uint256 indexed _liquidationFee, uint256 indexed _tradingFee);
    event CollateralEdited(bytes32 indexed _positionKey, uint256 indexed _collateralDelta, bool indexed _isIncrease);
    event IncreasePosition(bytes32 indexed _positionKey, uint256 indexed _collateralDelta, uint256 indexed _sizeDelta);
    event DecreasePosition(bytes32 indexed _positionKey, uint256 indexed _collateralDelta, uint256 indexed _sizeDelta);
    event DeleteRequest(bytes32 indexed _positionKey, bool indexed _isLimit);
    event EditPosition(
        bytes32 indexed _positionKey,
        uint256 indexed _collateralDelta,
        uint256 indexed _sizeDelta,
        int256 _pnlDelta,
        bool _isIncrease
    );
    event PositionCreated(bytes32 indexed _positionKey, MarketStructs.Position indexed _position);
    event FundingFeeProcessed(address indexed _user, uint256 indexed _fundingFee);
    event FundingParamsUpdated(bytes32 indexed _positionKey, MarketStructs.FundingParams indexed _fundingParams);
    event BorrowingFeesProcessed(address indexed _user, uint256 indexed _borrowingFee);
    event BorrowingParamsUpdated(bytes32 indexed _positionKey, MarketStructs.BorrowParams indexed _borrowingParams);

    error TradeStorage_OrderDoesNotExist();
    error TradeStorage_PositionDoesNotExist();
    error TradeStorage_FeeExceedsCollateralDelta();
    error TradeStorage_InvalidCollateralReduction();
    error TradeStorage_InvalidLiquidationFee();
    error TradeStorage_InvalidTradingFee();
    error TradeStorage_NoFeesToClaim();
    error TradeStorage_AlreadyInitialised();
    error TradeStorage_LossExceedsPrinciple();
    error TradeStorage_InvalidPrice();
    error TradeStorage_IncorrectOrderIndex();
    error TradeStorage_OrderAlreadyExecuted();
    error TradeStorage_RequestAlreadyExists();
    error TradeStorage_UserDoesNotOwnPosition();
    error TradeStorage_PositionAlreadyExists();

    constructor(
        address _marketStorage,
        address _liquidityVault,
        address _tradeVault,
        address _wusdc,
        address _priceOracle,
        address _dataOracle,
        address _roleStorage
    ) RoleValidation(_roleStorage) {
        marketStorage = IMarketStorage(_marketStorage);
        liquidityVault = ILiquidityVault(_liquidityVault);
        tradeVault = ITradeVault(_tradeVault);
        WUSDC = IWUSDC(_wusdc);
        priceOracle = IPriceOracle(_priceOracle);
        dataOracle = IDataOracle(_dataOracle);
    }

    function initialise(
        uint256 _liquidationFee, // 5e18 = 5 USD
        uint256 _tradingFee, // 0.001e18 = 0.1%
        uint256 _executionFee // 0.001 ether
    ) external onlyAdmin {
        if (isInitialised) revert TradeStorage_AlreadyInitialised();
        liquidationFeeUsd = _liquidationFee;
        tradingFee = _tradingFee;
        executionFee = _executionFee;
        isInitialised = true;
        emit TradeStorageInitialised(_liquidationFee, _tradingFee, _executionFee);
    }

    /// @dev Adds Order to EnumerableSet
    function createOrderRequest(MarketStructs.Request calldata _request) external onlyRouter {
        // Generate the Key
        bytes32 orderKey = TradeHelper.generateKey(_request);

        EnumerableSet.Bytes32Set storage orderSet = _request.isLimit ? limitOrderKeys : marketOrderKeys;

        if (orderSet.contains(orderKey)) {
            revert TradeStorage_RequestAlreadyExists();
        }

        priceOracle.requestSignedPrice(_request.indexToken, block.timestamp);

        orderSet.add(orderKey);
        orders[orderKey] = _request;

        emit OrderRequestCreated(orderKey, _request);
    }

    function cancelOrderRequest(bytes32 _orderKey, bool _isLimit) external onlyRouterOrExecutor {
        EnumerableSet.Bytes32Set storage orderKeys = _isLimit ? limitOrderKeys : marketOrderKeys;

        if (!orderKeys.contains(_orderKey)) revert TradeStorage_OrderDoesNotExist();

        orderKeys.remove(_orderKey);
        delete orders[_orderKey];

        emit OrderRequestCancelled(_orderKey);
    }

    function executeCollateralIncrease(MarketStructs.ExecutionParams calldata _params) external onlyExecutor {
        bytes32 positionKey = TradeHelper.generateKey(_params.request);
        _validateAndPrepareExecution(positionKey, _params);
        _editPosition(_params.request.collateralDelta, 0, 0, 0, true, positionKey);
        _sendExecutionFee(payable(_params.feeReceiver), executionFee);
        emit CollateralEdited(positionKey, _params.request.collateralDelta, _params.request.isIncrease);
    }

    function executeCollateralDecrease(MarketStructs.ExecutionParams calldata _params) external onlyExecutor {
        bytes32 positionKey = TradeHelper.generateKey(_params.request);
        _validateAndPrepareExecution(positionKey, _params);

        MarketStructs.Position memory position = openPositions[positionKey];
        if (position.collateralAmount <= _params.request.collateralDelta) {
            revert TradeStorage_InvalidCollateralReduction();
        }

        uint256 collateralPrice = priceOracle.getCollateralPrice();
        position.collateralAmount -= _params.request.collateralDelta;
        _checkIsLiquidatable(
            position, collateralPrice, address(marketStorage), address(priceOracle), address(dataOracle)
        );

        _editPosition(_params.request.collateralDelta, 0, 0, 0, false, positionKey);

        bytes32 marketKey = TradeHelper.getMarketKey(_params.request.indexToken);
        tradeVault.transferOutTokens(
            marketKey, _params.request.user, _params.request.collateralDelta, _params.request.isLong
        );

        _sendExecutionFee(payable(_params.feeReceiver), executionFee);

        emit CollateralEdited(positionKey, _params.request.collateralDelta, _params.request.isIncrease);
    }

    function createNewPosition(MarketStructs.ExecutionParams calldata _params) external onlyExecutor {
        bytes32 positionKey = TradeHelper.generateKey(_params.request);
        if (openPositions[positionKey].user != address(0)) revert TradeStorage_PositionAlreadyExists();

        _validateAndPrepareExecution(positionKey, _params);
        uint256 collateralPrice = priceOracle.getCollateralPrice();

        // reservations
        uint256 sizeDeltaUsd = TradeHelper.getTradeValueUsd(
            address(dataOracle), _params.request.indexToken, _params.request.sizeDelta, _params.signedBlockPrice
        );
        uint256 wusdcAmount = (sizeDeltaUsd * PRECISION) / collateralPrice;
        liquidityVault.updateReservation(_params.request.user, int256(wusdcAmount));

        _createNewPosition(_params.request, positionKey, _params.signedBlockPrice, collateralPrice);

        _sendExecutionFee(payable(_params.feeReceiver), executionFee);

        emit PositionCreated(positionKey, openPositions[positionKey]);
    }

    function increaseExistingPosition(MarketStructs.ExecutionParams calldata _params) external onlyExecutor {
        bytes32 positionKey = TradeHelper.generateKey(_params.request);
        _validateAndPrepareExecution(positionKey, _params);

        MarketStructs.Position memory position = openPositions[positionKey];
        uint256 newCollateralAmount = position.collateralAmount + _params.request.collateralDelta;
        uint256 sizeDelta = (newCollateralAmount * position.positionSize) / position.collateralAmount;

        // reservations
        uint256 collateralPrice = priceOracle.getCollateralPrice();
        uint256 sizeDeltaUsd = TradeHelper.getTradeValueUsd(
            address(dataOracle), _params.request.indexToken, _params.request.sizeDelta, _params.signedBlockPrice
        );
        uint256 wusdcAmount = (sizeDeltaUsd * PRECISION) / collateralPrice;
        liquidityVault.updateReservation(_params.request.user, int256(wusdcAmount));

        _editPosition(_params.request.collateralDelta, sizeDelta, 0, _params.signedBlockPrice, true, positionKey);

        _sendExecutionFee(payable(_params.feeReceiver), executionFee);

        emit IncreasePosition(positionKey, _params.request.collateralDelta, _params.request.sizeDelta);
    }

    function decreaseExistingPosition(MarketStructs.ExecutionParams calldata _params) external onlyExecutor {
        bytes32 positionKey = TradeHelper.generateKey(_params.request);
        _validateAndPrepareExecution(positionKey, _params);

        MarketStructs.Position memory position = openPositions[positionKey];

        uint256 reserved = liquidityVault.reservedAmounts(_params.request.user);
        uint256 realisedAmount = (_params.request.sizeDelta * reserved) / openPositions[positionKey].positionSize;
        liquidityVault.updateReservation(_params.request.user, -int256(realisedAmount));

        uint256 sizeDelta;
        if (_params.request.collateralDelta == position.collateralAmount) {
            sizeDelta = position.positionSize;
        } else {
            sizeDelta = (position.positionSize * _params.request.collateralDelta) / position.collateralAmount;
        }
        int256 pnl = PricingCalculator.getDecreasePositionPnL(
            address(dataOracle),
            position.indexToken,
            sizeDelta,
            position.pnlParams.weightedAvgEntryPrice,
            _params.signedBlockPrice,
            position.isLong
        );

        _editPosition(_params.request.collateralDelta, sizeDelta, pnl, _params.signedBlockPrice, false, positionKey);
        _processFeesAndTransfer(positionKey, _params, pnl);

        if (position.positionSize == 0 || position.collateralAmount == 0) {
            _deletePosition(positionKey, TradeHelper.getMarketKey(_params.request.indexToken), position.isLong);
        }

        _sendExecutionFee(payable(_params.feeReceiver), executionFee);
        emit DecreasePosition(positionKey, _params.request.collateralDelta, _params.request.sizeDelta);
    }

    function _validateAndPrepareExecution(bytes32 positionKey, MarketStructs.ExecutionParams calldata _params)
        internal
    {
        MarketStructs.Position memory position = openPositions[positionKey];
        if (position.user == address(0)) revert TradeStorage_PositionDoesNotExist();
        // check feels redundant -> revisit
        EnumerableSet.Bytes32Set storage orderKeys = _params.request.isLimit ? limitOrderKeys : marketOrderKeys;
        if (!orderKeys.contains(positionKey)) revert TradeStorage_OrderAlreadyExecuted();
        _deleteRequest(positionKey, _params.request.isLimit);
        _updateFeeParameters(positionKey, _params.request.indexToken);
    }

    function _processFeesAndTransfer(bytes32 _positionKey, MarketStructs.ExecutionParams calldata _params, int256 pnl)
        internal
    {
        uint256 afterFeeAmount = _processFees(_positionKey, _params.request, _params.signedBlockPrice);
        _handleTokenTransfers(
            _params.request, TradeHelper.getMarketKey(_params.request.indexToken), pnl, afterFeeAmount
        );
    }

    // only callable from liquidator contract
    function liquidatePosition(bytes32 _positionKey, address _liquidator, uint256 _collateralPrice)
        external
        onlyLiquidator
    {
        // check that the position exists
        MarketStructs.Position memory position = openPositions[_positionKey];
        if (position.user == address(0)) revert TradeStorage_PositionDoesNotExist();
        _checkIsLiquidatable(
            position, _collateralPrice, address(marketStorage), address(priceOracle), address(dataOracle)
        );
        // get the position fees
        address market = marketStorage.markets(position.market).market;
        (, uint256 fundingFee) = FundingCalculator.getTotalPositionFees(market, position);

        bytes32 marketKey = position.market;

        // delete the position from storage
        delete openPositions[_positionKey];
        openPositionKeys[marketKey][position.isLong].remove(_positionKey);

        uint256 liqFee = TradeHelper.calculateLiquidationFee(address(priceOracle), liquidationFeeUsd);

        tradeVault.liquidatePositionCollateral(
            _liquidator, liqFee, marketKey, position.collateralAmount, fundingFee, position.isLong
        );

        emit LiquidatePosition(_positionKey, _liquidator, position.collateralAmount, position.isLong);
    }

    function setFees(uint256 _liquidationFee, uint256 _tradingFee) external onlyConfigurator {
        if (_liquidationFee > TradeHelper.MAX_LIQUIDATION_FEE || _liquidationFee == 0) {
            revert TradeStorage_InvalidLiquidationFee();
        }
        if (_tradingFee > TradeHelper.MAX_TRADING_FEE || _tradingFee == 0) revert TradeStorage_InvalidTradingFee();
        liquidationFeeUsd = _liquidationFee;
        tradingFee = _tradingFee;
        emit FeesSet(_liquidationFee, _tradingFee);
    }

    function claimFundingFees(bytes32 _positionKey) external {
        // get the position
        MarketStructs.Position memory position = openPositions[_positionKey];
        // check that the position exists
        if (position.user == address(0)) revert TradeStorage_PositionDoesNotExist();
        // Check the user is the owner of the position
        if (position.user != msg.sender) revert TradeStorage_UserDoesNotOwnPosition();
        // get the funding fees a user is eligible to claim for that position
        _updateFeeParameters(_positionKey, position.indexToken);
        // if none, revert
        uint256 claimable = position.fundingParams.feesEarned;
        if (claimable == 0) revert TradeStorage_NoFeesToClaim();
        bytes32 marketKey = TradeHelper.getMarketKey(position.indexToken);

        // Realise all fees
        openPositions[_positionKey].fundingParams.feesEarned = 0;

        tradeVault.claimFundingFees(marketKey, position.user, claimable, position.isLong);

        emit FundingFeesClaimed(position.user, claimable);
    }

    function getOpenPositionKeys(bytes32 _marketKey, bool _isLong) external view returns (bytes32[] memory) {
        return openPositionKeys[_marketKey][_isLong].values();
    }

    function getOrderKeys(bool _isLimit) external view returns (bytes32[] memory orderKeys) {
        orderKeys = _isLimit ? limitOrderKeys.values() : marketOrderKeys.values();
    }

    function getRequestQueueLengths() external view returns (uint256 marketLen, uint256 limitLen) {
        marketLen = marketOrderKeys.length();
        limitLen = limitOrderKeys.length();
    }

    function _handleTokenTransfers(
        MarketStructs.Request memory _request,
        bytes32 _marketKey,
        int256 _pnl,
        uint256 _remainingCollateral
    ) internal {
        if (_pnl < 0) {
            // Loss scenario
            uint256 lossAmount = uint256(-_pnl); // Convert the negative PnL to a positive value for calculations
            if (_remainingCollateral < lossAmount) revert TradeStorage_LossExceedsPrinciple();

            uint256 userAmount = _remainingCollateral - lossAmount;
            tradeVault.transferToLiquidityVault(lossAmount);
            tradeVault.transferOutTokens(_marketKey, _request.user, userAmount, _request.isLong);
        } else {
            // Profit scenario
            tradeVault.transferOutTokens(_marketKey, _request.user, _remainingCollateral, _request.isLong);
            if (_pnl > 0) {
                liquidityVault.transferPositionProfit(_request.user, uint256(_pnl));
            }
        }
        emit DecreaseTokenTransfer(_request.user, _remainingCollateral, _pnl);
    }

    function _deleteRequest(bytes32 _orderKey, bool _isLimit) internal {
        delete orders[_orderKey];
        if (_isLimit) {
            limitOrderKeys.remove(_orderKey);
        } else {
            marketOrderKeys.remove(_orderKey);
        }
        emit DeleteRequest(_orderKey, _isLimit);
    }

    function _deletePosition(bytes32 _positionKey, bytes32 _marketKey, bool _isLong) internal {
        delete openPositions[_positionKey];
        openPositionKeys[_marketKey][_isLong].remove(_positionKey);
    }

    /// @dev Applies all changes to an active position
    function _editPosition(
        uint256 _collateralDelta,
        uint256 _sizeDelta,
        int256 _pnlDelta,
        uint256 _price,
        bool _isIncrease,
        bytes32 _positionKey
    ) internal {
        MarketStructs.Position storage position = openPositions[_positionKey];
        if (_isIncrease) {
            position.collateralAmount += _collateralDelta;
            if (_sizeDelta > 0) {
                _updateForIncrease(_sizeDelta, _price, position);
            }
        } else {
            position.collateralAmount -= _collateralDelta;
            if (_sizeDelta > 0) {
                _updateForDecrease(_sizeDelta, _pnlDelta, _price, position);
            }
        }

        emit EditPosition(_positionKey, _collateralDelta, _sizeDelta, _pnlDelta, _isIncrease);
    }

    function _updateForIncrease(uint256 _sizeDelta, uint256 _price, MarketStructs.Position storage position) internal {
        position.positionSize += _sizeDelta;
        uint256 sizeDeltaUsd =
            TradeHelper.getTradeValueUsd(address(dataOracle), position.indexToken, _sizeDelta, _price);
        position.pnlParams.weightedAvgEntryPrice = PricingCalculator.calculateWeightedAverageEntryPrice(
            position.pnlParams.weightedAvgEntryPrice, position.pnlParams.sigmaIndexSizeUSD, int256(sizeDeltaUsd), _price
        );
        position.pnlParams.sigmaIndexSizeUSD += sizeDeltaUsd;
    }

    function _updateForDecrease(
        uint256 _sizeDelta,
        int256 _pnlDelta,
        uint256 _price,
        MarketStructs.Position storage position
    ) internal {
        position.positionSize -= _sizeDelta;
        uint256 sizeDeltaUsd =
            TradeHelper.getTradeValueUsd(address(dataOracle), position.indexToken, _sizeDelta, _price);
        position.pnlParams.weightedAvgEntryPrice = PricingCalculator.calculateWeightedAverageEntryPrice(
            position.pnlParams.weightedAvgEntryPrice,
            position.pnlParams.sigmaIndexSizeUSD,
            -int256(sizeDeltaUsd),
            _price
        );
        position.pnlParams.sigmaIndexSizeUSD -= sizeDeltaUsd;
        position.realisedPnl += _pnlDelta;
    }

    function _createNewPosition(
        MarketStructs.Request memory _request,
        bytes32 _positionKey,
        uint256 _signedBlockPrice,
        uint256 _collateralPrice
    ) internal {
        TradeHelper.checkMinCollateral(_request, _collateralPrice, address(this));
        bytes32 marketKey = TradeHelper.getMarketKey(_request.indexToken);
        address market = marketStorage.markets(marketKey).market;
        MarketStructs.Position memory _position =
            TradeHelper.generateNewPosition(market, address(dataOracle), _request, _signedBlockPrice);
        TradeHelper.checkLeverage(
            address(dataOracle),
            address(priceOracle),
            _request.indexToken,
            _signedBlockPrice,
            _position.positionSize,
            _position.collateralAmount
        );

        openPositions[_positionKey] = _position;
        openPositionKeys[marketKey][_position.isLong].add(_positionKey);
        emit PositionCreated(_positionKey, _position);
    }

    function _sendExecutionFee(address payable _executor, uint256 _executionFee) internal {
        tradeVault.sendExecutionFee(_executor, _executionFee);
    }

    function _checkIsLiquidatable(
        MarketStructs.Position memory _position,
        uint256 _collateralPriceUsd,
        address _marketStorage,
        address _priceOracle,
        address _dataOracle
    ) public view returns (bool) {
        uint256 collateralValueUsd = (_position.collateralAmount * _collateralPriceUsd) / PRECISION;
        uint256 totalFeesOwedUsd = TradeHelper.getTotalFeesOwedUsd(_position, _collateralPriceUsd, _marketStorage);
        int256 pnl = PricingCalculator.calculatePnL(_priceOracle, _dataOracle, _position);
        int256 reminance = int256(collateralValueUsd) - int256(liquidationFeeUsd) - int256(totalFeesOwedUsd) + pnl;
        if (reminance <= 0) {
            return true;
        } else {
            return false;
        }
    }

    function _processFees(bytes32 _positionKey, MarketStructs.Request memory _request, uint256 _signedBlockPrice)
        internal
        returns (uint256 _afterFeeAmount)
    {
        uint256 fundingFee = _subtractFundingFee(openPositions[_positionKey], _request.collateralDelta);
        uint256 borrowFee =
            _subtractBorrowingFee(openPositions[_positionKey], _request.collateralDelta, _signedBlockPrice);
        if (borrowFee > 0) {
            tradeVault.transferToLiquidityVault(borrowFee);
        }

        emit FeesProcessed(_positionKey, fundingFee, borrowFee);

        return _request.collateralDelta - fundingFee - borrowFee;
    }

    function _subtractFundingFee(MarketStructs.Position memory _position, uint256 _collateralDelta)
        internal
        returns (uint256)
    {
        uint256 feesOwed = _position.fundingParams.feesOwed;

        if (feesOwed > _collateralDelta) revert TradeStorage_FeeExceedsCollateralDelta();

        bytes32 marketKey = TradeHelper.getMarketKey(_position.indexToken);

        tradeVault.swapFundingAmount(marketKey, feesOwed, _position.isLong);

        bytes32 positionKey = keccak256(abi.encode(_position.indexToken, _position.user, _position.isLong));
        openPositions[positionKey].fundingParams.feesOwed = 0;

        emit FundingFeeProcessed(_position.user, feesOwed);
        return feesOwed;
    }

    /// @dev Returns borrow fee in collateral tokens (original value is in index tokens)
    function _subtractBorrowingFee(
        MarketStructs.Position memory _position,
        uint256 _collateralDelta,
        uint256 _signedPrice
    ) internal returns (uint256 _fee) {
        address market = TradeHelper.getMarket(address(marketStorage), _position.indexToken);
        uint256 borrowFee = BorrowingCalculator.calculateBorrowingFee(market, _position, _collateralDelta);
        bytes32 positionKey = keccak256(abi.encode(_position.indexToken, _position.user, _position.isLong));
        openPositions[positionKey].borrowParams.feesOwed -= borrowFee;
        // convert borrow fee from index tokens to collateral tokens to subtract from collateral:
        uint256 borrowFeeUsd =
            TradeHelper.getTradeValueUsd(address(dataOracle), _position.indexToken, borrowFee, _signedPrice);
        uint256 collateralFee = (borrowFeeUsd * PRECISION) / priceOracle.getCollateralPrice();
        emit BorrowingFeesProcessed(_position.user, borrowFee);
        return collateralFee;
    }

    function _updateFeeParameters(bytes32 _positionKey, address _indexToken) internal {
        MarketStructs.Position storage position = openPositions[_positionKey];
        address market = TradeHelper.getMarket(address(marketStorage), _indexToken);
        // Borrowing Fees
        position.borrowParams.feesOwed = BorrowingCalculator.getBorrowingFees(market, position);
        position.borrowParams.lastLongCumulativeBorrowFee = IMarket(market).longCumulativeBorrowFee();
        position.borrowParams.lastShortCumulativeBorrowFee = IMarket(market).shortCumulativeBorrowFee();
        position.borrowParams.lastBorrowUpdate = block.timestamp;
        // Funding Fees
        (position.fundingParams.feesEarned, position.fundingParams.feesOwed) =
            FundingCalculator.getTotalPositionFees(market, position);
        position.fundingParams.lastLongCumulativeFunding = IMarket(market).longCumulativeFundingFees();
        position.fundingParams.lastShortCumulativeFunding = IMarket(market).shortCumulativeFundingFees();
        position.fundingParams.lastFundingUpdate = block.timestamp;

        emit BorrowingParamsUpdated(_positionKey, position.borrowParams);
        emit FundingParamsUpdated(_positionKey, position.fundingParams);
    }
}
