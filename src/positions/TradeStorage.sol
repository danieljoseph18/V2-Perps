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

import {Types} from "../libraries/Types.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {IMarketStorage} from "../markets/interfaces/IMarketStorage.sol";
import {ITradeVault} from "./interfaces/ITradeVault.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ILiquidityVault} from "../markets/interfaces/ILiquidityVault.sol";
import {RoleValidation} from "../access/RoleValidation.sol";
import {PriceImpact} from "../libraries/PriceImpact.sol";
import {Borrowing} from "../libraries/Borrowing.sol";
import {Funding} from "../libraries/Funding.sol";
import {TradeHelper} from "./TradeHelper.sol";
import {Pricing} from "../libraries/Pricing.sol";
import {IPriceOracle} from "../oracle/interfaces/IPriceOracle.sol";
import {IDataOracle} from "../oracle/interfaces/IDataOracle.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/// @dev Needs TradeStorage Role
/// @dev Need to add liquidity reservation for positions
contract TradeStorage is RoleValidation {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.Bytes32Set;

    IPriceOracle priceOracle;
    IMarketStorage marketStorage;
    ILiquidityVault liquidityVault;
    ITradeVault tradeVault;
    IDataOracle dataOracle;

    uint256 constant PRECISION = 1e18;
    uint256 constant MAX_LIQUIDATION_FEE = 100e18; // 100 USD
    uint256 constant MAX_TRADING_FEE = 0.01e18; // 1%

    mapping(bytes32 _key => Types.Request _order) public orders;
    EnumerableSet.Bytes32Set private marketOrderKeys;
    EnumerableSet.Bytes32Set private limitOrderKeys;

    mapping(bytes32 _positionKey => Types.Position) public openPositions;
    mapping(bytes32 _marketKey => mapping(bool _isLong => EnumerableSet.Bytes32Set _positionKeys)) internal
        openPositionKeys;

    bool private isInitialised;

    uint256 public liquidationFeeUsd;
    uint256 public minCollateralUsd;
    uint256 public tradingFee;
    uint256 public executionFee;

    event OrderRequestCreated(bytes32 indexed _orderKey, Types.Request indexed _request);
    event OrderRequestCancelled(bytes32 indexed _orderKey);
    event TradeExecuted(Types.ExecutionParams indexed _executionParams);
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
    event PositionCreated(bytes32 indexed _positionKey, Types.Position indexed _position);
    event FundingFeeProcessed(address indexed _user, uint256 indexed _fundingFee);
    event FundingParamsUpdated(bytes32 indexed _positionKey, Types.Funding indexed _fundingParams);
    event BorrowingFeesProcessed(address indexed _user, uint256 indexed _borrowingFee);
    event BorrowingParamsUpdated(bytes32 indexed _positionKey, Types.Borrow indexed _borrowingParams);

    constructor(
        address _marketStorage,
        address _liquidityVault,
        address _tradeVault,
        address _priceOracle,
        address _dataOracle,
        address _roleStorage
    ) RoleValidation(_roleStorage) {
        marketStorage = IMarketStorage(_marketStorage);
        liquidityVault = ILiquidityVault(_liquidityVault);
        tradeVault = ITradeVault(_tradeVault);
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
    function createOrderRequest(Types.Request calldata _request) external onlyRouter {
        // Generate the Key
        bytes32 orderKey = TradeHelper.generateKey(_request);
        // Create a Storage Pointer to the Order Set
        EnumerableSet.Bytes32Set storage orderSet = _request.isLimit ? limitOrderKeys : marketOrderKeys;
        // Check if the Order already exists
        require(!orderSet.contains(orderKey), "TS: Order Already Exists");
        // Request the price from the oracle to be signed on the current block
        priceOracle.requestSignedPrice(_request.indexToken, block.timestamp);
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

    function executeCollateralIncrease(Types.ExecutionParams calldata _params) external onlyExecutor {
        // Generate the Key
        bytes32 positionKey = TradeHelper.generateKey(_params.request);
        _validateAndPrepareExecution(positionKey, _params, true);
        _editPosition(_params.request.collateralDelta, 0, 0, 0, _params.price, true, positionKey);
        tradeVault.sendExecutionFee(payable(_params.feeReceiver), executionFee);
        emit CollateralEdited(positionKey, _params.request.collateralDelta, _params.request.isIncrease);
    }

    function executeCollateralDecrease(Types.ExecutionParams calldata _params) external onlyExecutor {
        bytes32 positionKey = TradeHelper.generateKey(_params.request);
        _validateAndPrepareExecution(positionKey, _params, true);

        Types.Position memory position = openPositions[positionKey];

        uint256 collateralPrice = priceOracle.getCollateralPrice();
        position.collateralAmount -= _params.request.collateralDelta;

        require(_checkMinCollateral(position.collateralAmount, collateralPrice), "TS: Min Collat");

        require(
            !_checkIsLiquidatable(position, collateralPrice, _params.price, address(marketStorage), address(dataOracle)),
            "TS: Liquidatable"
        );

        _editPosition(_params.request.collateralDelta, 0, 0, 0, _params.price, false, positionKey);

        tradeVault.transferOutTokens(
            TradeHelper.getMarketKey(_params.request.indexToken),
            _params.request.user,
            _params.request.collateralDelta,
            _params.request.isLong
        );

        tradeVault.sendExecutionFee(payable(_params.feeReceiver), executionFee);

        emit CollateralEdited(positionKey, _params.request.collateralDelta, _params.request.isIncrease);
    }

    function createNewPosition(Types.ExecutionParams calldata _params) external onlyExecutor {
        bytes32 positionKey = TradeHelper.generateKey(_params.request);
        _validateAndPrepareExecution(positionKey, _params, false);

        uint256 collateralPrice = priceOracle.getCollateralPrice();
        uint256 sizeUsd = TradeHelper.getTradeValueUsd(
            address(dataOracle), _params.request.indexToken, _params.request.sizeDelta, _params.price
        );

        // Reserve Liquidity Equal to the Position Size
        _updateLiquidityReservation(
            positionKey, _params.request.user, _params.request.sizeDelta, sizeUsd, collateralPrice, true
        );
        // Check that the Position meets the minimum collateral threshold
        require(_checkMinCollateral(_params.request.collateralDelta, collateralPrice), "TS: Min Collat");
        // Generate the Position
        bytes32 marketKey = TradeHelper.getMarketKey(_params.request.indexToken);
        address market = marketStorage.markets(marketKey).market;
        Types.Position memory position =
            TradeHelper.generateNewPosition(market, address(dataOracle), _params.request, _params.price);
        // Check the Position's Leverage is Valid
        TradeHelper.checkLeverage(collateralPrice, sizeUsd, position.collateralAmount);
        // Update Storage
        openPositions[positionKey] = position;
        openPositionKeys[marketKey][position.isLong].add(positionKey);
        // Send the Execution Fee to the Executor
        tradeVault.sendExecutionFee(payable(_params.feeReceiver), executionFee);

        emit PositionCreated(positionKey, position);
    }

    function increaseExistingPosition(Types.ExecutionParams calldata _params) external onlyExecutor {
        bytes32 positionKey = TradeHelper.generateKey(_params.request);
        _validateAndPrepareExecution(positionKey, _params, true);
        // Fetch Position
        Types.Position memory position = openPositions[positionKey];
        uint256 newCollateralAmount = position.collateralAmount + _params.request.collateralDelta;
        // Calculate the Size Delta to keep Leverage Consistent
        uint256 sizeDelta = (newCollateralAmount * position.positionSize) / position.collateralAmount;
        // Reserve Liquidity Equal to the Position Size
        uint256 sizeDeltaUsd = TradeHelper.getTradeValueUsd(
            address(dataOracle), _params.request.indexToken, _params.request.sizeDelta, _params.price
        );
        _updateLiquidityReservation(
            positionKey, _params.request.user, sizeDelta, sizeDeltaUsd, priceOracle.getCollateralPrice(), true
        );
        // Update the Existing Position
        _editPosition(_params.request.collateralDelta, sizeDelta, sizeDeltaUsd, 0, _params.price, true, positionKey);
        // Send the Execution Fee to the Executor
        tradeVault.sendExecutionFee(payable(_params.feeReceiver), executionFee);

        emit IncreasePosition(positionKey, _params.request.collateralDelta, _params.request.sizeDelta);
    }

    function decreaseExistingPosition(Types.ExecutionParams calldata _params) external onlyExecutor {
        bytes32 positionKey = TradeHelper.generateKey(_params.request);
        _validateAndPrepareExecution(positionKey, _params, true);

        Types.Position memory position = openPositions[positionKey];
        uint256 collateralPrice = priceOracle.getCollateralPrice();
        _updateLiquidityReservation(
            positionKey,
            _params.request.user,
            _params.request.sizeDelta,
            TradeHelper.getTradeValueUsd(
                address(dataOracle), _params.request.indexToken, _params.request.sizeDelta, _params.price
            ),
            collateralPrice,
            false
        );

        uint256 sizeDelta;
        if (_params.request.collateralDelta == position.collateralAmount) {
            sizeDelta = position.positionSize;
        } else {
            sizeDelta = (position.positionSize * _params.request.collateralDelta) / position.collateralAmount;
        }
        int256 pnl = Pricing.getDecreasePositionPnL(
            address(dataOracle),
            position.indexToken,
            sizeDelta,
            position.pnl.weightedAvgEntryPrice,
            _params.price,
            position.isLong
        );

        _editPosition(_params.request.collateralDelta, sizeDelta, 0, pnl, _params.price, false, positionKey);
        _processFeesAndTransfer(positionKey, _params, pnl, collateralPrice);

        if (position.positionSize == 0 || position.collateralAmount == 0) {
            _deletePosition(positionKey, TradeHelper.getMarketKey(_params.request.indexToken), position.isLong);
        }

        tradeVault.sendExecutionFee(payable(_params.feeReceiver), executionFee);
        emit DecreasePosition(positionKey, _params.request.collateralDelta, _params.request.sizeDelta);
    }

    function liquidatePosition(
        bytes32 _positionKey,
        address _liquidator,
        uint256 _collateralPrice,
        uint256 _signedBlockPrice
    ) external onlyLiquidator {
        // Check that the position exists
        Types.Position memory position = openPositions[_positionKey];
        require(position.user != address(0), "TS: Position Doesn't Exist");

        // Update the market for which they are being liquidated
        IMarket(position.market).updateFundingRate();
        IMarket(position.market).updateBorrowingRate(position.isLong);
        // Check if the position is liquidatable
        require(
            _checkIsLiquidatable(
                position, _collateralPrice, _signedBlockPrice, address(marketStorage), address(dataOracle)
            ),
            "TS: Not Liquidatable"
        );
        // Get the position fees in index tokens
        (, uint256 indexFundingFee) = Funding.getTotalPositionFees(position.market, position);
        // Convert index funding fee to collateral
        uint256 collateralfundingFee = TradeHelper.convertIndexAmountToCollateral(
            address(priceOracle), indexFundingFee, _signedBlockPrice, dataOracle.getBaseUnits(position.indexToken)
        );

        // delete the position from storage
        delete openPositions[_positionKey];
        bytes32 marketKey = TradeHelper.getMarketKey(position.indexToken);
        openPositionKeys[marketKey][position.isLong].remove(_positionKey);

        tradeVault.liquidatePositionCollateral(
            _liquidator,
            TradeHelper.calculateLiquidationFee(address(priceOracle), liquidationFeeUsd),
            marketKey,
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
        Types.Position memory position = openPositions[_positionKey];
        // check that the position exists
        require(position.user != address(0), "TS: Position Doesn't Exist");
        // Check the user is the owner of the position
        require(position.user == msg.sender, "TS: Not Position Owner");
        bytes32 marketKey = TradeHelper.getMarketKey(position.indexToken);
        // update the market for which the user is claiming fees
        IMarket(position.market).updateFundingRate();
        // get the funding fees a user is eligible to claim for that position
        _updateFeeParameters(_positionKey);
        // if none, revert
        uint256 claimable = position.funding.feesEarned;
        require(claimable != 0, "TS: No Fees To Claim");

        // Realise all fees
        openPositions[_positionKey].funding.feesEarned = 0;

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

    function _deletePosition(bytes32 _positionKey, bytes32 _marketKey, bool _isLong) internal {
        delete openPositions[_positionKey];
        openPositionKeys[_marketKey][_isLong].remove(_positionKey);
    }

    /// @dev Applies all changes to an active position
    function _editPosition(
        uint256 _collateralDelta,
        uint256 _sizeDelta,
        uint256 _sizeDeltaUsd,
        int256 _pnlDelta,
        uint256 _price,
        bool _isIncrease,
        bytes32 _positionKey
    ) internal {
        // Get a storage pointer to the Position
        Types.Position storage position = openPositions[_positionKey];
        if (_isIncrease) {
            // Increase the Position's collateral
            position.collateralAmount += _collateralDelta;
            if (_sizeDelta > 0) {
                _updatePositionForIncrease(_sizeDelta, _sizeDeltaUsd, _price, position);
            }
        } else {
            position.collateralAmount -= _collateralDelta;
            if (_sizeDelta > 0) {
                _updatePositionForDecrease(_sizeDelta, _pnlDelta, _price, position);
            }
        }

        emit EditPosition(_positionKey, _collateralDelta, _sizeDelta, _pnlDelta, _isIncrease);
    }

    function _updatePositionForIncrease(
        uint256 _sizeDelta,
        uint256 _sizeDeltaUsd,
        uint256 _price,
        Types.Position storage position
    ) internal {
        position.positionSize += _sizeDelta;
        position.pnl.weightedAvgEntryPrice = Pricing.calculateWeightedAverageEntryPrice(
            position.pnl.weightedAvgEntryPrice, position.pnl.sigmaIndexSizeUSD, int256(_sizeDeltaUsd), _price
        );
        position.pnl.sigmaIndexSizeUSD += _sizeDeltaUsd;
    }

    function _updatePositionForDecrease(
        uint256 _sizeDelta,
        int256 _pnlDelta,
        uint256 _price,
        Types.Position storage position
    ) internal {
        position.positionSize -= _sizeDelta;
        uint256 sizeDeltaUsd =
            TradeHelper.getTradeValueUsd(address(dataOracle), position.indexToken, _sizeDelta, _price);
        position.pnl.weightedAvgEntryPrice = Pricing.calculateWeightedAverageEntryPrice(
            position.pnl.weightedAvgEntryPrice, position.pnl.sigmaIndexSizeUSD, -int256(sizeDeltaUsd), _price
        );
        position.pnl.sigmaIndexSizeUSD -= sizeDeltaUsd;
        position.realisedPnl += _pnlDelta;
    }

    function _validateAndPrepareExecution(
        bytes32 _positionKey,
        Types.ExecutionParams calldata _params,
        bool _positionShouldExist
    ) internal {
        if (_positionShouldExist) {
            // Check that the Position exists
            require(openPositions[_positionKey].user != address(0), "TS: Position Doesn't Exist");
            // Update the Position Fees
            _updateFeeParameters(_positionKey);
        } else {
            // Check that the Position does not exist
            require(openPositions[_positionKey].user == address(0), "TS: Position Exists");
        }
        // Delete the Request from Storage
        delete orders[_positionKey];
        if (_params.request.isLimit) {
            limitOrderKeys.remove(_positionKey);
        } else {
            marketOrderKeys.remove(_positionKey);
        }
    }

    function _processFeesAndTransfer(
        bytes32 _positionKey,
        Types.ExecutionParams calldata _params,
        int256 pnl,
        uint256 _collateralPrice
    ) internal {
        Types.Position memory position = openPositions[_positionKey];
        uint256 baseUnits = dataOracle.getBaseUnits(position.indexToken);
        uint256 fundingFee = _subtractFundingFee(
            _positionKey, position, _params.request.collateralDelta, _params.price, _collateralPrice, baseUnits
        );
        uint256 borrowFee = _subtractBorrowingFee(
            _positionKey, position, _params.request.collateralDelta, _params.price, _collateralPrice, baseUnits
        );
        if (borrowFee > 0) {
            tradeVault.transferToLiquidityVault(borrowFee);
        }

        uint256 afterFeeAmount = _params.request.collateralDelta - fundingFee - borrowFee;
        bytes32 marketKey = TradeHelper.getMarketKey(_params.request.indexToken);

        if (pnl < 0) {
            // Loss scenario
            uint256 lossAmount = uint256(-pnl); // Convert the negative PnL to a positive value for calculations
            require(afterFeeAmount >= lossAmount, "TS: Loss > Principle");

            uint256 userAmount = afterFeeAmount - lossAmount;
            tradeVault.transferToLiquidityVault(lossAmount);
            tradeVault.transferOutTokens(marketKey, _params.request.user, userAmount, _params.request.isLong);
        } else {
            // Profit scenario
            tradeVault.transferOutTokens(marketKey, _params.request.user, afterFeeAmount, _params.request.isLong);
            if (pnl > 0) {
                liquidityVault.transferPositionProfit(_params.request.user, uint256(pnl));
            }
        }
    }

    function _checkIsLiquidatable(
        Types.Position memory _position,
        uint256 _collateralPrice,
        uint256 _indexPrice,
        address _marketStorage,
        address _dataOracle
    ) public view returns (bool isLiquidatable) {
        uint256 collateralValueUsd = (_position.collateralAmount * _collateralPrice) / PRECISION;
        uint256 totalFeesOwedUsd =
            TradeHelper.getTotalFeesOwedUsd(address(dataOracle), _position, _indexPrice, _marketStorage);
        int256 pnl = Pricing.calculatePnL(_indexPrice, _dataOracle, _position);
        uint256 losses = liquidationFeeUsd + totalFeesOwedUsd;
        if (pnl < 0) {
            losses += uint256(-pnl);
        }
        if (collateralValueUsd <= losses) {
            isLiquidatable = true;
        } else {
            isLiquidatable = false;
        }
    }

    // Checks if a position meets the minimum collateral threshold
    function _checkMinCollateral(uint256 _collateralAmount, uint256 _collateralPriceUsd)
        internal
        view
        returns (bool isValid)
    {
        uint256 requestCollateralUsd = (_collateralAmount * _collateralPriceUsd) / PRECISION;
        if (requestCollateralUsd < minCollateralUsd) {
            isValid = false;
        } else {
            isValid = true;
        }
    }

    function _subtractFundingFee(
        bytes32 _positionKey,
        Types.Position memory _position,
        uint256 _collateralDelta,
        uint256 _signedPrice,
        uint256 _collateralPrice,
        uint256 _baseUnits
    ) internal returns (uint256 collateralFeesOwed) {
        uint256 feesOwedUsd = (_position.funding.feesOwed * _signedPrice) / _baseUnits;
        collateralFeesOwed = (feesOwedUsd * PRECISION) / _collateralPrice;

        require(collateralFeesOwed <= _collateralDelta, "TS: Fee > CollateralDelta");

        openPositions[_positionKey].funding.feesOwed = 0;

        tradeVault.swapFundingAmount(
            TradeHelper.getMarketKey(_position.indexToken), collateralFeesOwed, _position.isLong
        );

        emit FundingFeeProcessed(_position.user, collateralFeesOwed);
    }

    /// @dev Returns borrow fee in collateral tokens (original value is in index tokens)
    function _subtractBorrowingFee(
        bytes32 _positionKey,
        Types.Position memory _position,
        uint256 _collateralDelta,
        uint256 _signedPrice,
        uint256 _collateralPrice,
        uint256 _baseUnits
    ) internal returns (uint256 collateralFeesOwed) {
        uint256 borrowFee = Borrowing.calculateFeeForPositionChange(_position.market, _position, _collateralDelta);
        openPositions[_positionKey].borrow.feesOwed -= borrowFee;
        // convert borrow fee from index tokens to collateral tokens to subtract from collateral:
        uint256 borrowFeeUsd = (borrowFee * _signedPrice) / _baseUnits;
        collateralFeesOwed = (borrowFeeUsd * PRECISION) / _collateralPrice;
        emit BorrowingFeesProcessed(_position.user, borrowFee);
    }

    function _updateFeeParameters(bytes32 _positionKey) internal {
        Types.Position storage position = openPositions[_positionKey];
        address market = position.market;
        // Borrowing Fees
        position.borrow.feesOwed = Borrowing.getTotalPositionFeesOwed(market, position);
        position.borrow.lastLongCumulativeBorrowFee = IMarket(market).longCumulativeBorrowFees();
        position.borrow.lastShortCumulativeBorrowFee = IMarket(market).shortCumulativeBorrowFees();
        position.borrow.lastBorrowUpdate = block.timestamp;
        // Funding Fees
        (position.funding.feesEarned, position.funding.feesOwed) = Funding.getTotalPositionFees(market, position);
        position.funding.lastLongCumulativeFunding = IMarket(market).longCumulativeFundingFees();
        position.funding.lastShortCumulativeFunding = IMarket(market).shortCumulativeFundingFees();
        position.funding.lastFundingUpdate = block.timestamp;

        emit BorrowingParamsUpdated(_positionKey, position.borrow);
        emit FundingParamsUpdated(_positionKey, position.funding);
    }

    function _updateLiquidityReservation(
        bytes32 _positionKey,
        address _user,
        uint256 _sizeDelta,
        uint256 _sizeDeltaUsd,
        uint256 _collateralPrice,
        bool _isIncrease
    ) internal {
        int256 reserveDelta;
        if (_isIncrease) {
            reserveDelta = int256((_sizeDeltaUsd * PRECISION) / _collateralPrice);
        } else {
            uint256 reserved = liquidityVault.reservedAmounts(_user);
            uint256 realisedAmount = (_sizeDelta * reserved) / openPositions[_positionKey].positionSize;
            reserveDelta = -int256(realisedAmount);
        }
        liquidityVault.updateReservation(_user, reserveDelta);
    }
}
