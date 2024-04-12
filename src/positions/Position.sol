// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IMarket} from "../markets/interfaces/IMarket.sol";
import {ITradeStorage} from "./interfaces/ITradeStorage.sol";
import {Borrowing} from "../libraries/Borrowing.sol";
import {Funding} from "../libraries/Funding.sol";
import {mulDiv, mulDivSigned} from "@prb/math/Common.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {SD59x18, sd, unwrap, exp} from "@prb/math/SD59x18.sol";
import {Execution} from "../positions/Execution.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {MarketUtils} from "../markets/MarketUtils.sol";
import {MathUtils} from "../libraries/MathUtils.sol";

/// @dev Library containing all the data types used throughout the protocol
library Position {
    using SignedMath for int256;
    using SafeCast for uint256;
    using SafeCast for int256;
    using MathUtils for uint256;
    using MathUtils for int256;

    error Position_InvalidDecrease();
    error Position_SizeDelta();
    error Position_DeltaExceedsCollateral();
    error Position_CollateralExceedsSize();
    error Position_BelowMinLeverage();
    error Position_OverMaxLeverage();
    error Position_InvalidSlippage();
    error Position_InvalidCollateralDelta();
    error Position_MarketDoesNotExist();
    error Position_InvalidLimitPrice();
    error Position_InvalidAssetId();
    error Position_InvalidConditionalPercentage();
    error Position_InvalidSizeDelta();
    error Position_CollateralDelta();
    error Position_NewPosition();
    error Position_IncreasePositionCollateral();
    error Position_IncreasePositionSize();
    error Position_InvalidIncreasePosition();
    error Position_DecreasePositionCollateral();
    error Position_DecreasePositionSize();
    error Position_FundingTimestamp();
    error Position_FundingRate();
    error Position_FundingAccrual();
    error Position_BorrowingTimestamp();
    error Position_BorrowRateDelta();
    error Position_CumulativeBorrowDelta();
    error Position_OpenInterestDelta();
    error Position_InvalidFeeUpdate();
    error Position_InvalidCollateralUpdate();
    error Position_InvalidPoolUpdate();

    uint8 private constant MIN_LEVERAGE = 100; // 1x
    uint8 private constant LEVERAGE_PRECISION = 100;
    uint16 private constant MIN_COLLATERAL = 1000;
    uint64 private constant PRECISION = 1e18;
    uint64 private constant TARGET_PNL_RATIO = 0.35e18;
    int256 private constant PRICE_PRECISION = 1e30;
    // Max and Min Price Slippage
    uint128 private constant MIN_SLIPPAGE = 0.0001e30; // 0.01%
    uint128 private constant MAX_SLIPPAGE = 0.9999e30; // 99.99%
    uint256 private constant MAX_ADL_PERCENTAGE = 0.66e18; // 66%

    // Data for an Open Position
    struct Data {
        string ticker;
        address user;
        address collateralToken; // WETH long, USDC short
        bool isLong;
        uint256 collateral; // USD
        uint256 size; // USD
        uint256 weightedAvgEntryPrice;
        uint64 lastUpdate;
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
        uint64 stopLossPercentage;
        uint64 takeProfitPercentage;
        uint256 stopLossPrice;
        uint256 takeProfitPrice;
    }

    // Trade Request -> Sent by user
    struct Input {
        string ticker; // Asset ticker, e.g "ETH"
        address collateralToken;
        uint256 collateralDelta;
        uint256 sizeDelta; // USD
        uint256 limitPrice;
        uint128 maxSlippage; // % with 30 D.P
        uint64 executionFee;
        bool isLong;
        bool isLimit;
        bool isIncrease;
        bool reverseWrap;
        bool triggerAbove; // For Limits -> Execute above the limit price, or below it
    }

    // Request -> Constructed by Router based on User Input
    struct Request {
        Input input;
        Conditionals conditionals;
        address user;
        uint64 requestTimestamp;
        RequestType requestType;
        bytes32 requestId; // Id of the price update request
    }

    // Bundled Request for Execution
    struct Settlement {
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

    /**
     * =========================== Validation Functions ============================
     */
    function validateInputParameters(Input memory _trade, Conditionals memory _conditionals, address _market)
        public
        view
        returns (bytes32 positionKey)
    {
        if (!(_trade.maxSlippage >= MIN_SLIPPAGE && _trade.maxSlippage <= MAX_SLIPPAGE)) {
            revert Position_InvalidSlippage();
        }
        if (bytes(_trade.ticker).length == 0) revert Position_InvalidAssetId();
        if (_market == address(0)) revert Position_MarketDoesNotExist();

        positionKey = keccak256(abi.encode(_trade.ticker, msg.sender, _trade.isLong));

        if (_trade.isLimit && _trade.limitPrice == 0) revert Position_InvalidLimitPrice();
        else if (!_trade.isLimit && _trade.limitPrice != 0) revert Position_InvalidLimitPrice();

        if (_conditionals.stopLossPercentage > PRECISION) revert Position_InvalidConditionalPercentage();
        if (_conditionals.takeProfitPercentage > PRECISION) revert Position_InvalidConditionalPercentage();
    }

    function validateMarketDelta(
        IMarket.MarketStorage memory _prevStorage,
        IMarket.MarketStorage memory _storage,
        Position.Request memory _request
    ) internal view {
        _validateFundingValues(_prevStorage.funding, _storage.funding);
        _validateBorrowingValues(
            _prevStorage.borrowing, _storage.borrowing, _request.input.sizeDelta, _request.input.isLong
        );
        _validateOpenInterest(
            _prevStorage.openInterest,
            _storage.openInterest,
            _request.input.sizeDelta,
            _request.input.isLong,
            _request.input.isIncrease
        );
        _validatePnlValues(_prevStorage.pnl, _storage.pnl, _request.input.isLong);
    }

    function validateCollateralIncrease(
        Data memory _position,
        Execution.FeeState memory _feeState,
        Execution.Prices memory _prices,
        uint256 _collateralDelta,
        uint256 _collateralDeltaUsd,
        uint256 _initialCollateral
    ) internal pure {
        // ensure the position collateral has changed by the correct amount
        uint256 expectedCollateralDelta = _collateralDelta - _feeState.positionFee - _feeState.borrowFee
            - _feeState.affiliateRebate - _feeState.feeForExecutor;
        // Account for funding
        if (_feeState.fundingFee < 0) expectedCollateralDelta -= _feeState.fundingFee.abs();
        else if (_feeState.fundingFee > 0) expectedCollateralDelta += _feeState.fundingFee.abs();
        if (expectedCollateralDelta != _collateralDeltaUsd.fromUsd(_prices.collateralPrice, _prices.collateralBaseUnit))
        {
            revert Position_CollateralDelta();
        }
        // Validate Position Delta
        if (_position.collateral != _initialCollateral + _collateralDeltaUsd) {
            revert Position_CollateralDelta();
        }
    }

    function validateCollateralDecrease(
        Data memory _position,
        Execution.FeeState memory _feeState,
        Execution.Prices memory _prices,
        uint256 _initialCollateral
    ) internal pure {
        // ensure the position collateral has changed by the correct amount
        uint256 expectedCollateralDelta = _feeState.afterFeeAmount + _feeState.positionFee + _feeState.borrowFee
            + _feeState.affiliateRebate + _feeState.feeForExecutor;
        // Account for funding
        if (_feeState.fundingFee < 0) expectedCollateralDelta += _feeState.fundingFee.abs();
        else if (_feeState.fundingFee > 0) expectedCollateralDelta -= _feeState.fundingFee.abs();
        // Convert to USD
        uint256 collateralDeltaUsd = expectedCollateralDelta.toUsd(_prices.collateralPrice, _prices.collateralBaseUnit);
        // Validate Position Delta
        if (_position.collateral != _initialCollateral - collateralDeltaUsd) {
            revert Position_CollateralDelta();
        }
    }

    // @audit - wrong --> need to handle conversions between collateral & usd
    function validateNewPosition(
        uint256 _collateralIn,
        uint256 _afterFeeAmount,
        uint256 _positionFee,
        uint256 _affiliateRebate,
        uint256 _feeForExecutor
    ) internal pure {
        if (_collateralIn != _afterFeeAmount + _positionFee + _affiliateRebate + _feeForExecutor) {
            revert Position_NewPosition();
        }
    }

    function validateIncreasePosition(
        Data memory _position,
        Execution.FeeState memory _feeState,
        Execution.Prices memory _prices,
        uint256 _collateralDelta,
        uint256 _collateralDeltaUsd,
        uint256 _initialCollateral,
        uint256 _initialSize,
        uint256 _sizeDelta
    ) internal pure {
        uint256 expectedCollateralDelta = _collateralDelta - _feeState.positionFee - _feeState.affiliateRebate
            - _feeState.borrowFee - _feeState.feeForExecutor;
        // Account for funding paid out from / to the user
        if (_feeState.fundingFee < 0) expectedCollateralDelta -= _feeState.fundingFee.abs();
        else if (_feeState.fundingFee > 0) expectedCollateralDelta += _feeState.fundingFee.abs();
        // Convert to USD
        uint256 collateralDeltaUsd = expectedCollateralDelta.toUsd(_prices.collateralPrice, _prices.collateralBaseUnit);
        if (_collateralDeltaUsd != collateralDeltaUsd) {
            revert Position_IncreasePositionCollateral();
        }
        if (_position.collateral != _initialCollateral + collateralDeltaUsd) {
            revert Position_IncreasePositionCollateral();
        }
        if (_position.size != _initialSize + _sizeDelta) {
            revert Position_IncreasePositionSize();
        }
    }

    // @gas - can combine with collateral decrease?
    function validateDecreasePosition(
        Data memory _position,
        Execution.FeeState memory _feeState,
        Execution.Prices memory _prices,
        uint256 _initialCollateral,
        uint256 _initialSize,
        uint256 _sizeDelta,
        int256 _pnl
    ) internal pure {
        // Amount out should = collateralDelta +- pnl += fundingFee - borrow fee - trading fee - affiliateRebate - feeForExecutor
        /**
         * collat before should = collat after + collateralDelta + fees + pnl
         * feeDiscount / 2, as 1/2 is rebate to referrer
         */
        uint256 expectedCollateralDelta = _feeState.afterFeeAmount + _feeState.positionFee + _feeState.affiliateRebate
            + _feeState.borrowFee + _feeState.feeForExecutor;
        // Account for funding / pnl paid out from collateral
        if (_pnl < 0) expectedCollateralDelta += _pnl.abs();
        else if (_pnl > 0) expectedCollateralDelta -= _pnl.abs();

        if (_feeState.fundingFee < 0) expectedCollateralDelta += _feeState.fundingFee.abs();

        // Convert to USD
        uint256 collateralDeltaUsd = expectedCollateralDelta.toUsd(_prices.collateralPrice, _prices.collateralBaseUnit);

        if (_initialCollateral != _position.collateral + collateralDeltaUsd) {
            revert Position_DecreasePositionCollateral();
        }

        if (_initialSize != _position.size + _sizeDelta) {
            revert Position_DecreasePositionSize();
        }
    }

    // 1x = 100
    function checkLeverage(IMarket market, string memory _ticker, uint256 _sizeUsd, uint256 _collateralUsd)
        internal
        view
    {
        uint256 maxLeverage = MarketUtils.getMaxLeverage(market, _ticker);
        if (_collateralUsd > _sizeUsd) revert Position_CollateralExceedsSize();
        uint256 leverage = mulDiv(_sizeUsd, LEVERAGE_PRECISION, _collateralUsd);
        if (leverage < MIN_LEVERAGE) revert Position_BelowMinLeverage();
        if (leverage > maxLeverage) revert Position_OverMaxLeverage();
    }

    // @audit - can an order get mischaracterized as an SL vs TP? Can this cause harm?
    // @audit - probably rethink this
    /**
     * We can add a bool for execute above / below. This should make categorization
     * and execution easier.
     */
    // @audit - collateral check is wrong --> different units
    function getRequestType(Input memory _trade, Data memory _position)
        internal
        pure
        returns (RequestType requestType)
    {
        // Case 1: Position doesn't exist (Create Position (Market / Limit))
        if (_position.user == address(0)) {
            if (!_trade.isIncrease) revert Position_InvalidDecrease();
            if (_trade.sizeDelta == 0) revert Position_SizeDelta();
            requestType = RequestType.CREATE_POSITION;
        } else if (_trade.sizeDelta == 0) {
            // Case 2: Position exists but sizeDelta is 0 (Collateral Increase / Decrease)
            if (_trade.isIncrease) {
                requestType = RequestType.COLLATERAL_INCREASE;
            } else {
                if (_position.collateral < _trade.collateralDelta) revert Position_DeltaExceedsCollateral();
                requestType = RequestType.COLLATERAL_DECREASE;
            }
        } else if (_trade.isIncrease) {
            // Case 3: Trade is a Market / Limit Increase on an Existing Position
            requestType = RequestType.POSITION_INCREASE;
        } else {
            // Case 4 & 5: Trade is a Market Decrease or Limit Order (SL / TP) on an Existing Position
            if (_trade.collateralDelta > _position.collateral) revert Position_InvalidCollateralDelta();
            if (_trade.sizeDelta > _position.size) revert Position_InvalidSizeDelta();

            if (_trade.isLimit) {
                // Case 4: Trade is a Limit Order on an Existing Position (SL / TP)
                if (_trade.triggerAbove) {
                    if (_trade.isLong) {
                        requestType = RequestType.TAKE_PROFIT;
                    } else {
                        requestType = RequestType.STOP_LOSS;
                    }
                } else {
                    if (_trade.isLong) requestType = RequestType.STOP_LOSS;
                    else requestType = RequestType.TAKE_PROFIT;
                }
            } else {
                // Case 5: Trade is a Market Decrease on an Existing Position
                requestType = RequestType.POSITION_DECREASE;
            }
        }
    }

    /**
     * =========================== Constructor Functions ============================
     */
    function generateKey(Request memory _request) external pure returns (bytes32 positionKey) {
        positionKey = keccak256(abi.encode(_request.input.ticker, _request.user, _request.input.isLong));
    }

    function generateOrderKey(Request memory _request) public pure returns (bytes32 orderKey) {
        orderKey = keccak256(
            abi.encode(
                _request.input.ticker,
                _request.user,
                _request.input.isLong,
                _request.input.isIncrease, // Enables separate SL / TP Orders
                _request.input.limitPrice // Enables multiple limit orders
            )
        );
    }

    function createRequest(
        Input memory _trade,
        Conditionals calldata _conditionals,
        address _user,
        RequestType _requestType,
        bytes32 _requestId
    ) internal view returns (Request memory request) {
        request = Request({
            input: _trade,
            conditionals: _conditionals,
            user: _user,
            requestTimestamp: uint64(block.timestamp),
            requestType: _requestType,
            requestId: _requestId
        });
    }

    function generateNewPosition(
        IMarket market,
        Request memory _request,
        uint256 _impactedPrice,
        uint256 _collateralUsd
    ) internal view returns (Data memory position) {
        // Get Entry Funding & Borrowing Values
        (uint256 longBorrowFee, uint256 shortBorrowFee) =
            MarketUtils.getCumulativeBorrowFees(market, _request.input.ticker);
        // get Trade Value in USD
        position = Data({
            ticker: _request.input.ticker,
            collateralToken: _request.input.collateralToken,
            user: _request.user,
            collateral: _collateralUsd,
            size: _request.input.sizeDelta,
            weightedAvgEntryPrice: _impactedPrice,
            lastUpdate: uint64(block.timestamp),
            isLong: _request.input.isLong,
            fundingParams: FundingParams(MarketUtils.getFundingAccrued(market, _request.input.ticker), 0),
            borrowingParams: BorrowingParams(0, longBorrowFee, shortBorrowFee),
            stopLossKey: bytes32(0),
            takeProfitKey: bytes32(0)
        });
    }

    // SL / TP are Decrease Orders tied to a Position
    function createConditionalOrders(
        Data memory _position,
        Conditionals memory _conditionals,
        Execution.Prices memory _prices,
        uint256 _totalExecutionFee
    ) internal view returns (Request memory stopLossOrder, Request memory takeProfitOrder) {
        // Construct the stop loss based on the values
        uint256 slExecutionFee = _totalExecutionFee.percentage(2, 3); // 2/3 of the total execution fee
        if (_conditionals.stopLossSet) {
            stopLossOrder = Request({
                input: Input({
                    ticker: _position.ticker,
                    collateralToken: _position.collateralToken,
                    // Convert Percentage of Collateral from USD to Collateral Tokens
                    collateralDelta: _position.collateral.percentage(_conditionals.stopLossPercentage).fromUsd(
                        _prices.collateralPrice, _prices.collateralBaseUnit
                        ),
                    sizeDelta: _position.size.percentage(_conditionals.stopLossPercentage),
                    limitPrice: _conditionals.stopLossPrice,
                    maxSlippage: MAX_SLIPPAGE,
                    executionFee: uint64(slExecutionFee),
                    isLong: _position.isLong,
                    isLimit: true,
                    isIncrease: false,
                    reverseWrap: true,
                    triggerAbove: _position.isLong ? false : true
                }),
                conditionals: Conditionals(false, false, 0, 0, 0, 0),
                user: _position.user,
                requestTimestamp: uint64(block.timestamp),
                requestType: RequestType.STOP_LOSS,
                requestId: bytes32(0)
            });
        }
        // Construct the Take profit based on the values
        if (_conditionals.takeProfitSet) {
            takeProfitOrder = Request({
                input: Input({
                    ticker: _position.ticker,
                    collateralToken: _position.collateralToken,
                    collateralDelta: _position.collateral.percentage(_conditionals.takeProfitPercentage).fromUsd(
                        _prices.collateralPrice, _prices.collateralBaseUnit
                        ),
                    sizeDelta: _position.size.percentage(_conditionals.takeProfitPercentage),
                    limitPrice: _conditionals.takeProfitPrice,
                    maxSlippage: MAX_SLIPPAGE,
                    executionFee: uint64(_totalExecutionFee - slExecutionFee),
                    isLong: !_position.isLong,
                    isLimit: true,
                    isIncrease: false,
                    reverseWrap: true,
                    triggerAbove: _position.isLong ? true : false
                }),
                conditionals: Conditionals(false, false, 0, 0, 0, 0),
                user: _position.user,
                requestTimestamp: uint64(block.timestamp),
                requestType: RequestType.TAKE_PROFIT,
                requestId: bytes32(0)
            });
        }
    }

    function createLiquidationOrder(
        Data memory _position,
        uint256 _collateralPrice,
        uint256 _collateralBaseUnit,
        address _liquidator,
        bytes32 _requestId
    ) internal view returns (Settlement memory order) {
        order = Settlement({
            request: Request({
                input: Input({
                    ticker: _position.ticker,
                    collateralToken: _position.collateralToken,
                    collateralDelta: _position.collateral.fromUsd(_collateralPrice, _collateralBaseUnit),
                    sizeDelta: _position.size,
                    limitPrice: 0,
                    maxSlippage: MAX_SLIPPAGE,
                    executionFee: 0,
                    isLong: _position.isLong,
                    isLimit: false,
                    isIncrease: false,
                    reverseWrap: false,
                    triggerAbove: false
                }),
                conditionals: Conditionals(false, false, 0, 0, 0, 0),
                user: _position.user,
                requestTimestamp: uint64(block.timestamp),
                requestType: RequestType.POSITION_DECREASE,
                requestId: _requestId
            }),
            orderKey: bytes32(0),
            feeReceiver: _liquidator,
            isAdl: false
        });
    }

    function createAdlOrder(
        Data memory _position,
        uint256 _sizeDelta,
        uint256 _collateralDelta,
        address _feeReceiver,
        bytes32 _requestId
    ) internal view returns (Settlement memory order) {
        order = Settlement({
            request: Request({
                input: Input({
                    ticker: _position.ticker,
                    collateralToken: _position.collateralToken,
                    collateralDelta: _collateralDelta,
                    sizeDelta: _sizeDelta,
                    limitPrice: 0,
                    maxSlippage: MAX_SLIPPAGE,
                    executionFee: 0,
                    isLong: _position.isLong,
                    isLimit: false,
                    isIncrease: false,
                    reverseWrap: false,
                    triggerAbove: false
                }),
                conditionals: Conditionals(false, false, 0, 0, 0, 0),
                user: _position.user,
                requestTimestamp: uint64(block.timestamp),
                requestType: RequestType.POSITION_DECREASE,
                requestId: _requestId
            }),
            orderKey: bytes32(0),
            feeReceiver: _feeReceiver,
            isAdl: true
        });
    }

    /**
     * =========================== Getter Functions ============================
     */
    function calculateFee(
        ITradeStorage tradeStorage,
        uint256 _sizeDelta,
        uint256 _collateralDelta,
        uint256 _collateralPrice,
        uint256 _collateralBaseUnit
    ) external view returns (uint256 positionFee, uint256 feeForExecutor) {
        uint256 feePercentage = tradeStorage.tradingFee();
        uint256 executorPercentage = tradeStorage.feeForExecution();
        // Units usd to collateral amount
        if (_sizeDelta != 0) {
            uint256 sizeInCollateral = _sizeDelta.fromUsd(_collateralPrice, _collateralBaseUnit);
            // calculate fee
            positionFee = sizeInCollateral.percentage(feePercentage);
            feeForExecutor = positionFee.percentage(executorPercentage);
            positionFee -= feeForExecutor;
        } else {
            positionFee = _collateralDelta.percentage(feePercentage);
            feeForExecutor = positionFee.percentage(executorPercentage);
            positionFee -= feeForExecutor;
        }
    }

    function getFundingFeeDelta(
        IMarket market,
        string calldata _ticker,
        uint256 _indexPrice,
        uint256 _sizeDelta,
        int256 _entryFundingAccrued
    ) external view returns (int256 fundingFeeUsd, int256 nextFundingAccrued) {
        (, nextFundingAccrued) = Funding.calculateNextFunding(market, _ticker, _indexPrice);
        // Funding Fee Usd = Size Delta * Percentage Funding Accrued
        fundingFeeUsd = _sizeDelta.toInt256().percentageUsd(nextFundingAccrued - _entryFundingAccrued);
    }

    function getTotalFundingFees(IMarket market, Data memory _position, uint256 _indexPrice)
        external
        view
        returns (int256 totalFeesOwedUsd)
    {
        (, int256 nextFundingAccrued) = Funding.calculateNextFunding(market, _position.ticker, _indexPrice);
        // Total Fees Owed Usd = Position Size * Percentage Funding Accrued
        totalFeesOwedUsd =
            _position.size.toInt256().percentageInt(nextFundingAccrued - _position.fundingParams.lastFundingAccrued);
    }

    function getTotalBorrowFees(IMarket market, Data memory _position, Execution.Prices memory _prices)
        external
        view
        returns (uint256 collateralFeesOwed)
    {
        uint256 feesUsd = getTotalBorrowFeesUsd(market, _position);
        collateralFeesOwed = feesUsd.fromUsd(_prices.collateralPrice, _prices.collateralBaseUnit);
    }

    /// @dev Gets Total Fees Owed By a Position in Tokens
    /// @dev Gets Fees Owed Since the Last Time a Position Was Updated
    /// @dev Units: Fees in USD (% of fees applied to position size)
    function getTotalBorrowFeesUsd(IMarket market, Data memory _position)
        public
        view
        returns (uint256 totalFeesOwedUsd)
    {
        uint256 borrowFee = _position.isLong
            ? MarketUtils.getCumulativeBorrowFee(market, _position.ticker, true)
                - _position.borrowingParams.lastLongCumulativeBorrowFee
            : MarketUtils.getCumulativeBorrowFee(market, _position.ticker, false)
                - _position.borrowingParams.lastShortCumulativeBorrowFee;
        borrowFee += Borrowing.calculatePendingFees(market, _position.ticker, _position.isLong);
        uint256 feeSinceUpdate = borrowFee == 0 ? 0 : _position.size.percentage(borrowFee);
        totalFeesOwedUsd = feeSinceUpdate + _position.borrowingParams.feesOwed;
    }

    /// @dev returns PNL in USD
    // PNL = (Current Price - Average Entry Price) * (Position Value / Average Entry Price)
    function getPositionPnl(
        uint256 _positionSizeUsd,
        uint256 _weightedAvgEntryPrice,
        uint256 _indexPrice,
        uint256 _indexBaseUnit,
        bool _isLong
    ) public pure returns (int256) {
        int256 priceDelta = _indexPrice.diff(_weightedAvgEntryPrice);
        uint256 entryIndexAmount = _positionSizeUsd.fromUsd(_weightedAvgEntryPrice, _indexBaseUnit);
        if (_isLong) {
            return mulDivSigned(priceDelta, entryIndexAmount.toInt256(), _indexBaseUnit.toInt256());
        } else {
            return -mulDivSigned(priceDelta, entryIndexAmount.toInt256(), _indexBaseUnit.toInt256());
        }
    }

    /// @dev Returns fractional PNL in Collateral tokens
    function getRealizedPnl(
        uint256 _positionSizeUsd,
        uint256 _sizeDeltaUsd,
        uint256 _weightedAvgEntryPrice,
        uint256 _impactedPrice,
        uint256 _indexBaseUnit,
        uint256 _collateralTokenPrice,
        uint256 _collateralBaseUnit,
        bool _isLong
    ) external pure returns (int256 decreasePositionPnl) {
        // Calculate whole position Pnl
        int256 positionPnl =
            getPositionPnl(_positionSizeUsd, _weightedAvgEntryPrice, _impactedPrice, _indexBaseUnit, _isLong);

        // Get (% realised) * pnl
        int256 realizedPnl = positionPnl.percentageSigned(_sizeDeltaUsd, _positionSizeUsd);

        // Units from USD to collateral tokens
        decreasePositionPnl = realizedPnl.fromUsdToSigned(_collateralTokenPrice, _collateralBaseUnit);
    }

    function getLiquidationPrice(Data memory _position) external pure returns (uint256 liquidationPrice) {
        if (_position.isLong) {
            // For long positions, liquidation price is when:
            // collateral + PNL = 0
            // Solving for liquidation price:
            // (liquidationPrice - entryPrice) * (positionSize / entryPrice) + _position.collateral = 0
            // liquidationPrice = entryPrice - (_position.collateral * entryPrice) / positionSize

            liquidationPrice = _position.weightedAvgEntryPrice
                - mulDiv(_position.collateral, _position.weightedAvgEntryPrice, _position.size);
        } else {
            // For short positions, liquidation price is when:
            // collateral - PNL = 0
            // Solving for liquidation price:
            // (entryPrice - liquidationPrice) * (positionSize / entryPrice) - _position.collateral = 0
            // liquidationPrice = entryPrice + (_position.collateral * entryPrice) / positionSize

            liquidationPrice = _position.weightedAvgEntryPrice
                + mulDiv(_position.collateral, _position.weightedAvgEntryPrice, _position.size);
        }
    }

    /**
     * @dev Calculates the Percentage to ADL a position by based on the PNL to Pool Ratio.
     * Percentage to ADL = 1 - e ** (-sqrt(excessRatio) * (positionPnl/positionSize))
     * where excessRatio = (currentPnlToPoolRatio/targetPnlToPoolRatio) - 1
     *
     * The maximum pnl to pool ratio is configured to 0.45e18, or 45%. We introduce
     * a target pnl to pool ratio (35%), so that in the event of the max ratio being exceeded, the
     * overall ratio can still be reduced. If we configured the excess ratio
     * purely based on the max ratio, once pnl exceeds 45%, the percentage to adl would be 0.
     */
    function calculateAdlPercentage(uint256 _pnlToPoolRatio, int256 _positionProfit, uint256 _positionSize)
        external
        pure
        returns (uint256 adlPercentage)
    {
        uint256 excessRatio = (_pnlToPoolRatio.mulDivCeil(PRECISION, TARGET_PNL_RATIO) - PRECISION).squared();
        SD59x18 exponent = sd(-excessRatio.toInt256()).mul(sd(_positionProfit)).div(sd(_positionSize.toInt256()));
        adlPercentage = PRECISION - unwrap(exp(exponent)).toUint256();
        if (adlPercentage > MAX_ADL_PERCENTAGE) adlPercentage = MAX_ADL_PERCENTAGE;
    }

    /**
     * =========================== Private Functions ============================
     */

    // Sizes must be valid percentages
    function _validateConditionals(Conditionals memory _conditionals, uint256 _referencePrice, bool _isLong)
        private
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

    function _validateFundingValues(IMarket.FundingValues memory _prevFunding, IMarket.FundingValues memory _funding)
        private
        view
    {
        // Funding Rate should update to current block timestamp
        if (_funding.lastFundingUpdate != block.timestamp) {
            revert Position_FundingTimestamp();
        }
        // If Funding Rate Velocity was non 0, funding rate should change
        if (_prevFunding.fundingRateVelocity != 0) {
            uint256 timeElapsed = (block.timestamp - _prevFunding.lastFundingUpdate);
            // currentFundingRate = prevRate + velocity * (timeElapsed / 1 days)
            int256 expectedRate =
                _prevFunding.fundingRate + _prevFunding.fundingRateVelocity.percentageSigned(timeElapsed, 1 days);
            if (expectedRate != _funding.fundingRate) {
                revert Position_FundingRate();
            }
        }
        // If Funding Rate was non 0, accrued USD should change
        if (_prevFunding.fundingRate != 0 && _prevFunding.fundingAccruedUsd == _funding.fundingAccruedUsd) {
            revert Position_FundingAccrual();
        }
    }

    function _validateBorrowingValues(
        IMarket.BorrowingValues memory _prevBorrowing,
        IMarket.BorrowingValues memory _borrowing,
        uint256 _sizeDelta,
        bool _isLong
    ) private view {
        // Borrowing Rate should update to current block timestamp
        if (_borrowing.lastBorrowUpdate != block.timestamp) {
            revert Position_BorrowingTimestamp();
        }
        if (_isLong) {
            // If Size Delta != 0 -> Borrow Rate should change due to updated OI
            if (_sizeDelta != 0 && _borrowing.longBorrowingRate == _prevBorrowing.longBorrowingRate) {
                revert Position_BorrowRateDelta();
            }
            // If Time elapsed = 0, Cumulative Fees should remain constant
            if (_prevBorrowing.lastBorrowUpdate == block.timestamp) {
                if (_borrowing.longCumulativeBorrowFees != _prevBorrowing.longCumulativeBorrowFees) {
                    revert Position_CumulativeBorrowDelta();
                }
            } else {
                // Else should change for side if rate not 0
                if (
                    _borrowing.longCumulativeBorrowFees == _prevBorrowing.longCumulativeBorrowFees
                        && _prevBorrowing.longBorrowingRate != 0
                ) {
                    revert Position_CumulativeBorrowDelta();
                }
            }
        } else {
            // If Size Delta != 0 -> Borrow Rate should change due to updated OI
            if (_sizeDelta != 0 && _borrowing.shortBorrowingRate == _prevBorrowing.shortBorrowingRate) {
                revert Position_BorrowRateDelta();
            }
            // If Time elapsed = 0, Cumulative Fees should remain constant
            if (_prevBorrowing.lastBorrowUpdate == block.timestamp) {
                if (_borrowing.shortCumulativeBorrowFees != _prevBorrowing.shortCumulativeBorrowFees) {
                    revert Position_CumulativeBorrowDelta();
                }
            } else {
                // Else should change for side if rate not 0
                if (
                    _borrowing.shortCumulativeBorrowFees == _prevBorrowing.shortCumulativeBorrowFees
                        && _prevBorrowing.shortBorrowingRate != 0
                ) {
                    revert Position_CumulativeBorrowDelta();
                }
            }
        }
    }

    function _validateOpenInterest(
        IMarket.OpenInterestValues memory _prevOpenInterest,
        IMarket.OpenInterestValues memory _openInterest,
        uint256 _sizeDelta,
        bool _isLong,
        bool _isIncrease
    ) private pure {
        if (_isLong) {
            // If increase, long open interest should increase by size delta.
            if (_isIncrease) {
                if (_openInterest.longOpenInterest != _prevOpenInterest.longOpenInterest + _sizeDelta) {
                    revert Position_OpenInterestDelta();
                }
            } else {
                // If decrease, long open interest should decrease by size delta.
                if (_openInterest.longOpenInterest != _prevOpenInterest.longOpenInterest - _sizeDelta) {
                    revert Position_OpenInterestDelta();
                }
            }
        } else {
            // If increase, short open interest should increase by size delta.
            if (_isIncrease) {
                if (_openInterest.shortOpenInterest != _prevOpenInterest.shortOpenInterest + _sizeDelta) {
                    revert Position_OpenInterestDelta();
                }
            } else {
                // If decrease, short open interest should decrease by size delta.
                if (_openInterest.shortOpenInterest != _prevOpenInterest.shortOpenInterest - _sizeDelta) {
                    revert Position_OpenInterestDelta();
                }
            }
        }
    }

    function _validatePnlValues(IMarket.PnlValues memory _prevPnl, IMarket.PnlValues memory _pnl, bool _isLong)
        private
        pure
    {
        // WAEP for the Opposite side should never change
        if (_isLong) {
            if (_pnl.shortAverageEntryPriceUsd != _prevPnl.shortAverageEntryPriceUsd) {
                revert Position_InvalidIncreasePosition();
            }
        } else {
            if (_pnl.longAverageEntryPriceUsd != _prevPnl.longAverageEntryPriceUsd) {
                revert Position_InvalidIncreasePosition();
            }
        }
    }

    /**
     * For an increase:
     * - Fees should be accumulated in the fee pool
     * - Users collateral amount should increase by collateral after fees
     * - Settled funding should be settled through the pool balance
     *
     * For a decrease:
     * - Fees should be accumulated in the fee pool
     * - Users collateral amount should decrease by collateral after fees
     * - Settled funding should be settled through the pool balance
     * - PNL should be settled through the pool balance
     */
    // @audit - need to account for collateral absorbed into the pool
    function validatePoolDelta(
        Execution.FeeState memory _feeState,
        IMarket.State memory _marketBefore,
        IMarket.State memory _marketAfter,
        uint256 _collateralDelta,
        uint256 _userCollateralBefore,
        bool _isIncrease,
        bool _isFullDecrease
    ) internal pure {
        if (_isIncrease) {
            // Fees should be accumulated in the fee pool
            if (
                _marketAfter.accumulatedFees
                    != _marketBefore.accumulatedFees + _feeState.positionFee + _feeState.borrowFee
            ) {
                revert Position_InvalidFeeUpdate();
            }
            // Funding / PNL should be settled through the pool balance
            // Calculate the Execpted Balance of the Market
            uint256 expectedMarketBalance = _marketBefore.poolBalance;
            // If user paid funding, pool should increase
            if (_feeState.fundingFee < 0) expectedMarketBalance += _feeState.fundingFee.abs();
            // If user got paid funding, pool should decrease
            else if (_feeState.fundingFee > 0) expectedMarketBalance -= _feeState.fundingFee.abs();
            // If user lost pnl, pool should increase
            if (_feeState.realizedPnl < 0) expectedMarketBalance -= _feeState.realizedPnl.abs();
            // If user gained pnl, pool should decrease
            else if (_feeState.realizedPnl > 0) expectedMarketBalance += _feeState.realizedPnl.abs();

            if (_marketAfter.poolBalance != expectedMarketBalance) {
                revert Position_InvalidPoolUpdate();
            }
        } else {
            // Fees should be accumulated in the fee pool
            if (
                _marketAfter.accumulatedFees
                    != _marketBefore.accumulatedFees + _feeState.positionFee + _feeState.borrowFee
            ) {
                revert Position_InvalidFeeUpdate();
            }

            // Funding / PNL should be settled through the pool balance
            // Calculate the Execpted Balance of the Market
            uint256 expectedMarketBalance = _marketBefore.poolBalance;

            if (_feeState.isLiquidation) {
                // If liquidation, all collateral after fees should be accumulated in the pool

                expectedMarketBalance += _feeState.afterFeeAmount;
                if (_feeState.amountOwedToUser > 0) {
                    expectedMarketBalance -= _feeState.amountOwedToUser;
                }
            } else {
                // If user paid funding, pool should increase
                if (_feeState.fundingFee < 0) {
                    expectedMarketBalance += _feeState.fundingFee.abs();
                } else if (_feeState.fundingFee > 0) {
                    // If user got paid funding, pool should decrease
                    expectedMarketBalance -= _feeState.fundingFee.abs();
                }
                // If user lost pnl, pool should increase
                if (_feeState.realizedPnl < 0) {
                    expectedMarketBalance += _feeState.realizedPnl.abs();
                } else if (_feeState.realizedPnl > 0) {
                    // If user gained pnl, pool should decrease
                    expectedMarketBalance -= _feeState.realizedPnl.abs();
                }
            }

            if (_collateralDelta > _userCollateralBefore) {
                // If deficit in collateral was covered by the pool (due to decrease in collateral value)
                expectedMarketBalance -= (_collateralDelta - _userCollateralBefore);
            } else if (_isFullDecrease && _userCollateralBefore - _collateralDelta > 0) {
                // If excess collateral left on a full decrease, it's absorbed into the pool
                expectedMarketBalance += (_userCollateralBefore - _collateralDelta);
            }

            if (_marketAfter.poolBalance != expectedMarketBalance) {
                revert Position_InvalidPoolUpdate();
            }
        }
    }
}
