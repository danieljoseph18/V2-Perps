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
import {Borrowing} from "../libraries/Borrowing.sol";
import {Funding} from "../libraries/Funding.sol";
import {mulDiv} from "@prb/math/Common.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {MarketUtils} from "../markets/MarketUtils.sol";
import {Pricing} from "../libraries/Pricing.sol";
import {Order} from "../positions/Order.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Oracle} from "../oracle/Oracle.sol";
import {IPriceFeed} from "../oracle/interfaces/IPriceFeed.sol";

/// @dev Library containing all the data types used throughout the protocol
library Position {
    using SignedMath for int256;
    using SafeCast for uint256;

    uint256 public constant MIN_LEVERAGE = 100; // 1x
    uint256 public constant LEVERAGE_PRECISION = 100;
    uint256 public constant PRECISION = 1e18;
    // Margin of Error for Limit Order Prices
    uint256 public constant PRICE_MARGIN = 0.005e18; // 0.5%

    ///////////////////////////
    // OPEN POSITION STRUCTS //
    ///////////////////////////

    // Data for an Open Position
    struct Data {
        IMarket market;
        address indexToken;
        address user;
        address collateralToken; // WETH long, USDC short
        uint256 collateralAmount; // vs size = leverage
        uint256 positionSize; // position size in index tokens, value fluctuates in USD giving PnL
        bool isLong; // will determine token used
        BorrowingParams borrowingParams;
        FundingParams fundingParams;
        PnLParams pnlParams;
        bytes32 stopLossKey;
        bytes32 takeProfitKey;
    }

    // Borrow Component of an Open Position
    struct BorrowingParams {
        uint256 feesOwed;
        uint256 lastBorrowUpdate;
        uint256 lastLongCumulativeBorrowFee; // borrow fee at last for longs
        uint256 lastShortCumulativeBorrowFee; // borrow fee at entry for shorts
    }

    // Funding Component of a Position
    // All Values in Index Tokens
    struct FundingParams {
        uint256 feesEarned;
        uint256 feesOwed;
        uint256 lastFundingUpdate;
        uint256 lastLongCumulativeFunding;
        uint256 lastShortCumulativeFunding;
    }

    // PnL Component of a Position
    struct PnLParams {
        uint256 weightedAvgEntryPrice;
        uint256 sigmaIndexSizeUSD; // Sum of all increases and decreases in index size USD
    }

    struct Conditionals {
        bool stopLossSet;
        bool takeProfitSet;
        uint256 stopLossPrice;
        uint256 takeProfitPrice;
        uint256 stopLossPercentage;
        uint256 takeProfitPercentage;
    }

    /////////////////////
    // REQUEST STRUCTS //
    /////////////////////

    // Trade Request -> Sent by user
    struct Input {
        address indexToken;
        address collateralToken;
        uint256 collateralDelta;
        uint256 sizeDelta;
        uint256 limitPrice;
        uint256 maxSlippage;
        uint256 executionFee;
        bool isLong;
        bool isLimit;
        bool isIncrease;
        bool shouldWrap;
        Conditionals conditionals;
    }

    // Request -> Constructed by Router
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

    function getRequestType(Input calldata _trade, Data memory _position, uint256 _collateralDelta)
        external
        pure
        returns (RequestType requestType)
    {
        // Case 1: Position doesn't exist (Create Position)
        if (_position.user == address(0)) {
            require(_trade.isIncrease, "Position: Invalid Decrease");
            require(_trade.sizeDelta != 0, "Position: Size Delta");
            requestType = RequestType.CREATE_POSITION;
        } else if (_trade.sizeDelta == 0) {
            // Case 2: Position exists but sizeDelta is 0 (Collateral Increase / Decrease)
            if (_trade.isIncrease) {
                requestType = RequestType.COLLATERAL_INCREASE;
            } else {
                require(_position.collateralAmount >= _collateralDelta, "Position: Delta > Collateral");
                requestType = RequestType.COLLATERAL_DECREASE;
            }
        } else {
            // Case 3: Position exists and sizeDelta is not 0 (Position Increase / Decrease)
            require(_trade.sizeDelta != 0, "Position: Size Delta");
            if (_trade.isIncrease) {
                requestType = RequestType.POSITION_INCREASE;
            } else {
                require(_position.positionSize >= _trade.sizeDelta, "Position: Size < SizeDelta");
                require(_position.collateralAmount >= _collateralDelta, "Position: Delta > Collateral");
                requestType = RequestType.POSITION_DECREASE;
            }
        }
    }

    function generateKey(Request memory _request) external pure returns (bytes32 positionKey) {
        positionKey = keccak256(abi.encode(_request.input.indexToken, _request.user, _request.input.isLong));
    }

    // Include the request type to differentiate between types like SL/TP
    function generateOrderKey(Request memory _request) public pure returns (bytes32 orderKey) {
        orderKey =
            keccak256(abi.encode(_request.input.indexToken, _request.user, _request.input.isLong, _request.requestType));
    }

    function checkLimitPrice(uint256 _price, Input memory _request) external pure {
        if (_request.isLong) {
            // Increase Probability of a new order
            require(_price <= _request.limitPrice, "Position: Limit Price");
        } else {
            // Increase Probability of a new order
            require(_price >= _request.limitPrice, "Position: Limit Price");
        }
    }

    function exists(Data memory _position) external pure returns (bool) {
        return _position.user != address(0);
    }

    // 1x = 100
    function checkLeverage(IMarket market, uint256 _sizeUsd, uint256 _collateralUsd) external view {
        uint256 maxLeverage = market.getMaxLeverage();
        require(_collateralUsd <= _sizeUsd, "Position: collateral exceeds size");
        uint256 leverage = mulDiv(_sizeUsd, LEVERAGE_PRECISION, _collateralUsd);
        require(leverage >= MIN_LEVERAGE, "Position: Below Min Leverage");
        require(leverage <= maxLeverage, "Position: Over Max Leverage");
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

    function createEditOrder(
        Data memory _position,
        uint256 _executionPrice,
        uint256 _percentage,
        uint256 _maxSlippage,
        uint256 _executionFee,
        bool _isStopLoss
    ) external view returns (Request memory request) {
        RequestType requestType;
        // Require SL/TP Orders to be a certain % away
        // WAEP is used as the reference price
        uint256 priceMargin = mulDiv(_position.pnlParams.weightedAvgEntryPrice, PRICE_MARGIN, PRECISION);

        Conditionals memory conditionals;
        if (_isStopLoss) {
            require(_executionPrice <= _position.pnlParams.weightedAvgEntryPrice - priceMargin, "Position: SL Price");
            conditionals.stopLossPrice = _executionPrice;
            conditionals.stopLossPercentage = _percentage;
        } else {
            require(_executionPrice >= _position.pnlParams.weightedAvgEntryPrice + priceMargin, "Position: TP Price");
            conditionals.takeProfitPrice = _executionPrice;
            conditionals.takeProfitPercentage = _percentage;
        }
        request = Request({
            input: Input({
                indexToken: _position.indexToken,
                collateralToken: _position.collateralToken,
                collateralDelta: mulDiv(_position.collateralAmount, _percentage, PRECISION),
                sizeDelta: mulDiv(_position.positionSize, _percentage, PRECISION),
                limitPrice: _executionPrice,
                maxSlippage: _maxSlippage,
                executionFee: _executionFee,
                isLong: _position.isLong,
                isLimit: true,
                isIncrease: false,
                shouldWrap: false,
                conditionals: conditionals
            }),
            market: address(_position.market),
            user: _position.user,
            requestBlock: block.number,
            requestType: requestType
        });
    }

    function generateNewPosition(Request memory _request, Order.ExecuteCache memory _cache)
        external
        view
        returns (Data memory position)
    {
        // Get Entry Funding & Borrowing Values
        (uint256 longFundingFee, uint256 shortFundingFee, uint256 longBorrowFee, uint256 shortBorrowFee) =
            _cache.market.getCumulativeFees();
        // get Trade Value in USD
        position = Data({
            market: _cache.market,
            indexToken: _request.input.indexToken,
            collateralToken: _request.input.collateralToken,
            user: _request.user,
            collateralAmount: _request.input.collateralDelta,
            positionSize: _request.input.sizeDelta,
            isLong: _request.input.isLong,
            borrowingParams: BorrowingParams(0, block.timestamp, longBorrowFee, shortBorrowFee),
            fundingParams: FundingParams(0, 0, block.timestamp, longFundingFee, shortFundingFee),
            pnlParams: PnLParams(_cache.indexPrice, _cache.sizeDeltaUsd.abs()),
            stopLossKey: bytes32(0),
            takeProfitKey: bytes32(0)
        });
    }

    function getPnl(Data memory _position, uint256 _price, uint256 _baseUnit) external pure returns (int256 pnl) {
        // Get the Entry Value (WAEP * Position Size)
        uint256 entryValue = mulDiv(_position.pnlParams.weightedAvgEntryPrice, _position.positionSize, _baseUnit);
        // Get the Current Value (Price * Position Size)
        uint256 currentValue = mulDiv(_price, _position.positionSize, _baseUnit);
        // Return the difference
        if (_position.isLong) {
            pnl = currentValue.toInt256() - entryValue.toInt256();
        } else {
            pnl = entryValue.toInt256() - currentValue.toInt256();
        }
    }

    /// @dev Need to adjust for decimals
    function getTradeValueUsd(uint256 _sizeDelta, uint256 _signedPrice, uint256 _baseUnit)
        public
        pure
        returns (uint256 tradeValueUsd)
    {
        tradeValueUsd = mulDiv(_sizeDelta, _signedPrice, _baseUnit);
    }

    function isLiquidatable(Position.Data memory _position, Order.ExecuteCache memory _cache, uint256 liquidationFeeUsd)
        public
        view
        returns (bool)
    {
        uint256 collateralValueUsd = mulDiv(_position.collateralAmount, _cache.collateralPrice, PRECISION);
        uint256 totalFeesOwedUsd = getTotalFeesOwedUsd(_position, _cache);
        int256 pnl = Pricing.calculatePnL(_position, _cache.indexPrice, _cache.indexBaseUnit);
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
                indexToken: _position.indexToken,
                collateralToken: _position.collateralToken,
                collateralDelta: collateralDelta,
                sizeDelta: _sizeDelta,
                limitPrice: 0,
                maxSlippage: 0,
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
    ) public pure returns (uint256 collateralAmount) {
        uint256 indexUsd = mulDiv(_indexAmount, _indexPrice, _indexBaseUnit);
        collateralAmount = mulDiv(indexUsd, _collateralBaseUnit, _collateralPrice);
    }

    function getTotalFeesOwedUsd(Data memory _position, Order.ExecuteCache memory _cache)
        public
        view
        returns (uint256 totalFeesOwedUsd)
    {
        uint256 borrowingFeeOwed = Borrowing.getTotalPositionFeesOwed(_cache.market, _position);
        uint256 borrowingFeeUsd = mulDiv(borrowingFeeOwed, _cache.indexPrice, _cache.indexBaseUnit);

        (, uint256 fundingFeeOwed) = Funding.getTotalPositionFees(_cache.market, _position);
        uint256 fundingValueUsd = mulDiv(fundingFeeOwed, _cache.indexPrice, _cache.indexBaseUnit);

        totalFeesOwedUsd = borrowingFeeUsd + fundingValueUsd;
    }

    function getMarketKey(address _indexToken) external pure returns (bytes32 marketKey) {
        marketKey = keccak256(abi.encode(_indexToken));
    }

    // Sizes must be valid percentages
    function validateConditionals(Conditionals memory _conditionals, uint256 _referencePrice, bool _isLong)
        external
        pure
    {
        uint256 priceMargin = mulDiv(_referencePrice, PRICE_MARGIN, PRECISION);
        if (_conditionals.stopLossSet) {
            require(_conditionals.stopLossPercentage > 0, "Position: StopLoss %");
            if (_isLong) {
                require(_conditionals.stopLossPrice <= _referencePrice - priceMargin, "Position: StopLoss Price");
            } else {
                require(_conditionals.stopLossPrice >= _referencePrice + priceMargin, "Position: StopLoss Price");
            }
        }
        if (_conditionals.takeProfitSet) {
            require(_conditionals.takeProfitPercentage > 0, "Position: TakeProfit %");
            if (_isLong) {
                require(_conditionals.takeProfitPrice >= _referencePrice + priceMargin, "Position: TakeProfit Price");
            } else {
                require(_conditionals.takeProfitPrice <= _referencePrice - priceMargin, "Position: TakeProfit Price");
            }
        }
    }
}
