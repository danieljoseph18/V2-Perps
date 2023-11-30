// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

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

    mapping(bool _isLimit => mapping(bytes32 _orderKey => MarketStructs.PositionRequest)) public orders;
    mapping(bool _isLimit => bytes32[] _orderKeys) public orderKeys;

    // Track open positions
    mapping(bytes32 _positionKey => MarketStructs.Position) public openPositions;
    mapping(bytes32 _marketKey => mapping(bool _isLong => bytes32[] _positionKeys)) public openPositionKeys;

    mapping(address _user => uint256 _rewards) public accumulatedRewards;

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
    event ExecutionFeeSent(address _executor, uint256 _fee);
    event FeesProcessed(bytes32 _positionKey, uint256 _fundingFee, uint256 _borrowFee);
    event FundingFeesClaimed(address _user, uint256 _fundingFees);
    event TradingFeesSet(uint256 _liquidationFee, uint256 _tradingFee);

    error TradeStorage_InsufficientBalance();
    error TradeStorage_OrderDoesNotExist();
    error TradeStorage_PositionDoesNotExist();
    error TradeStorage_FeeExceedsCollateralDelta();
    error TradeStorage_InsufficientCollateralToClaim();
    error TradeStorage_InsufficientCollateral();
    error TradeStorage_InvalidCollateralReduction();
    error TradeStorage_LiquidationFeeExceedsMax();
    error TradeStorage_TradingFeeExceedsMax();
    error TradeStorage_FailedToSendExecutionFee();
    error TradeStorage_NoFeesToClaim();
    error TradeStorage_AlreadyInitialised();
    error TradeStorage_LossExceedsPrinciple();
    error TradeStorage_InvalidPrice();

    /// Note Move all number initializations to an initialise function
    constructor(
        address _marketStorage,
        address _liquidityVault,
        address _tradeVault,
        address _wusdc,
        address _priceOracle,
        address _roleStorage
    ) RoleValidation(_roleStorage) {
        marketStorage = IMarketStorage(_marketStorage);
        liquidityVault = ILiquidityVault(_liquidityVault);
        tradeVault = ITradeVault(_tradeVault);
        WUSDC = IWUSDC(_wusdc);
        priceOracle = IPriceOracle(_priceOracle);
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
    }

    function createOrderRequest(MarketStructs.PositionRequest memory _positionRequest) external onlyRouter {
        bytes32 _positionKey = TradeHelper.generateKey(_positionRequest);
        TradeHelper.validateRequest(address(this), _positionKey, _positionRequest.isLimit);
        _assignRequest(_positionKey, _positionRequest, _positionRequest.isLimit);
        emit OrderRequestCreated(_positionKey, _positionRequest);
    }

    /// Note Caller must be request creator, or keeper (after period of time)
    function cancelOrderRequest(bytes32 _positionKey, bool _isLimit) external onlyRouter {
        if (orders[_isLimit][_positionKey].user == address(0)) revert TradeStorage_OrderDoesNotExist();

        uint256 index = orders[_isLimit][_positionKey].requestIndex;
        uint256 lastIndex = orderKeys[_isLimit].length - 1;

        // Delete the order
        delete orders[_isLimit][_positionKey];

        // If the order to be deleted is not the last one, replace its slot with the last order's key
        if (index != lastIndex) {
            bytes32 lastKey = orderKeys[_isLimit][lastIndex];
            orderKeys[_isLimit][index] = lastKey;
            orders[_isLimit][lastKey].requestIndex = index; // Update the requestIndex of the order that was moved
        }

        // Remove the last key
        orderKeys[_isLimit].pop();
        emit OrderRequestCancelled(_positionKey);
    }

    function executeTrade(MarketStructs.ExecutionParams memory _executionParams)
        external
        onlyExecutor
        returns (MarketStructs.Position memory)
    {
        bytes32 key = TradeHelper.generateKey(_executionParams.positionRequest);

        uint256 price;

        if (_executionParams.positionRequest.sizeDelta == 0) {
            price = priceOracle.getCollateralPrice();
            _executeCollateralEdit(_executionParams.positionRequest, price, key);
        } else {
            price = ImpactCalculator.applyPriceImpact(
                _executionParams.signedBlockPrice, _executionParams.positionRequest.priceImpact
            );
            _executionParams.positionRequest.isIncrease
                ? _executeIncreasePosition(_executionParams.positionRequest, price, key)
                : _executeDecreasePosition(_executionParams.positionRequest, price, key);
        }
        _sendExecutionFee(_executionParams.executor, minExecutionFee);

        // fire event to be picked up by backend and stored in DB
        emit TradeExecuted(_executionParams);
        // return the edited position
        return openPositions[key];
    }

    // only callable from liquidator contract
    function liquidatePosition(bytes32 _positionKey, address _liquidator, uint256 _collateralPrice)
        external
        onlyLiquidator
    {
        // check that the position exists
        MarketStructs.Position memory position = openPositions[_positionKey];
        if (position.user == address(0)) revert TradeStorage_PositionDoesNotExist();
        TradeHelper.checkIsLiquidatable(position, _collateralPrice, address(this), address(marketStorage));
        // get the position fees
        address market = TradeHelper.getMarket(address(marketStorage), position.indexToken);
        uint256 fundingFee = FundingCalculator.getTotalPositionFeeOwed(market, position);

        bytes32 marketKey = position.market;

        // delete the position from storage
        delete openPositions[_positionKey];

        tradeVault.liquidatePositionCollateral(marketKey, position.collateralAmount, fundingFee, position.isLong);

        emit LiquidatePosition(_positionKey, _liquidator, position.collateralAmount, position.isLong);
    }

    function setFees(uint256 _liquidationFee, uint256 _tradingFee) external onlyConfigurator {
        if (_liquidationFee > TradeHelper.MAX_LIQUIDATION_FEE) revert TradeStorage_LiquidationFeeExceedsMax();
        if (_tradingFee > TradeHelper.MAX_TRADING_FEE) revert TradeStorage_TradingFeeExceedsMax();
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

    function getNextPositionIndex(bytes32 _marketKey, bool _isLong) external view returns (uint256) {
        return openPositionKeys[_marketKey][_isLong].length - 1;
    }

    function getOrderKeys() external view returns (bytes32[] memory, bytes32[] memory) {
        return (orderKeys[true], orderKeys[false]);
    }

    function getPositionFees(MarketStructs.Position memory _position) public view returns (uint256, uint256) {
        address market = TradeHelper.getMarket(address(marketStorage), _position.indexToken);
        uint256 borrowFee = IMarket(market).getBorrowingFees(_position);
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
        // check the position exists
        if (openPositions[_positionKey].user == address(0)) revert TradeStorage_PositionDoesNotExist();
        // check price is correct value
        if (_price == 0) revert TradeStorage_InvalidPrice();
        // delete the request
        _deletePositionRequest(_positionKey, _positionRequest.requestIndex, _positionRequest.isLimit);
        // get the positions current collateral and size
        uint256 currentCollateral = openPositions[_positionKey].collateralAmount;
        uint256 currentSize = openPositions[_positionKey].positionSize;
        // update the funding parameters
        _updateFundingParameters(_positionKey, _positionRequest.indexToken);

        // validate the added collateral won't push position below min leverage
        if (_positionRequest.isIncrease) {
            TradeHelper.checkLeverage(currentSize, currentCollateral + _positionRequest.collateralDelta);
            _editPosition(_positionRequest.collateralDelta, 0, 0, 0, true, _positionKey);
        } else {
            // Note check the remaining collateral is above the PNL losses + liquidaton fee (minimum collateral)
            if (
                !TradeHelper.checkCollateralReduction(
                    openPositions[_positionKey], _positionRequest.collateralDelta, _price, address(marketStorage)
                )
            ) {
                revert TradeStorage_InvalidCollateralReduction();
            }
            // validate the collateral delta won't push position above max leverage
            TradeHelper.checkLeverage(currentSize, currentCollateral - _positionRequest.collateralDelta);
            _editPosition(_positionRequest.collateralDelta, 0, 0, 0, false, _positionKey);
            // Transfer the withdrawn collateral to the user
            bytes32 marketKey = TradeHelper.getMarketKey(_positionRequest.indexToken);
            tradeVault.transferOutTokens(
                marketKey, _positionRequest.user, _positionRequest.collateralDelta, _positionRequest.isLong
            );
        }
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
        if (openPositions[_positionKey].user != address(0)) {
            // if exists, leverage must remain constant
            // calculate the size delta from the collateral delta
            // size / current collateral = leverage, +1 collateral = (+1 x leverage) size
            uint256 leverage = TradeHelper.calculateLeverage(
                openPositions[_positionKey].positionSize, openPositions[_positionKey].collateralAmount
            );
            /// @dev Leverage can be decimal -> need to scale by multiple
            uint256 sizeDelta = _positionRequest.collateralDelta * leverage;
            // add on to the position
            _editPosition(_positionRequest.collateralDelta, sizeDelta, 0, _price, true, _positionKey);
        } else {
            // Create New Position
            // Check position has sufficient collateral
            uint256 collateralPrice = priceOracle.getCollateralPrice();
            TradeHelper.checkMinCollateral(_positionRequest, collateralPrice, address(marketStorage));
            // Generate New Position
            bytes32 marketKey = TradeHelper.getMarketKey(_positionRequest.indexToken);
            address market = marketStorage.getMarket(marketKey).market;
            MarketStructs.Position memory _position =
                TradeHelper.generateNewPosition(market, address(this), _positionRequest, _price);
            // Check leverage is valid
            TradeHelper.checkLeverage(_position.positionSize, _position.collateralAmount);
            // Create Position
            _createNewPosition(_position, _positionKey, marketKey);
        }
    }

    function _executeDecreasePosition(
        MarketStructs.PositionRequest memory _positionRequest,
        uint256 _price,
        bytes32 _positionKey
    ) internal {
        if (_price == 0) revert TradeStorage_InvalidPrice();
        if (_positionRequest.isLimit) TradeHelper.checkLimitPrice(_price, _positionRequest);
        // Decrease or close position
        _deletePositionRequest(_positionKey, _positionRequest.requestIndex, _positionRequest.isLimit);
        // Check the position exists
        MarketStructs.Position storage _position = openPositions[_positionKey];
        if (_position.user == address(0)) revert TradeStorage_PositionDoesNotExist();
        // Calculate Leverage
        uint256 leverage = TradeHelper.calculateLeverage(_position.positionSize, _position.collateralAmount);

        // Process the fees for the decrease and return after fee amount
        uint256 afterFeeAmount = _processFees(_positionKey, _positionRequest);
        // SizeDelta = CollateralDelta * Leverage (Keeps Leverage Constant as Collateral is Removed)
        uint256 sizeDelta = afterFeeAmount * leverage;
        // Get PNL for SizeDelta
        int256 pnl = PricingCalculator.getDecreasePositionPnL(
            sizeDelta, _position.pnlParams.weightedAvgEntryPrice, _price, _position.isLong
        );

        _editPosition(_positionRequest.collateralDelta, sizeDelta, pnl, _price, false, _positionKey);

        bytes32 marketKey = TradeHelper.getMarketKey(_positionRequest.indexToken);

        _handleTokenTransfers(_positionRequest, marketKey, pnl, afterFeeAmount);

        if (_position.positionSize == 0) {
            _deletePosition(_positionKey, marketKey, _position.isLong);
        }
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

    // deletes a position request from storage
    function _deletePositionRequest(bytes32 _positionKey, uint256 _requestIndex, bool _isLimit) internal {
        delete orders[_isLimit][_positionKey];
        orderKeys[_isLimit][_requestIndex] = orderKeys[_isLimit][orderKeys[_isLimit].length - 1];
        orderKeys[_isLimit].pop();
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
            position.positionSize += _sizeDelta;
            uint256 sizeDeltaUsd = _sizeDelta * _price;
            position.pnlParams.weightedAvgEntryPrice = PricingCalculator.calculateWeightedAverageEntryPrice(
                position.pnlParams.weightedAvgEntryPrice,
                position.pnlParams.sigmaIndexSizeUSD,
                int256(sizeDeltaUsd),
                _price
            );
            position.pnlParams.sigmaIndexSizeUSD += sizeDeltaUsd;
            position.pnlParams.leverage =
                TradeHelper.calculateLeverage(position.positionSize, position.collateralAmount);
        } else {
            position.collateralAmount -= _collateralDelta;
            position.positionSize -= _sizeDelta;
            int256 sizeDeltaUsd = int256(_sizeDelta) * -1 * int256(_price);
            position.pnlParams.weightedAvgEntryPrice = PricingCalculator.calculateWeightedAverageEntryPrice(
                position.pnlParams.weightedAvgEntryPrice, position.pnlParams.sigmaIndexSizeUSD, sizeDeltaUsd, _price
            );
            position.pnlParams.sigmaIndexSizeUSD -= uint256(sizeDeltaUsd);
            position.realisedPnl += _pnlDelta;
            position.pnlParams.leverage =
                TradeHelper.calculateLeverage(position.positionSize, position.collateralAmount);
        }
    }

    function _createNewPosition(MarketStructs.Position memory _position, bytes32 _positionKey, bytes32 _marketKey)
        internal
    {
        openPositions[_positionKey] = _position;
        openPositionKeys[_marketKey][_position.isLong].push(_positionKey);
    }

    function _assignRequest(bytes32 _positionKey, MarketStructs.PositionRequest memory _positionRequest, bool _isLimit)
        internal
    {
        if (_isLimit) {
            orders[true][_positionKey] = _positionRequest;
            orderKeys[true].push(_positionKey);
        } else {
            orders[false][_positionKey] = _positionRequest;
            orderKeys[false].push(_positionKey);
        }
    }

    function _sendExecutionFee(address _executor, uint256 _executionFee) internal {
        if (address(this).balance < _executionFee) revert TradeStorage_InsufficientBalance();
        (bool success,) = _executor.call{value: _executionFee}("");
        if (!success) revert TradeStorage_FailedToSendExecutionFee();
        emit ExecutionFeeSent(_executor, _executionFee);
    }

    function _processFees(bytes32 _positionKey, MarketStructs.PositionRequest memory _positionRequest)
        internal
        returns (uint256 _afterFeeAmount)
    {
        uint256 fundingFee = _subtractFundingFee(openPositions[_positionKey], _positionRequest.collateralDelta);
        uint256 borrowFee = _subtractBorrowingFee(openPositions[_positionKey], _positionRequest.collateralDelta);
        if (borrowFee > 0) {
            _updateBorrowingParameters(_positionKey, borrowFee, _positionRequest.indexToken);
            tradeVault.transferToLiquidityVault(borrowFee);
        }

        emit FeesProcessed(_positionKey, fundingFee, borrowFee);

        return _positionRequest.collateralDelta - fundingFee - borrowFee;
    }

    function _subtractFundingFee(MarketStructs.Position memory _position, uint256 _collateralDelta)
        internal
        returns (uint256 _fee)
    {
        // get the funding fee owed on the position
        uint256 feesOwed = _position.fundingParams.feesOwed;
        // Note: User shouldn't be able to reduce collateral by less than the fees owed
        if (feesOwed > _collateralDelta) revert TradeStorage_FeeExceedsCollateralDelta();
        //uint256 feesOwed = unwrap(ud(earnedFundingFees) * ud(position.positionSize));
        // transfer the subtracted amount to the counterparties' liquidity
        bytes32 marketKey = TradeHelper.getMarketKey(_position.indexToken);
        // Note Need to move collateral balance storage to TradeVault
        if (_position.isLong) {
            tradeVault.swapFundingAmount(marketKey, feesOwed, true);
        } else {
            tradeVault.swapFundingAmount(marketKey, feesOwed, false);
        }
        bytes32 _positionKey = keccak256(abi.encodePacked(_position.indexToken, _position.user, _position.isLong));
        openPositions[_positionKey].fundingParams.feesOwed = 0;
        // return the collateral delta - the funding fee paid to the counterparty
        _fee = feesOwed;
    }

    function _subtractBorrowingFee(MarketStructs.Position memory _position, uint256 _collateralDelta)
        internal
        view
        returns (uint256 _fee)
    {
        address market = TradeHelper.getMarket(address(marketStorage), _position.indexToken);
        uint256 borrowFee = BorrowingCalculator.calculateBorrowingFee(market, _position, _collateralDelta);
        return borrowFee;
    }

    function _updateBorrowingParameters(bytes32 _positionKey, uint256 _feesRealised, address _indexToken) internal {
        MarketStructs.Position storage position = openPositions[_positionKey];
        address market = TradeHelper.getMarket(address(marketStorage), _indexToken);
        position.borrowParams.feesOwed -= _feesRealised;
        position.borrowParams.lastBorrowUpdate = block.timestamp;
        position.borrowParams.lastLongCumulativeBorrowFee = IMarket(market).longCumulativeBorrowFee();
        position.borrowParams.lastShortCumulativeBorrowFee = IMarket(market).shortCumulativeBorrowFee();
    }

    function _updateFundingParameters(bytes32 _positionKey, address _indexToken) internal {
        address market = TradeHelper.getMarket(address(marketStorage), _indexToken);
        // calculate funding for the position
        (uint256 earned, uint256 owed) =
            FundingCalculator.getFeesSinceLastPositionUpdate(market, openPositions[_positionKey]);

        openPositions[_positionKey].fundingParams.feesEarned += earned;
        openPositions[_positionKey].fundingParams.feesOwed += owed;

        // get current long and short cumulative funding rates
        // get market address first => then call functions to get rates
        uint256 longCumulative = IMarket(market).longCumulativeFundingFees();
        uint256 shortCumulative = IMarket(market).shortCumulativeFundingFees();

        openPositions[_positionKey].fundingParams.lastLongCumulativeFunding = longCumulative;
        openPositions[_positionKey].fundingParams.lastShortCumulativeFunding = shortCumulative;

        openPositions[_positionKey].fundingParams.lastFundingUpdate = block.timestamp;
    }
}
