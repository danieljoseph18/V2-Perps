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

    uint256 public constant PRECISION = 1e18;

    mapping(bytes32 _key => MarketStructs.Request _order) public orders;
    EnumerableSet.Bytes32Set private marketOrderKeys;
    EnumerableSet.Bytes32Set private limitOrderKeys;
    // Track open positions
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
    event LiquidityReserved(
        address _user, bytes32 indexed _positionKey, uint256 indexed _amount, bool indexed _isIncrease
    );
    event TradeStorage_StartIndexUpdated(uint256 indexed _startIndex);

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

    function executeTrade(MarketStructs.ExecutionParams memory _params) external onlyExecutor {
        bytes32 positionKey = TradeHelper.generateKey(_params.request);
        EnumerableSet.Bytes32Set storage orderKeys = _params.request.isLimit ? limitOrderKeys : marketOrderKeys;

        if (orderKeys.contains(positionKey)) revert TradeStorage_OrderAlreadyExecuted();

        if (_params.request.sizeDelta == 0) {
            _executeCollateralEdit(_params.request, _params.signedBlockPrice, positionKey);
        } else {
            _reserveLiquidity(
                _params.request.user,
                positionKey,
                _params.request.sizeDelta,
                _params.signedBlockPrice,
                _params.request.indexToken,
                _params.request.isIncrease
            );
            _params.request.isIncrease
                ? _executeIncreasePosition(_params.request, _params.signedBlockPrice, positionKey)
                : _executeDecreasePosition(_params.request, _params.signedBlockPrice, positionKey);
        }
        _sendExecutionFee(payable(_params.feeReceiver), executionFee);

        // fire event to be picked up by backend and stored in DB
        emit TradeExecuted(_params);
    }

    // only callable from liquidator contract
    function liquidatePosition(bytes32 _positionKey, address _liquidator, uint256 _collateralPrice)
        external
        onlyLiquidator
    {
        // check that the position exists
        MarketStructs.Position memory position = openPositions[_positionKey];
        if (position.user == address(0)) revert TradeStorage_PositionDoesNotExist();
        TradeHelper.checkIsLiquidatable(
            position, _collateralPrice, address(this), address(marketStorage), address(priceOracle), address(dataOracle)
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
        MarketStructs.Position storage position = openPositions[_positionKey];
        address user = position.user;
        // check that the position exists
        if (user == address(0)) revert TradeStorage_PositionDoesNotExist();
        // Check the user is the owner of the position
        if (user != msg.sender) revert TradeStorage_UserDoesNotOwnPosition();
        // get the funding fees a user is eligible to claim for that position
        _updateFundingParameters(_positionKey, position.indexToken);
        // if none, revert
        uint256 claimable = position.fundingParams.feesEarned;
        if (claimable == 0) revert TradeStorage_NoFeesToClaim();
        bytes32 marketKey = TradeHelper.getMarketKey(position.indexToken);

        // Realise all fees
        openPositions[_positionKey].fundingParams.feesEarned = 0;

        tradeVault.claimFundingFees(marketKey, user, claimable, position.isLong);

        emit FundingFeesClaimed(user, claimable);
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

    function _executeCollateralEdit(MarketStructs.Request memory _request, uint256 _price, bytes32 _positionKey)
        internal
    {
        if (_price == 0) revert TradeStorage_InvalidPrice();

        MarketStructs.Position storage position = openPositions[_positionKey];
        if (position.user == address(0)) revert TradeStorage_PositionDoesNotExist();

        _deleteRequest(_positionKey, _request.isLimit);

        _updateFundingParameters(_positionKey, _request.indexToken);
        _updateBorrowingParameters(_positionKey, _request.indexToken);

        if (_request.isIncrease) {
            _editPosition(_request.collateralDelta, 0, 0, 0, true, _positionKey);
        } else {
            TradeHelper.checkCollateralReduction(
                position, _request.collateralDelta, address(priceOracle), address(dataOracle), address(marketStorage)
            );
            _editPosition(_request.collateralDelta, 0, 0, 0, false, _positionKey);

            bytes32 marketKey = TradeHelper.getMarketKey(_request.indexToken);
            tradeVault.transferOutTokens(marketKey, _request.user, _request.collateralDelta, _request.isLong);
        }

        emit CollateralEdited(_positionKey, _request.collateralDelta, _request.isIncrease);
    }

    function _executeIncreasePosition(MarketStructs.Request memory _request, uint256 _price, bytes32 _positionKey)
        internal
    {
        // regular increase, or new position request
        // check the request is valid
        if (_price == 0) revert TradeStorage_InvalidPrice();
        if (_request.isLimit) TradeHelper.checkLimitPrice(_price, _request);

        // if position exists, edit existing position
        _deleteRequest(_positionKey, _request.isLimit);
        MarketStructs.Position memory position = openPositions[_positionKey];
        if (position.user != address(0)) {
            uint256 newCollateralAmount = position.collateralAmount + _request.collateralDelta;
            uint256 sizeDelta = (newCollateralAmount * position.positionSize) / position.collateralAmount;
            _updateFundingParameters(_positionKey, _request.indexToken);
            _updateBorrowingParameters(_positionKey, _request.indexToken);
            _editPosition(_request.collateralDelta, sizeDelta, 0, _price, true, _positionKey);
        } else {
            _createNewPosition(_request, _positionKey, _price);
        }
        emit IncreasePosition(_positionKey, _request.collateralDelta, _request.sizeDelta);
    }

    function _executeDecreasePosition(MarketStructs.Request memory _request, uint256 _price, bytes32 _positionKey)
        internal
    {
        if (_price == 0) revert TradeStorage_InvalidPrice();
        if (_request.isLimit) TradeHelper.checkLimitPrice(_price, _request);

        _deleteRequest(_positionKey, _request.isLimit);

        MarketStructs.Position storage position = openPositions[_positionKey];
        if (position.user == address(0)) revert TradeStorage_PositionDoesNotExist();

        _updateFundingParameters(_positionKey, _request.indexToken);
        _updateBorrowingParameters(_positionKey, _request.indexToken);

        uint256 afterFeeAmount = _processFees(_positionKey, _request, _price);
        uint256 sizeDelta;
        if (_request.collateralDelta == position.collateralAmount) {
            sizeDelta = position.positionSize;
        } else {
            sizeDelta = (position.positionSize * _request.collateralDelta) / position.collateralAmount;
        }
        int256 pnl = PricingCalculator.getDecreasePositionPnL(
            address(dataOracle),
            position.indexToken,
            sizeDelta,
            position.pnlParams.weightedAvgEntryPrice,
            _price,
            position.isLong
        );

        _editPosition(_request.collateralDelta, sizeDelta, pnl, _price, false, _positionKey);

        bytes32 marketKey = TradeHelper.getMarketKey(_request.indexToken);

        _handleTokenTransfers(_request, marketKey, pnl, afterFeeAmount);

        if (position.positionSize == 0) {
            _deletePosition(_positionKey, marketKey, position.isLong);
        }
        emit DecreasePosition(_positionKey, _request.collateralDelta, _request.sizeDelta);
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
        int256 sizeDeltaUsd =
            -1 * int256(TradeHelper.getTradeValueUsd(address(dataOracle), position.indexToken, _sizeDelta, _price));
        position.pnlParams.weightedAvgEntryPrice = PricingCalculator.calculateWeightedAverageEntryPrice(
            position.pnlParams.weightedAvgEntryPrice, position.pnlParams.sigmaIndexSizeUSD, sizeDeltaUsd, _price
        );
        position.pnlParams.sigmaIndexSizeUSD -= uint256(-sizeDeltaUsd);
        position.realisedPnl += _pnlDelta;
    }

    function _createNewPosition(MarketStructs.Request memory _request, bytes32 _positionKey, uint256 _price) internal {
        uint256 collateralPrice = priceOracle.getCollateralPrice();
        TradeHelper.checkMinCollateral(_request, collateralPrice, address(this));
        bytes32 marketKey = TradeHelper.getMarketKey(_request.indexToken);
        address market = marketStorage.markets(marketKey).market;
        MarketStructs.Position memory _position =
            TradeHelper.generateNewPosition(market, address(dataOracle), _request, _price);
        TradeHelper.checkLeverage(
            address(dataOracle),
            address(priceOracle),
            _request.indexToken,
            _price,
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

    function _updateBorrowingParameters(bytes32 _positionKey, address _indexToken) internal {
        MarketStructs.Position storage position = openPositions[_positionKey];
        address market = TradeHelper.getMarket(address(marketStorage), _indexToken);
        position.borrowParams.feesOwed = BorrowingCalculator.getBorrowingFees(market, position);
        position.borrowParams.lastLongCumulativeBorrowFee = IMarket(market).longCumulativeBorrowFee();
        position.borrowParams.lastShortCumulativeBorrowFee = IMarket(market).shortCumulativeBorrowFee();
        position.borrowParams.lastBorrowUpdate = block.timestamp;
        emit BorrowingParamsUpdated(_positionKey, position.borrowParams);
    }

    function _updateFundingParameters(bytes32 _positionKey, address _indexToken) internal {
        address market = TradeHelper.getMarket(address(marketStorage), _indexToken);

        (openPositions[_positionKey].fundingParams.feesEarned, openPositions[_positionKey].fundingParams.feesOwed) =
            FundingCalculator.getTotalPositionFees(market, openPositions[_positionKey]);

        uint256 longCumulative = IMarket(market).longCumulativeFundingFees();
        uint256 shortCumulative = IMarket(market).shortCumulativeFundingFees();

        openPositions[_positionKey].fundingParams.lastLongCumulativeFunding = longCumulative;
        openPositions[_positionKey].fundingParams.lastShortCumulativeFunding = shortCumulative;

        openPositions[_positionKey].fundingParams.lastFundingUpdate = block.timestamp;
        emit FundingParamsUpdated(_positionKey, openPositions[_positionKey].fundingParams);
    }

    function _reserveLiquidity(
        address _user,
        bytes32 _positionKey,
        uint256 _sizeDelta,
        uint256 _price,
        address _indexToken,
        bool _isIncrease
    ) internal {
        if (_isIncrease) {
            uint256 sizeDeltaUsd = TradeHelper.getTradeValueUsd(address(dataOracle), _indexToken, _sizeDelta, _price);
            uint256 wusdcAmount = (sizeDeltaUsd * PRECISION) / priceOracle.getCollateralPrice();
            liquidityVault.updateReservation(_user, int256(wusdcAmount));
        } else {
            uint256 reserved = liquidityVault.reservedAmounts(_user);
            uint256 realisedAmount = (_sizeDelta * reserved) / openPositions[_positionKey].positionSize;
            liquidityVault.updateReservation(_user, -int256(realisedAmount));
        }
        emit LiquidityReserved(_user, _positionKey, _sizeDelta, _isIncrease);
    }
}
