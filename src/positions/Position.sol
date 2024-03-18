// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IMarket} from "../markets/interfaces/IMarket.sol";
import {IMarketMaker} from "../markets/interfaces/IMarketMaker.sol";
import {ITradeStorage} from "./interfaces/ITradeStorage.sol";
import {Borrowing} from "../libraries/Borrowing.sol";
import {Funding} from "../libraries/Funding.sol";
import {mulDiv} from "@prb/math/Common.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {Pricing} from "../libraries/Pricing.sol";
import {Execution} from "../positions/Execution.sol";
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
    error Position_InvalidSlippage();
    error Position_InvalidCollateralDelta();
    error Position_MarketDoesNotExist();
    error Position_InvalidLimitPrice();
    error Position_InvalidAssetId();
    error Position_InvalidConditionalPercentage();
    error Position_InvalidSizeDelta();
    error Position_UnmatchedMarkets();
    error Position_ZeroAddress();
    error Position_InvalidRequestBlock();
    error Position_NotLiquidatable();

    uint256 public constant MIN_LEVERAGE = 100; // 1x
    uint256 public constant LEVERAGE_PRECISION = 100;
    uint256 public constant PRECISION = 1e18;
    uint256 private constant MIN_SLIPPAGE = 0.0001e18; // 0.01%
    uint256 private constant MAX_SLIPPAGE = 0.9999e18; // 99.99%
    uint256 private constant MIN_COLLATERAL = 1000;

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
        bool isLong;
        FundingParams fundingParams;
        BorrowingParams borrowingParams;
        /**
         * While SL / TPs are separate entities (decrease orders), tieing them to a position lets
         * us close them simultaneously with the position, to prevent the issue
         * of orders being left open after a position is closed.
         */
        bytes32 stopLossKey;
        bytes32 takeProfitKey;
    }

    struct FundingParams {
        int256 lastFundingAccrued;
        int256 fundingOwed; // in Collateral Tokens
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
        bool reverseWrap;
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

    // Bundled Request for Execution
    struct Settlement {
        Request request;
        bytes32 orderKey;
        address feeReceiver;
        bool isAdl;
    }

    struct Adjustment {
        bytes32 orderKey;
        Conditionals conditionals;
        uint256 sizeDelta;
        uint256 collateralDelta;
        uint256 collateralIn;
        uint256 limitPrice;
        uint256 maxSlippage;
        bool isLongToken;
        bool reverseWrap;
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
                if (_trade.collateralDelta > _position.collateralAmount) revert Position_InvalidCollateralDelta();
                if (_trade.sizeDelta > _position.positionSize) revert Position_InvalidSizeDelta();
                requestType = RequestType.POSITION_DECREASE;
            }
        }
    }

    function validateInputParameters(Position.Input memory _trade, address _market)
        public
        view
        returns (bytes32 positionKey)
    {
        checkSlippage(_trade.maxSlippage);
        if (_trade.collateralDelta < MIN_COLLATERAL) revert Position_InvalidCollateralDelta();
        if (_trade.assetId == bytes32(0)) revert Position_InvalidAssetId();
        if (_market == address(0)) revert Position_MarketDoesNotExist();

        positionKey = keccak256(abi.encode(_trade.assetId, msg.sender, _trade.isLong));

        if (_trade.isLimit && _trade.limitPrice == 0) revert Position_InvalidLimitPrice();
        else if (!_trade.isLimit && _trade.limitPrice != 0) revert Position_InvalidLimitPrice();

        if (_trade.conditionals.stopLossPercentage > PRECISION) revert Position_InvalidConditionalPercentage();
        if (_trade.conditionals.takeProfitPercentage > PRECISION) revert Position_InvalidConditionalPercentage();
    }

    function checkSlippage(uint256 _maxSlippage) public pure {
        if (!(_maxSlippage >= MIN_SLIPPAGE && _maxSlippage <= MAX_SLIPPAGE)) {
            revert Position_InvalidSlippage();
        }
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
        uint256 maxLeverage = market.getMaxLeverage(_assetId);
        if (_collateralUsd > _sizeUsd) revert Position_CollateralExceedsSize();
        uint256 leverage = mulDiv(_sizeUsd, LEVERAGE_PRECISION, _collateralUsd);
        if (leverage < MIN_LEVERAGE) revert Position_BelowMinLeverage();
        console.log("Size USD: ", _sizeUsd);
        console.log("Collateral USD: ", _collateralUsd);
        console.log("Leverage: ", leverage);

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

    function generateNewPosition(Request memory _request, Execution.State memory _state)
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
            isLong: _request.input.isLong,
            fundingParams: FundingParams(_state.market.getFundingAccrued(_request.input.assetId), 0),
            borrowingParams: BorrowingParams(0, longBorrowFee, shortBorrowFee),
            stopLossKey: bytes32(0),
            takeProfitKey: bytes32(0)
        });
    }

    // SL / TP are Decrease Orders tied to a Position
    function constructConditionalOrders(Position.Data memory _position, Position.Conditionals memory _conditionals)
        external
        view
        returns (Position.Request memory stopLossOrder, Position.Request memory takeProfitOrder)
    {
        // Construct the stop loss based on the values
        if (_conditionals.stopLossSet) {
            stopLossOrder = Position.Request({
                input: Position.Input({
                    assetId: _position.assetId,
                    collateralToken: _position.collateralToken,
                    collateralDelta: mulDiv(_position.collateralAmount, _conditionals.stopLossPercentage, PRECISION),
                    sizeDelta: mulDiv(_position.positionSize, _conditionals.stopLossPercentage, PRECISION),
                    limitPrice: _conditionals.stopLossPrice,
                    maxSlippage: MAX_SLIPPAGE,
                    executionFee: 0, // @audit - how do we get user to pay for execution?
                    isLong: !_position.isLong,
                    isLimit: true,
                    isIncrease: false,
                    reverseWrap: true,
                    conditionals: Position.Conditionals({
                        stopLossSet: false,
                        stopLossPrice: 0,
                        stopLossPercentage: 0,
                        takeProfitSet: false,
                        takeProfitPrice: 0,
                        takeProfitPercentage: 0
                    })
                }),
                market: address(_position.market),
                user: _position.user,
                requestBlock: block.number,
                requestType: Position.RequestType.STOP_LOSS
            });
        }
        // Construct the Take profit based on the values
        if (_conditionals.takeProfitSet) {
            takeProfitOrder = Position.Request({
                input: Position.Input({
                    assetId: _position.assetId,
                    collateralToken: _position.collateralToken,
                    collateralDelta: mulDiv(_position.collateralAmount, _conditionals.takeProfitPercentage, PRECISION),
                    sizeDelta: mulDiv(_position.positionSize, _conditionals.takeProfitPercentage, PRECISION),
                    limitPrice: _conditionals.takeProfitPrice,
                    maxSlippage: MAX_SLIPPAGE,
                    executionFee: 0, // @audit - how do we get user to pay for execution?
                    isLong: !_position.isLong,
                    isLimit: true,
                    isIncrease: false,
                    reverseWrap: true,
                    conditionals: Position.Conditionals({
                        stopLossSet: false,
                        stopLossPrice: 0,
                        stopLossPercentage: 0,
                        takeProfitSet: false,
                        takeProfitPrice: 0,
                        takeProfitPercentage: 0
                    })
                }),
                market: address(_position.market),
                user: _position.user,
                requestBlock: block.number,
                requestType: Position.RequestType.TAKE_PROFIT
            });
        }
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

    // @audit - check math -> should never revert unless position is not liquidatable
    // should handle insolvent liqs etc.
    function liquidate(Position.Data memory _position, Execution.State memory _state, uint256 liquidationFeeUsd)
        external
        view
        returns (uint256 feesOwedToUser, uint256 feesToAccumulate, uint256 liqFeeInCollateral)
    {
        // Get the value of all collateral remaining in the position
        uint256 collateralValueUsd =
            mulDiv(_position.collateralAmount, _state.collateralPrice, _state.collateralBaseUnit);
        // Get the PNL for the position
        int256 pnl = Pricing.getPositionPnl(_position, _state.indexPrice, _state.indexBaseUnit);
        // Get the Borrow Fees Owed in USD
        uint256 borrowingFeesUsd = Borrowing.getTotalFeesOwedUsd(_position, _state);
        // Get the Funding Fees Owed in USD
        int256 fundingFeesUsd = Funding.getTotalFeesOwedUsd(_position, _state.indexPrice);
        // Calculate the total losses
        int256 losses = pnl + borrowingFeesUsd.toInt256() + fundingFeesUsd + liquidationFeeUsd.toInt256();
        // Check if the position is liquidatable
        if (losses < 0 && collateralValueUsd <= losses.abs()) {
            uint256 feesOwedToUserUsd = fundingFeesUsd > 0 ? fundingFeesUsd.abs() : 0;
            if (pnl > 0) feesOwedToUserUsd += pnl.abs();
            feesOwedToUser =
                convertUsdToCollateral(feesOwedToUserUsd, _state.collateralPrice, _state.collateralBaseUnit);
            // Convert borrowing fees owed to collateral
            feesToAccumulate =
                convertUsdToCollateral(borrowingFeesUsd, _state.collateralPrice, _state.collateralBaseUnit);
            liqFeeInCollateral =
                convertUsdToCollateral(liquidationFeeUsd, _state.collateralPrice, _state.collateralBaseUnit);
        } else {
            revert Position_NotLiquidatable();
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
        returns (Settlement memory settlement)
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
                reverseWrap: false,
                conditionals: Conditionals(false, false, 0, 0, 0, 0)
            }),
            market: address(_position.market),
            user: _position.user,
            requestBlock: block.number,
            requestType: RequestType.POSITION_DECREASE
        });
        settlement =
            Settlement({request: request, orderKey: generateOrderKey(request), feeReceiver: address(0), isAdl: true});
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
        public
        pure
        returns (uint256 collateralAmount)
    {
        collateralAmount = mulDiv(_usdAmount, _collateralBaseUnit, _collateralPrice);
    }

    function getTotalFeesOwedUsd(Data memory _position, Execution.State memory _state)
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
        returns (Conditionals memory)
    {
        // Check the Validity of the Stop Loss / Take Profit
        bool stopLossValid = true;
        bool takeProfitValid = true;
        if (_conditionals.stopLossSet) {
            if (_conditionals.stopLossPercentage == 0 || _conditionals.stopLossPercentage > PRECISION) {
                stopLossValid = false;
            }
            if (_isLong) {
                if (_conditionals.stopLossPrice >= _referencePrice) stopLossValid = false;
            } else {
                if (_conditionals.stopLossPrice <= _referencePrice) stopLossValid = false;
            }
        }
        if (_conditionals.takeProfitSet) {
            if (_conditionals.takeProfitPercentage == 0 || _conditionals.takeProfitPercentage > PRECISION) {
                takeProfitValid = false;
            }
            if (_isLong) {
                if (_conditionals.takeProfitPrice <= _referencePrice) takeProfitValid = false;
            } else {
                if (_conditionals.takeProfitPrice >= _referencePrice) takeProfitValid = false;
            }
        }

        // If Stop Loss / Take Profit are not valid set them to 0
        if (!stopLossValid) {
            _conditionals.stopLossSet = false;
            _conditionals.stopLossPrice = 0;
            _conditionals.stopLossPercentage = 0;
        }
        if (!takeProfitValid) {
            _conditionals.takeProfitSet = false;
            _conditionals.takeProfitPrice = 0;
            _conditionals.takeProfitPercentage = 0;
        }
        // Return the Validated Conditionals
        return _conditionals;
    }

    function validateRequest(IMarketMaker marketMaker, Request memory _request, Execution.State memory _state)
        external
        view
        returns (Request memory)
    {
        // Get the Market from the Market Maker
        address inputMarket = marketMaker.tokenToMarkets(_request.input.assetId);
        // Re-Validate the Input
        validateInputParameters(_request.input, inputMarket);
        if (inputMarket != _request.market) revert Position_UnmatchedMarkets();
        if (_request.user == address(0)) revert Position_ZeroAddress();
        if (_request.requestBlock > block.number) revert Position_InvalidRequestBlock();
        _request.input.conditionals =
            validateConditionals(_request.input.conditionals, _state.indexPrice, _request.input.isLong);

        return _request;
    }
}
