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

import {IMarket} from "../markets/interfaces/IMarket.sol";
import {ITradeStorage} from "./interfaces/ITradeStorage.sol";
import {Borrowing} from "../libraries/Borrowing.sol";
import {Funding} from "../libraries/Funding.sol";
import {mulDiv} from "@prb/math/Common.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {Pricing} from "../libraries/Pricing.sol";
import {Order} from "../positions/Order.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {console} from "forge-std/Test.sol";

/// @dev Library containing all the data types used throughout the protocol
library Position {
    using SignedMath for int256;
    using SafeCast for uint256;

    error Position_InvalidDecrease();
    error Position_SizeDelta();
    error Position_DeltaExceedsCollateral();
    error Position_LimitPriceExceeded();
    error Position_MinCollateralThreshold();
    error Position_CollateralExceedsSize();
    error Position_CollateralExceedsSizeShort();
    error Position_BelowMinLeverage();
    error Position_OverMaxLeverage();
    error Position_InvalidStopLossPercentage();
    error Position_InvalidStopLossPrice();
    error Position_InvalidTakeProfitPercentage();
    error Position_InvalidTakeProfitPrice();

    uint256 public constant MIN_LEVERAGE = 100; // 1x
    uint256 public constant LEVERAGE_PRECISION = 100;
    uint256 public constant PRECISION = 1e18;

    // Data for an Open Position
    struct Data {
        IMarket market;
        bytes32 assetId;
        address user;
        address collateralToken; // WETH long, USDC short
        uint256 collateralAmount;
        uint256 positionSize; // USD
        uint256 weightedAvgEntryPrice;
        uint256 lastUpdate;
        int256 lastFundingAccrued;
        bool isLong;
        BorrowingParams borrowingParams;
        /**
         * While SL / TPs are separate entities (decrease orders), tieing them to a position lets
         * us close them simultaneously with the position, to prevent the issue
         * of orders being left open after a position is closed.
         */
        bytes32 stopLossKey;
        bytes32 takeProfitKey;
    }

    struct BorrowingParams {
        uint256 feesOwed;
        uint256 lastLongCumulativeBorrowFee;
        uint256 lastShortCumulativeBorrowFee;
    }

    struct Conditionals {
        bool stopLossSet;
        bool takeProfitSet;
        uint256 stopLossPrice;
        uint256 takeProfitPrice;
        uint256 stopLossPercentage;
        uint256 takeProfitPercentage;
    }

    // Trade Request -> Sent by user
    struct Input {
        bytes32 assetId; // Hash of the asset ticker, e.g keccak256(abi.encode("ETH"))
        address collateralToken;
        uint256 collateralDelta;
        uint256 sizeDelta; // USD
        uint256 limitPrice;
        uint256 maxSlippage;
        uint256 executionFee;
        bool isLong;
        bool isLimit;
        bool isIncrease;
        bool shouldWrap;
        Conditionals conditionals;
    }

    // Request -> Constructed by Router based on User Input
    struct Request {
        Input input;
        address market;
        address user;
        uint256 requestBlock;
        RequestType requestType;
    }

    // Executed Request
    struct Execution {
        Request request;
        bytes32 orderKey;
        address feeReceiver;
        bool isAdl;
    }

    // Request Type Classification
    enum RequestType {
        COLLATERAL_INCREASE,
        COLLATERAL_DECREASE,
        POSITION_INCREASE,
        POSITION_DECREASE,
        CREATE_POSITION,
        STOP_LOSS,
        TAKE_PROFIT
    }

    function getRequestType(Input calldata _trade, Data memory _position)
        external
        pure
        returns (RequestType requestType)
    {
        // Case 1: Position doesn't exist (Create Position)
        if (_position.user == address(0)) {
            if (!_trade.isIncrease) revert Position_InvalidDecrease();
            if (_trade.sizeDelta == 0) revert Position_SizeDelta();
            requestType = RequestType.CREATE_POSITION;
        } else if (_trade.sizeDelta == 0) {
            // Case 2: Position exists but sizeDelta is 0 (Collateral Increase / Decrease)
            if (_trade.isIncrease) {
                requestType = RequestType.COLLATERAL_INCREASE;
            } else {
                if (_position.collateralAmount < _trade.collateralDelta) revert Position_DeltaExceedsCollateral();
                requestType = RequestType.COLLATERAL_DECREASE;
            }
        } else {
            // Case 3: Position exists and sizeDelta is not 0 (Position Increase / Decrease)
            if (_trade.sizeDelta == 0) revert Position_SizeDelta();
            if (_trade.isIncrease) {
                requestType = RequestType.POSITION_INCREASE;
            } else {
                /**
                 * Possible Size Delta & Collateral Delta can be > Size / Collateral Amount.
                 * In this case, it's a full close.
                 * Set Size Delta to = Position Size & Collateral Delta to = Collateral Amount
                 */
                requestType = RequestType.POSITION_DECREASE;
            }
        }
    }

    /// @dev Handle case where size/collateral delta > position size/collateral amount
    function checkForFullClose(Input memory _trade, Data calldata _position) external pure returns (Input memory) {
        if (_trade.sizeDelta >= _position.positionSize || _trade.collateralDelta >= _position.collateralAmount) {
            _trade.sizeDelta = _position.positionSize;
            _trade.collateralDelta = _position.collateralAmount;
        }
        return _trade;
    }

    function generateKey(Request memory _request) external pure returns (bytes32 positionKey) {
        positionKey = keccak256(abi.encode(_request.input.assetId, _request.user, _request.input.isLong));
    }

    function generateOrderKey(Request memory _request) public pure returns (bytes32 orderKey) {
        orderKey = keccak256(
            abi.encode(
                _request.input.assetId,
                _request.user,
                _request.input.isLong,
                _request.input.isIncrease, // Enables separate SL / TP Orders
                _request.input.limitPrice // Enables multiple limit orders
            )
        );
    }

    function checkLimitPrice(uint256 _price, Input memory _request) external pure {
        if (_request.isLong) {
            if (_price > _request.limitPrice) revert Position_LimitPriceExceeded();
        } else {
            if (_price < _request.limitPrice) revert Position_LimitPriceExceeded();
        }
    }

    function exists(Data memory _position) external pure returns (bool) {
        return _position.user != address(0);
    }

    // 1x = 100
    function checkLeverage(IMarket market, bytes32 _assetId, uint256 _sizeUsd, uint256 _collateralUsd) public view {
        console.log("Collateral USD: ", _collateralUsd);
        console.log("Size USD: ", _sizeUsd);
        console.logBytes32(_assetId);
        uint256 maxLeverage = market.getMaxLeverage(_assetId);
        if (_collateralUsd > _sizeUsd) revert Position_CollateralExceedsSize();
        uint256 leverage = mulDiv(_sizeUsd, LEVERAGE_PRECISION, _collateralUsd);
        console.log("Leverage: ", leverage);
        if (leverage < MIN_LEVERAGE) revert Position_BelowMinLeverage();
        if (leverage > maxLeverage) revert Position_OverMaxLeverage();
    }

    function createRequest(Input calldata _trade, address _market, address _user, RequestType _requestType)
        external
        view
        returns (Request memory request)
    {
        request = Request({
            input: _trade,
            market: _market,
            user: _user,
            requestBlock: block.number,
            requestType: _requestType
        });
    }

    function generateNewPosition(Request memory _request, Order.ExecutionState memory _state)
        external
        view
        returns (Data memory position)
    {
        // Get Entry Funding & Borrowing Values
        (uint256 longBorrowFee, uint256 shortBorrowFee) = _state.market.getCumulativeBorrowFees(_request.input.assetId);
        // get Trade Value in USD
        position = Data({
            market: _state.market,
            assetId: _request.input.assetId,
            collateralToken: _request.input.collateralToken,
            user: _request.user,
            collateralAmount: _request.input.collateralDelta,
            positionSize: _request.input.sizeDelta,
            weightedAvgEntryPrice: _state.impactedPrice,
            lastUpdate: block.timestamp,
            lastFundingAccrued: _state.market.getFundingAccrued(_request.input.assetId),
            isLong: _request.input.isLong,
            borrowingParams: BorrowingParams(0, longBorrowFee, shortBorrowFee),
            stopLossKey: bytes32(0),
            takeProfitKey: bytes32(0)
        });
    }

    function getPnl(Data memory _position, uint256 _price, uint256 _baseUnit) external pure returns (int256 pnl) {
        // Get the Entry Value (WAEP * Position Size)
        uint256 entryValue = mulDiv(_position.weightedAvgEntryPrice, _position.positionSize, _baseUnit);
        // Get the Current Value (Price * Position Size)
        uint256 currentValue = mulDiv(_price, _position.positionSize, _baseUnit);
        // Return the difference
        if (_position.isLong) {
            pnl = currentValue.toInt256() - entryValue.toInt256();
        } else {
            pnl = entryValue.toInt256() - currentValue.toInt256();
        }
    }

    function isLiquidatable(
        Position.Data memory _position,
        Order.ExecutionState memory _state,
        uint256 liquidationFeeUsd
    ) external view returns (bool) {
        uint256 collateralValueUsd = mulDiv(_position.collateralAmount, _state.collateralPrice, PRECISION);

        uint256 totalFeesOwedUsd = getTotalFeesOwedUsd(_position, _state);

        int256 pnl = Pricing.getPositionPnl(_position, _state.indexPrice, _state.indexBaseUnit);

        uint256 losses = liquidationFeeUsd + totalFeesOwedUsd;

        if (pnl < 0) {
            losses += pnl.abs();
        }
        if (collateralValueUsd <= losses) {
            return true;
        } else {
            return false;
        }
    }

    // Calculates the liquidation fee in Collateral Tokens
    function calculateLiquidationFee(uint256 _collateralPrice, uint256 _collateralBaseUnit, uint256 _liquidationFeeUsd)
        external
        pure
        returns (uint256 liquidationFee)
    {
        liquidationFee = mulDiv(_liquidationFeeUsd, _collateralBaseUnit, _collateralPrice);
    }

    // @audit - wrong order key
    function createAdlOrder(Data memory _position, uint256 _sizeDelta)
        external
        view
        returns (Execution memory execution)
    {
        // calculate collateral delta from size delta
        uint256 collateralDelta = mulDiv(_position.collateralAmount, _sizeDelta, _position.positionSize);

        Request memory request = Request({
            input: Input({
                assetId: _position.assetId,
                collateralToken: _position.collateralToken,
                collateralDelta: collateralDelta,
                sizeDelta: _sizeDelta,
                limitPrice: 0,
                maxSlippage: 0.33e18,
                executionFee: 0,
                isLong: _position.isLong,
                isLimit: false,
                isIncrease: false,
                shouldWrap: false,
                conditionals: Conditionals(false, false, 0, 0, 0, 0)
            }),
            market: address(_position.market),
            user: _position.user,
            requestBlock: block.number,
            requestType: RequestType.POSITION_DECREASE
        });
        execution =
            Execution({request: request, orderKey: generateOrderKey(request), feeReceiver: address(0), isAdl: true});
    }

    function convertIndexAmountToCollateral(
        uint256 _indexAmount,
        uint256 _indexPrice,
        uint256 _indexBaseUnit,
        uint256 _collateralPrice,
        uint256 _collateralBaseUnit
    ) external pure returns (uint256 collateralAmount) {
        uint256 indexUsd = mulDiv(_indexAmount, _indexPrice, _indexBaseUnit);
        collateralAmount = mulDiv(indexUsd, _collateralBaseUnit, _collateralPrice);
    }

    function convertUsdToCollateral(uint256 _usdAmount, uint256 _collateralPrice, uint256 _collateralBaseUnit)
        external
        pure
        returns (uint256 collateralAmount)
    {
        collateralAmount = mulDiv(_usdAmount, _collateralBaseUnit, _collateralPrice);
    }

    function getTotalFeesOwedUsd(Data memory _position, Order.ExecutionState memory _state)
        public
        view
        returns (uint256 totalFeesOwedUsd)
    {
        uint256 borrowingFeeOwed = Borrowing.getTotalCollateralFeesOwed(_position, _state);
        uint256 borrowingFeeUsd = mulDiv(borrowingFeeOwed, _state.collateralPrice, _state.collateralBaseUnit);

        totalFeesOwedUsd = borrowingFeeUsd;
    }

    // Sizes must be valid percentages
    function validateConditionals(Conditionals memory _conditionals, uint256 _referencePrice, bool _isLong)
        public
        pure
    {
        if (_conditionals.stopLossSet) {
            if (_conditionals.stopLossPercentage == 0 || _conditionals.stopLossPercentage > 1e18) {
                revert Position_InvalidStopLossPercentage();
            }
            if (_isLong) {
                if (_conditionals.stopLossPrice >= _referencePrice) revert Position_InvalidStopLossPrice();
            } else {
                if (_conditionals.stopLossPrice <= _referencePrice) revert Position_InvalidStopLossPrice();
            }
        }
        if (_conditionals.takeProfitSet) {
            if (_conditionals.takeProfitPercentage == 0 || _conditionals.takeProfitPercentage > 1e18) {
                revert Position_InvalidTakeProfitPercentage();
            }
            if (_isLong) {
                if (_conditionals.takeProfitPrice <= _referencePrice) revert Position_InvalidTakeProfitPrice();
            } else {
                if (_conditionals.takeProfitPrice >= _referencePrice) revert Position_InvalidTakeProfitPrice();
            }
        }
    }

    /**
     * Need to Check:
     * - Collateral is > min collateral
     * - Leverage is valid (1 - X)
     * - Limit price is valid -> if long, limit price < ref price, if short, limit price > ref price
     * - Conditional Prices are valid -> if long, stop loss < ref price, if short, stop loss > ref price
     * if long, take profit > ref price, if short, take profit < ref price
     */
    function validateRequest(ITradeStorage tradeStorage, Request memory _request, Order.ExecutionState memory _state)
        external
        view
    {
        // 1. Check Collateral is > Min Collateral
        console.log("Collateral Price: ", _state.collateralPrice);
        uint256 collateralUsd = _state.collateralDeltaUsd.abs();
        if (collateralUsd < tradeStorage.minCollateralUsd()) {
            revert Position_MinCollateralThreshold();
        }
        // 2. Check Leverage is valid
        // @audit - what about decrease position / collateral edits?
        if (
            _request.requestType == RequestType.POSITION_INCREASE || _request.requestType == RequestType.CREATE_POSITION
        ) {
            checkLeverage(_state.market, _request.input.assetId, _request.input.sizeDelta, collateralUsd);
        }
        // 3. Check Conditionals are valid
        validateConditionals(_request.input.conditionals, _state.indexPrice, _request.input.isLong);
    }
}
