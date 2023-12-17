// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.21;

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

/// @dev Needs TradeStorage Role
/// @dev Need to add liquidity reservation for positions
contract TradeStorage is RoleValidation {
    using SafeERC20 for IERC20;
    using SafeERC20 for IWUSDC;
    using MarketStructs for MarketStructs.Position;
    using MarketStructs for MarketStructs.PositionRequest;

    IWUSDC public immutable WUSDC;

    IPriceOracle public priceOracle;
    IMarketStorage public marketStorage;
    ILiquidityVault public liquidityVault;
    ITradeVault public tradeVault;
    IDataOracle public dataOracle;

    uint256 public constant PRECISION = 1e18;

    mapping(bool _isLimit => mapping(bytes32 _orderKey => MarketStructs.PositionRequest)) public orders;
    mapping(bool _isLimit => bytes32[] _orderKeys) public orderKeys;
    uint256 public orderKeysStartIndex;
    // Track open positions
    mapping(bytes32 _positionKey => MarketStructs.Position) public openPositions;
    mapping(bytes32 _marketKey => mapping(bool _isLong => bytes32[] _positionKeys)) public openPositionKeys;

    bool private isInitialised;

    uint256 public liquidationFeeUsd;
    uint256 public minCollateralUsd;
    uint256 public tradingFee;
    uint256 public minExecutionFee;

    event OrderRequestCreated(bytes32 _orderKey, MarketStructs.PositionRequest _positionRequest);
    event OrderRequestCancelled(bytes32 _orderKey);
    event TradeExecuted(MarketStructs.ExecutionParams _executionParams);
    event DecreaseTokenTransfer(address _user, uint256 _principle, int256 _pnl);
    event LiquidatePosition(bytes32 _positionKey, address _liquidator, uint256 _amountLiquidated, bool _isLong);
    event FeesProcessed(bytes32 _positionKey, uint256 _fundingFee, uint256 _borrowFee);
    event FundingFeesClaimed(address _user, uint256 _fundingFees);
    event TradeStorageInitialised(uint256 _liquidationFee, uint256 _tradingFee, uint256 _minExecutionFee);
    event TradingFeesSet(uint256 _liquidationFee, uint256 _tradingFee);
    event CollateralEdited(bytes32 _positionKey, uint256 _collateralDelta, bool _isIncrease);
    event IncreasePosition(bytes32 _positionKey, uint256 _collateralDelta, uint256 _sizeDelta);
    event DecreasePosition(bytes32 _positionKey, uint256 _collateralDelta, uint256 _sizeDelta);
    event DeletePositionRequest(bytes32 _positionKey, uint256 _requestIndex, bool _isLimit);
    event EditPosition(
        bytes32 _positionKey, uint256 _collateralDelta, uint256 _sizeDelta, int256 _pnlDelta, bool _isIncrease
    );
    event PositionCreated(bytes32 _positionKey, MarketStructs.Position _position);
    event FundingFeeProcessed(address _user, uint256 _fundingFee);
    event FundingParamsUpdated(bytes32 _positionKey, MarketStructs.FundingParams _fundingParams);
    event BorrowingFeesProcessed(address _user, uint256 _borrowingFee);
    event BorrowingParamsUpdated(bytes32 _positionKey, MarketStructs.BorrowParams _borrowingParams);
    event LiquidityReserved(address _user, bytes32 _positionKey, uint256 _amount, bool _isIncrease);
    event TradeStorage_StartIndexUpdated(uint256 _startIndex);

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

    /// Note Move all number initializations to an initialise function
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
        uint256 _minExecutionFee // 0.001 ether
    ) external onlyAdmin {
        if (isInitialised) revert TradeStorage_AlreadyInitialised();
        liquidationFeeUsd = _liquidationFee;
        tradingFee = _tradingFee;
        minExecutionFee = _minExecutionFee;
        isInitialised = true;
        emit TradeStorageInitialised(_liquidationFee, _tradingFee, _minExecutionFee);
    }

    function createOrderRequest(MarketStructs.PositionRequest memory _positionRequest) external onlyRouter {
        bytes32 _positionKey = TradeHelper.generateKey(_positionRequest);
        TradeHelper.validateRequest(address(this), _positionKey, _positionRequest.isLimit);
        _assignRequest(_positionKey, _positionRequest);
        emit OrderRequestCreated(_positionKey, _positionRequest);
    }

    function cancelOrderRequest(bytes32 _positionKey, bool _isLimit) external onlyRouterOrExecutor returns (bool) {
        if (orders[_isLimit][_positionKey].user == address(0)) revert TradeStorage_OrderDoesNotExist();
        delete orders[_isLimit][_positionKey];
        emit OrderRequestCancelled(_positionKey);
        return true;
    }

    function executeTrade(MarketStructs.ExecutionParams memory _executionParams) external onlyExecutor {
        if (
            orderKeys[_executionParams.positionRequest.isLimit][_executionParams.positionRequest.requestIndex]
                == bytes32(0)
        ) {
            revert TradeStorage_OrderAlreadyExecuted();
        }
        bytes32 key = TradeHelper.generateKey(_executionParams.positionRequest);

        if (_executionParams.positionRequest.sizeDelta == 0) {
            _executeCollateralEdit(_executionParams.positionRequest, _executionParams.signedBlockPrice, key);
        } else {
            _reserveLiquidity(
                _executionParams.positionRequest.user,
                key,
                _executionParams.positionRequest.sizeDelta,
                _executionParams.signedBlockPrice,
                _executionParams.positionRequest.indexToken,
                _executionParams.positionRequest.isIncrease
            );
            _executionParams.positionRequest.isIncrease
                ? _executeIncreasePosition(_executionParams.positionRequest, _executionParams.signedBlockPrice, key)
                : _executeDecreasePosition(_executionParams.positionRequest, _executionParams.signedBlockPrice, key);
        }
        _sendExecutionFee(payable(_executionParams.feeReceiver), minExecutionFee);

        // fire event to be picked up by backend and stored in DB
        emit TradeExecuted(_executionParams);
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
        address market = TradeHelper.getMarket(address(marketStorage), position.indexToken);
        (uint256 fundingFee,) = FundingCalculator.getTotalPositionFees(market, position);

        bytes32 marketKey = position.market;

        // delete the position from storage
        delete openPositions[_positionKey];

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
        emit TradingFeesSet(_liquidationFee, _tradingFee);
    }

    function claimFundingFees(bytes32 _positionKey) external {
        // get the position
        MarketStructs.Position storage position = openPositions[_positionKey];
        // check that the position exists
        if (position.user == address(0)) revert TradeStorage_PositionDoesNotExist();
        // get the funding fees a user is eligible to claim for that position
        _updateFundingParameters(_positionKey, position.indexToken);
        // if none, revert
        uint256 claimable = position.fundingParams.feesEarned;
        if (claimable == 0) revert TradeStorage_NoFeesToClaim();
        bytes32 marketKey = TradeHelper.getMarketKey(position.indexToken);

        // Realise all fees
        openPositions[_positionKey].fundingParams.feesEarned = 0;

        tradeVault.claimFundingFees(marketKey, position.user, claimable, position.isLong);

        emit FundingFeesClaimed(position.user, claimable);
    }

    function updateOrderStartIndex() external onlyExecutor {
        orderKeysStartIndex = orderKeys[false].length;
        emit TradeStorage_StartIndexUpdated(orderKeysStartIndex);
    }

    function setOrderStartIndexValue(uint256 _value) external onlyConfigurator {
        orderKeysStartIndex = _value;
    }

    function getNextPositionIndex(bytes32 _marketKey, bool _isLong) external view returns (uint256) {
        return openPositionKeys[_marketKey][_isLong].length;
    }

    function getOrderKeys() external view returns (bytes32[] memory, bytes32[] memory) {
        return (orderKeys[true], orderKeys[false]);
    }

    function getPendingMarketOrders() external view returns (bytes32[] memory) {
        uint256 totalOrders = orderKeys[false].length - orderKeysStartIndex;
        bytes32[] memory pendingOrders = new bytes32[](totalOrders);
        for (uint256 i = 0; i < totalOrders; i++) {
            pendingOrders[i] = orderKeys[false][orderKeysStartIndex + i];
        }
        return pendingOrders;
    }

    function getPositionFees(MarketStructs.Position memory _position) public view returns (uint256, uint256) {
        address market = TradeHelper.getMarket(address(marketStorage), _position.indexToken);
        uint256 borrowFee = BorrowingCalculator.getBorrowingFees(market, _position);
        return (borrowFee, liquidationFeeUsd);
    }

    function getRequestQueueLengths() public view returns (uint256, uint256) {
        return (orderKeys[false].length, orderKeys[true].length);
    }

    function _executeCollateralEdit(
        MarketStructs.PositionRequest memory _positionRequest,
        uint256 _price,
        bytes32 _positionKey
    ) internal {
        MarketStructs.Position memory position = openPositions[_positionKey];
        if (position.user == address(0)) revert TradeStorage_PositionDoesNotExist();
        // check price is correct value
        if (_price == 0) revert TradeStorage_InvalidPrice();
        _deletePositionRequest(_positionKey, _positionRequest.requestIndex, _positionRequest.isLimit);
        _updateFundingParameters(_positionKey, _positionRequest.indexToken);
        _updateBorrowingParameters(_positionKey, _positionRequest.indexToken);

        TradeHelper.checkLeverage(
            address(dataOracle),
            address(priceOracle),
            _positionRequest.indexToken,
            _price,
            position.positionSize,
            _positionRequest.isIncrease
                ? position.collateralAmount + _positionRequest.collateralDelta
                : position.collateralAmount - _positionRequest.collateralDelta
        );

        if (_positionRequest.isIncrease) {
            _editPosition(_positionRequest.collateralDelta, 0, 0, 0, true, _positionKey);
        } else {
            if (
                !TradeHelper.checkCollateralReduction(
                    position,
                    _positionRequest.collateralDelta,
                    address(priceOracle),
                    address(dataOracle),
                    address(marketStorage)
                )
            ) {
                revert TradeStorage_InvalidCollateralReduction();
            }
            _editPosition(_positionRequest.collateralDelta, 0, 0, 0, false, _positionKey);

            bytes32 marketKey = TradeHelper.getMarketKey(_positionRequest.indexToken);
            tradeVault.transferOutTokens(
                marketKey, _positionRequest.user, _positionRequest.collateralDelta, _positionRequest.isLong
            );
        }
        emit CollateralEdited(_positionKey, _positionRequest.collateralDelta, _positionRequest.isIncrease);
    }

    function _executeIncreasePosition(
        MarketStructs.PositionRequest memory _positionRequest,
        uint256 _price,
        bytes32 _positionKey
    ) internal {
        // regular increase, or new position request
        // check the request is valid
        if (_price == 0) revert TradeStorage_InvalidPrice();
        if (_positionRequest.isLimit) TradeHelper.checkLimitPrice(_price, _positionRequest);

        // if position exists, edit existing position
        _deletePositionRequest(_positionKey, _positionRequest.requestIndex, _positionRequest.isLimit);
        MarketStructs.Position memory position = openPositions[_positionKey];
        if (position.user != address(0)) {
            uint256 newCollateralAmount = position.collateralAmount + _positionRequest.collateralDelta;
            uint256 sizeDelta = (newCollateralAmount * position.positionSize) / position.collateralAmount;
            _updateFundingParameters(_positionKey, _positionRequest.indexToken);
            _updateBorrowingParameters(_positionKey, _positionRequest.indexToken);
            _editPosition(_positionRequest.collateralDelta, sizeDelta, 0, _price, true, _positionKey);
        } else {
            _createNewPosition(_positionRequest, _positionKey, _price);
        }
        emit IncreasePosition(_positionKey, _positionRequest.collateralDelta, _positionRequest.sizeDelta);
    }

    function _executeDecreasePosition(
        MarketStructs.PositionRequest memory _positionRequest,
        uint256 _price,
        bytes32 _positionKey
    ) internal {
        if (_price == 0) revert TradeStorage_InvalidPrice();
        if (_positionRequest.isLimit) TradeHelper.checkLimitPrice(_price, _positionRequest);

        _deletePositionRequest(_positionKey, _positionRequest.requestIndex, _positionRequest.isLimit);

        MarketStructs.Position storage position = openPositions[_positionKey];
        if (position.user == address(0)) revert TradeStorage_PositionDoesNotExist();

        _updateFundingParameters(_positionKey, _positionRequest.indexToken);
        _updateBorrowingParameters(_positionKey, _positionRequest.indexToken);

        uint256 afterFeeAmount = _processFees(_positionKey, _positionRequest, _price);
        uint256 sizeDelta;
        if (_positionRequest.collateralDelta == position.collateralAmount) {
            sizeDelta = position.positionSize;
        } else {
            sizeDelta = (position.positionSize * _positionRequest.collateralDelta) / position.collateralAmount;
        }
        int256 pnl = PricingCalculator.getDecreasePositionPnL(
            address(dataOracle),
            position.indexToken,
            sizeDelta,
            position.pnlParams.weightedAvgEntryPrice,
            _price,
            position.isLong
        );

        _editPosition(_positionRequest.collateralDelta, sizeDelta, pnl, _price, false, _positionKey);

        bytes32 marketKey = TradeHelper.getMarketKey(_positionRequest.indexToken);

        _handleTokenTransfers(_positionRequest, marketKey, pnl, afterFeeAmount);

        if (position.positionSize == 0) {
            _deletePosition(_positionKey, marketKey, position.isLong);
        }
        emit DecreasePosition(_positionKey, _positionRequest.collateralDelta, _positionRequest.sizeDelta);
    }

    function _handleTokenTransfers(
        MarketStructs.PositionRequest memory _positionRequest,
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
            tradeVault.transferOutTokens(_marketKey, _positionRequest.user, userAmount, _positionRequest.isLong);
        } else {
            // Profit scenario
            tradeVault.transferOutTokens(
                _marketKey, _positionRequest.user, _remainingCollateral, _positionRequest.isLong
            );
            if (_pnl > 0) {
                liquidityVault.transferPositionProfit(_positionRequest.user, uint256(_pnl));
            }
        }
        emit DecreaseTokenTransfer(_positionRequest.user, _remainingCollateral, _pnl);
    }

    function _deletePositionRequest(bytes32 _positionKey, uint256 _requestIndex, bool _isLimit) internal {
        delete orders[_isLimit][_positionKey];
        if (_isLimit) {
            delete orderKeys[_isLimit][_requestIndex];
        } else {
            delete orderKeys[_isLimit][_requestIndex];
        }
        emit DeletePositionRequest(_positionKey, _requestIndex, _isLimit);
    }

    function _deletePosition(bytes32 _positionKey, bytes32 _marketKey, bool _isLong) internal {
        delete openPositions[_positionKey];
        uint256 index = openPositions[_positionKey].index;
        if (_isLong) {
            delete openPositionKeys[_marketKey][true][index];
        } else {
            delete openPositionKeys[_marketKey][false][index];
        }
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

        if (position.positionSize > 0) {
            position.pnlParams.leverage = TradeHelper.calculateLeverage(
                address(dataOracle),
                address(priceOracle),
                position.indexToken,
                _price,
                position.positionSize,
                position.collateralAmount
            );
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

    function _createNewPosition(
        MarketStructs.PositionRequest memory _positionRequest,
        bytes32 _positionKey,
        uint256 _price
    ) internal {
        uint256 collateralPrice = priceOracle.getCollateralPrice();
        TradeHelper.checkMinCollateral(_positionRequest, collateralPrice, address(this));
        bytes32 marketKey = TradeHelper.getMarketKey(_positionRequest.indexToken);
        address market = marketStorage.markets(marketKey).market;
        MarketStructs.Position memory _position = TradeHelper.generateNewPosition(
            market, address(this), address(dataOracle), address(priceOracle), _positionRequest, _price
        );
        TradeHelper.checkLeverage(
            address(dataOracle),
            address(priceOracle),
            _positionRequest.indexToken,
            _price,
            _position.positionSize,
            _position.collateralAmount
        );

        openPositions[_positionKey] = _position;
        openPositionKeys[marketKey][_position.isLong].push(_positionKey);
        emit PositionCreated(_positionKey, _position);
    }

    function _assignRequest(bytes32 _positionKey, MarketStructs.PositionRequest memory _positionRequest) internal {
        if (_positionRequest.requestIndex != orderKeys[_positionRequest.isLimit].length) {
            revert TradeStorage_IncorrectOrderIndex();
        }
        orders[_positionRequest.isLimit][_positionKey] = _positionRequest;
        orderKeys[_positionRequest.isLimit].push(_positionKey);
    }

    function _sendExecutionFee(address payable _executor, uint256 _executionFee) internal {
        tradeVault.sendExecutionFee(_executor, _executionFee);
    }

    function _processFees(
        bytes32 _positionKey,
        MarketStructs.PositionRequest memory _positionRequest,
        uint256 _signedBlockPrice
    ) internal returns (uint256 _afterFeeAmount) {
        uint256 fundingFee = _subtractFundingFee(openPositions[_positionKey], _positionRequest.collateralDelta);
        uint256 borrowFee =
            _subtractBorrowingFee(openPositions[_positionKey], _positionRequest.collateralDelta, _signedBlockPrice);
        if (borrowFee > 0) {
            tradeVault.transferToLiquidityVault(borrowFee);
        }

        emit FeesProcessed(_positionKey, fundingFee, borrowFee);

        return _positionRequest.collateralDelta - fundingFee - borrowFee;
    }

    function _subtractFundingFee(MarketStructs.Position memory _position, uint256 _collateralDelta)
        internal
        returns (uint256)
    {
        uint256 feesOwed = _position.fundingParams.feesOwed;

        if (feesOwed > _collateralDelta) revert TradeStorage_FeeExceedsCollateralDelta();

        bytes32 marketKey = TradeHelper.getMarketKey(_position.indexToken);

        if (_position.isLong) {
            tradeVault.swapFundingAmount(marketKey, feesOwed, true);
        } else {
            tradeVault.swapFundingAmount(marketKey, feesOwed, false);
        }
        bytes32 positionKey = keccak256(abi.encodePacked(_position.indexToken, _position.user, _position.isLong));
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
        bytes32 positionKey = keccak256(abi.encodePacked(_position.indexToken, _position.user, _position.isLong));
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
