// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IMarket} from "../markets/interfaces/IMarket.sol";
import {IMarketMaker} from "../markets/interfaces/IMarketMaker.sol";
import {ITradeStorage} from "./interfaces/ITradeStorage.sol";
import {Borrowing} from "../libraries/Borrowing.sol";
import {Funding} from "../libraries/Funding.sol";
import {mulDiv, mulDivSigned} from "@prb/math/Common.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {Execution} from "../positions/Execution.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {MarketUtils} from "../markets/MarketUtils.sol";

/// @dev Library containing all the data types used throughout the protocol
library Position {
    using SignedMath for int256;
    using SafeCast for uint256;

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
    error Position_ZeroAddress();
    error Position_InvalidRequestTimestamp();
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

    uint8 private constant MIN_LEVERAGE = 100; // 1x
    uint8 private constant LEVERAGE_PRECISION = 100;
    uint64 private constant PRECISION = 1e18;
    uint64 private constant MIN_COLLATERAL = 1000;
    int256 private constant PRICE_PRECISION = 1e30;
    // Max and Min Price Slippage
    uint128 private constant MIN_SLIPPAGE = 0.0001e30; // 0.01%
    uint128 private constant MAX_SLIPPAGE = 0.9999e30; // 99.99%

    // Data for an Open Position
    struct Data {
        string ticker;
        address user;
        address collateralToken; // WETH long, USDC short
        bool isLong;
        uint256 collateralAmount;
        uint256 positionSize; // USD
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
        Conditionals conditionals;
    }

    // Request -> Constructed by Router based on User Input
    struct Request {
        Input input;
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
    function validateInputParameters(Position.Input memory _trade, address _market)
        public
        view
        returns (bytes32 positionKey)
    {
        if (!(_trade.maxSlippage >= MIN_SLIPPAGE && _trade.maxSlippage <= MAX_SLIPPAGE)) {
            revert Position_InvalidSlippage();
        }
        if (_trade.collateralDelta < MIN_COLLATERAL) revert Position_InvalidCollateralDelta();
        if (bytes(_trade.ticker).length == 0) revert Position_InvalidAssetId();
        if (_market == address(0)) revert Position_MarketDoesNotExist();

        positionKey = keccak256(abi.encode(_trade.ticker, msg.sender, _trade.isLong));

        if (_trade.isLimit && _trade.limitPrice == 0) revert Position_InvalidLimitPrice();
        else if (!_trade.isLimit && _trade.limitPrice != 0) revert Position_InvalidLimitPrice();

        if (_trade.conditionals.stopLossPercentage > PRECISION) revert Position_InvalidConditionalPercentage();
        if (_trade.conditionals.takeProfitPercentage > PRECISION) revert Position_InvalidConditionalPercentage();
    }

    function validateRequest(IMarket market, Request memory _request, Execution.State memory _state)
        external
        view
        returns (Request memory)
    {
        // Check the Market contains the Asset
        if (!market.isAssetInMarket(_request.input.ticker)) revert Position_MarketDoesNotExist();
        // Re-Validate the Input
        validateInputParameters(_request.input, address(market));
        if (_request.user == address(0)) revert Position_ZeroAddress();
        if (_request.requestTimestamp > block.timestamp) revert Position_InvalidRequestTimestamp();
        _request.input.conditionals =
            _validateConditionals(_request.input.conditionals, _state.indexPrice, _request.input.isLong);

        return _request;
    }

    function validateMarketDelta(
        IMarket.MarketStorage calldata _prevStorage,
        IMarket.MarketStorage calldata _storage,
        Position.Request calldata _request
    ) external view {
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
        uint256 _initialCollateral,
        uint256 _collateralIn,
        uint256 _positionFee,
        int256 _fundingFee,
        uint256 _borrowFee,
        uint256 _affiliateRebate
    ) external pure {
        // ensure the position collateral has changed by the correct amount
        uint256 expectedCollateralDelta = _collateralIn - _positionFee - _borrowFee - _affiliateRebate;
        // Account for funding
        if (_fundingFee < 0) expectedCollateralDelta -= _fundingFee.abs();
        else if (_fundingFee > 0) expectedCollateralDelta += _fundingFee.abs();
        // Validate Position Delta
        if (_position.collateralAmount != _initialCollateral + expectedCollateralDelta) {
            revert Position_CollateralDelta();
        }
    }

    function validateCollateralDecrease(
        Data memory _position,
        uint256 _initialCollateral,
        uint256 _collateralDelta,
        uint256 _positionFee, // trading fee not charged on collateral delta
        int256 _fundingFee,
        uint256 _borrowFee,
        uint256 _affiliateRebate
    ) external pure {
        // ensure the position collateral has changed by the correct amount
        uint256 expectedCollateralDelta = _collateralDelta + _positionFee + _borrowFee + _affiliateRebate;
        // Account for funding
        if (_fundingFee < 0) expectedCollateralDelta += _fundingFee.abs();
        else if (_fundingFee > 0) expectedCollateralDelta -= _fundingFee.abs();
        // Validate Position Delta
        if (_position.collateralAmount != _initialCollateral - expectedCollateralDelta) {
            revert Position_CollateralDelta();
        }
    }

    function validateNewPosition(
        uint256 _collateralIn,
        uint256 _positionCollateral,
        uint256 _positionFee,
        uint256 _affiliateRebate
    ) external pure {
        if (_collateralIn != _positionCollateral + _positionFee + _affiliateRebate) {
            revert Position_NewPosition();
        }
    }

    function validateIncreasePosition(
        Data memory _position,
        uint256 _initialCollateral,
        uint256 _initialSize,
        uint256 _collateralIn,
        uint256 _positionFee,
        uint256 _affiliateRebate,
        int256 _fundingFee,
        uint256 _borrowFee,
        uint256 _sizeDelta
    ) external pure {
        uint256 expectedCollateralDelta = _collateralIn - _positionFee - _affiliateRebate - _borrowFee;
        // Account for funding paid out from / to the user
        if (_fundingFee < 0) expectedCollateralDelta -= _fundingFee.abs();
        else if (_fundingFee > 0) expectedCollateralDelta += _fundingFee.abs();
        if (_position.collateralAmount != _initialCollateral + expectedCollateralDelta) {
            revert Position_IncreasePositionCollateral();
        }
        if (_position.positionSize != _initialSize + _sizeDelta) {
            revert Position_IncreasePositionSize();
        }
    }

    function validateDecreasePosition(
        Data memory _position,
        uint256 _initialCollateral,
        uint256 _initialSize,
        uint256 _collateralOut,
        uint256 _positionFee,
        uint256 _affiliateRebate,
        int256 _pnl,
        int256 _fundingFee,
        uint256 _borrowFee,
        uint256 _sizeDelta
    ) external pure {
        // Amount out should = collateralDelta +- pnl += fundingFee - borrow fee - trading fee
        /**
         * collat before should = collat after + collateralDelta + fees + pnl
         * feeDiscount / 2, as 1/2 is rebate to referrer
         */
        uint256 expectedCollateralDelta = _collateralOut + _positionFee + _affiliateRebate + _borrowFee;
        // Account for funding / pnl paid out from collateral
        if (_pnl < 0) expectedCollateralDelta += _pnl.abs();
        if (_fundingFee < 0) expectedCollateralDelta += _fundingFee.abs();

        if (_initialCollateral != _position.collateralAmount + expectedCollateralDelta) {
            revert Position_DecreasePositionCollateral();
        }

        if (_initialSize != _position.positionSize + _sizeDelta) {
            revert Position_DecreasePositionSize();
        }
    }

    // 1x = 100
    function checkLeverage(IMarket market, string calldata _ticker, uint256 _sizeUsd, uint256 _collateralUsd)
        external
        view
    {
        uint256 maxLeverage = MarketUtils.getMaxLeverage(market, _ticker);
        if (_collateralUsd > _sizeUsd) revert Position_CollateralExceedsSize();
        uint256 leverage = mulDiv(_sizeUsd, LEVERAGE_PRECISION, _collateralUsd);
        if (leverage < MIN_LEVERAGE) revert Position_BelowMinLeverage();
        if (leverage > maxLeverage) revert Position_OverMaxLeverage();
    }

    function getRequestType(Input calldata _trade, Data memory _position)
        external
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
                if (_position.collateralAmount < _trade.collateralDelta) revert Position_DeltaExceedsCollateral();
                requestType = RequestType.COLLATERAL_DECREASE;
            }
        } else if (_trade.isIncrease) {
            // Case 3: Trade is a Market / Limit Increase on an Existing Position
            requestType = RequestType.POSITION_INCREASE;
        } else {
            // Case 4 & 5: Trade is a Market Decrease or Limit Order (SL / TP) on an Existing Position
            if (_trade.collateralDelta > _position.collateralAmount) revert Position_InvalidCollateralDelta();
            if (_trade.sizeDelta > _position.positionSize) revert Position_InvalidSizeDelta();

            if (_trade.isLimit) {
                // Case 4: Trade is a Limit Order on an Existing Position (SL / TP)
                if (_position.isLong) {
                    requestType = (_trade.limitPrice > _position.weightedAvgEntryPrice)
                        ? RequestType.TAKE_PROFIT
                        : RequestType.STOP_LOSS;
                } else {
                    requestType = (_trade.limitPrice < _position.weightedAvgEntryPrice)
                        ? RequestType.TAKE_PROFIT
                        : RequestType.STOP_LOSS;
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

    function createRequest(Input calldata _trade, address _user, RequestType _requestType, bytes32 _requestId)
        external
        view
        returns (Request memory request)
    {
        request = Request({
            input: _trade,
            user: _user,
            requestTimestamp: uint64(block.timestamp),
            requestType: _requestType,
            requestId: _requestId
        });
    }

    function generateNewPosition(IMarket market, Request memory _request, Execution.State memory _state)
        external
        view
        returns (Data memory position)
    {
        // Get Entry Funding & Borrowing Values
        (uint256 longBorrowFee, uint256 shortBorrowFee) =
            MarketUtils.getCumulativeBorrowFees(market, _request.input.ticker);
        // get Trade Value in USD
        position = Data({
            ticker: _request.input.ticker,
            collateralToken: _request.input.collateralToken,
            user: _request.user,
            collateralAmount: _request.input.collateralDelta,
            positionSize: _request.input.sizeDelta,
            weightedAvgEntryPrice: _state.impactedPrice,
            lastUpdate: uint64(block.timestamp),
            isLong: _request.input.isLong,
            fundingParams: FundingParams(MarketUtils.getFundingAccrued(market, _request.input.ticker), 0),
            borrowingParams: BorrowingParams(0, longBorrowFee, shortBorrowFee),
            stopLossKey: bytes32(0),
            takeProfitKey: bytes32(0)
        });
    }

    // SL / TP are Decrease Orders tied to a Position
    function constructConditionalOrders(
        Data memory _position,
        Conditionals memory _conditionals,
        uint256 _totalExecutionFee
    ) external view returns (Request memory stopLossOrder, Request memory takeProfitOrder) {
        // Construct the stop loss based on the values
        uint256 slExecutionFee = mulDiv(_totalExecutionFee, 2, 3); // 2/3 of the total execution fee
        if (_conditionals.stopLossSet) {
            stopLossOrder = Request({
                input: Input({
                    ticker: _position.ticker,
                    collateralToken: _position.collateralToken,
                    collateralDelta: mulDiv(_position.collateralAmount, _conditionals.stopLossPercentage, PRECISION),
                    sizeDelta: mulDiv(_position.positionSize, _conditionals.stopLossPercentage, PRECISION),
                    limitPrice: _conditionals.stopLossPrice,
                    maxSlippage: MAX_SLIPPAGE,
                    executionFee: uint64(slExecutionFee),
                    isLong: !_position.isLong,
                    isLimit: true,
                    isIncrease: false,
                    reverseWrap: true,
                    conditionals: Conditionals({
                        stopLossSet: false,
                        stopLossPrice: 0,
                        stopLossPercentage: 0,
                        takeProfitSet: false,
                        takeProfitPrice: 0,
                        takeProfitPercentage: 0
                    })
                }),
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
                    collateralDelta: mulDiv(_position.collateralAmount, _conditionals.takeProfitPercentage, PRECISION),
                    sizeDelta: mulDiv(_position.positionSize, _conditionals.takeProfitPercentage, PRECISION),
                    limitPrice: _conditionals.takeProfitPrice,
                    maxSlippage: MAX_SLIPPAGE,
                    executionFee: uint64(_totalExecutionFee - slExecutionFee),
                    isLong: !_position.isLong,
                    isLimit: true,
                    isIncrease: false,
                    reverseWrap: true,
                    conditionals: Conditionals({
                        stopLossSet: false,
                        stopLossPrice: 0,
                        stopLossPercentage: 0,
                        takeProfitSet: false,
                        takeProfitPrice: 0,
                        takeProfitPercentage: 0
                    })
                }),
                user: _position.user,
                requestTimestamp: uint64(block.timestamp),
                requestType: RequestType.TAKE_PROFIT,
                requestId: bytes32(0)
            });
        }
    }

    function constructLiquidationOrder(Data memory _position, address _liquidator)
        external
        view
        returns (Settlement memory order)
    {
        order = Settlement({
            request: Request({
                input: Input({
                    ticker: _position.ticker,
                    collateralToken: _position.collateralToken,
                    collateralDelta: _position.collateralAmount,
                    sizeDelta: _position.positionSize,
                    limitPrice: 0,
                    maxSlippage: MAX_SLIPPAGE,
                    executionFee: 0,
                    isLong: _position.isLong,
                    isLimit: false,
                    isIncrease: false,
                    reverseWrap: false,
                    conditionals: Conditionals(false, false, 0, 0, 0, 0)
                }),
                user: _position.user,
                requestTimestamp: uint64(block.timestamp),
                requestType: RequestType.POSITION_DECREASE,
                requestId: bytes32(0)
            }),
            orderKey: bytes32(0),
            feeReceiver: _liquidator,
            isAdl: false
        });
    }

    // @audit - can structure like above for more efficiency
    // @audit - fee receiver - need to incentivize
    function createAdlOrder(Data memory _position, uint256 _sizeDelta)
        external
        view
        returns (Settlement memory settlement)
    {
        // calculate collateral delta from size delta
        uint256 collateralDelta = mulDiv(_position.collateralAmount, _sizeDelta, _position.positionSize);

        Request memory request = Request({
            input: Input({
                ticker: _position.ticker,
                collateralToken: _position.collateralToken,
                collateralDelta: collateralDelta,
                sizeDelta: _sizeDelta,
                limitPrice: 0,
                maxSlippage: MAX_SLIPPAGE,
                executionFee: 0,
                isLong: _position.isLong,
                isLimit: false,
                isIncrease: false,
                reverseWrap: false,
                conditionals: Conditionals(false, false, 0, 0, 0, 0)
            }),
            user: _position.user,
            requestTimestamp: uint64(block.timestamp),
            requestType: RequestType.POSITION_DECREASE,
            requestId: bytes32(0)
        });
        settlement =
            Settlement({request: request, orderKey: generateOrderKey(request), feeReceiver: address(0), isAdl: true});
    }

    /**
     * =========================== Getter Functions ============================
     */
    function calculateFee(
        ITradeStorage tradeStorage,
        uint256 _tokenAmount,
        uint256 _collateralDelta,
        uint256 _collateralPrice,
        uint256 _collateralBaseUnit
    ) external view returns (uint256 fee) {
        uint256 feePercentage = tradeStorage.tradingFee();
        // convert index amount to collateral amount
        if (_tokenAmount != 0) {
            uint256 sizeInCollateral = mulDiv(_tokenAmount, _collateralBaseUnit, _collateralPrice);
            // calculate fee
            fee = mulDiv(sizeInCollateral, feePercentage, PRECISION);
        } else {
            fee = mulDiv(_collateralDelta, feePercentage, PRECISION);
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
        // Both Values in USD -> 30 D.P: Divide by Price precision to get 30 D.P value
        fundingFeeUsd = mulDivSigned(_sizeDelta.toInt256(), nextFundingAccrued - _entryFundingAccrued, PRICE_PRECISION);
    }

    function getTotalFundingFees(IMarket market, Data memory _position, uint256 _indexPrice)
        external
        view
        returns (int256 totalFeesOwedUsd)
    {
        (, int256 nextFundingAccrued) = Funding.calculateNextFunding(market, _position.ticker, _indexPrice);
        totalFeesOwedUsd = mulDivSigned(
            _position.positionSize.toInt256(),
            nextFundingAccrued - _position.fundingParams.lastFundingAccrued,
            PRICE_PRECISION
        );
    }

    function getTotalBorrowFees(IMarket market, Data memory _position, Execution.State memory _state)
        external
        view
        returns (uint256 collateralFeesOwed)
    {
        uint256 feesUsd = getTotalBorrowFeesUsd(market, _position);
        collateralFeesOwed = mulDiv(feesUsd, _state.collateralBaseUnit, _state.collateralPrice);
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
        uint256 feeSinceUpdate = borrowFee == 0 ? 0 : mulDiv(_position.positionSize, borrowFee, PRECISION);
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
        int256 priceDelta = _indexPrice.toInt256() - _weightedAvgEntryPrice.toInt256();
        uint256 entryIndexAmount = mulDiv(_positionSizeUsd, _indexBaseUnit, _weightedAvgEntryPrice);
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
        uint256 _indexPrice,
        uint256 _indexBaseUnit,
        uint256 _collateralTokenPrice,
        uint256 _collateralBaseUnit,
        bool _isLong
    ) external pure returns (int256 decreasePositionPnl) {
        // Calculate whole position Pnl
        int256 positionPnl =
            getPositionPnl(_positionSizeUsd, _weightedAvgEntryPrice, _indexPrice, _indexBaseUnit, _isLong);
        // Get (% realised) * pnl
        int256 realizedPnl = mulDivSigned(positionPnl, _sizeDeltaUsd.toInt256(), _positionSizeUsd.toInt256());
        // Convert from USD to collateral tokens
        decreasePositionPnl =
            mulDivSigned(realizedPnl, _collateralBaseUnit.toInt256(), _collateralTokenPrice.toInt256());
    }

    /**
     * =========================== Internal Functions ============================
     */

    // Sizes must be valid percentages
    function _validateConditionals(Conditionals memory _conditionals, uint256 _referencePrice, bool _isLong)
        internal
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

    function _validateFundingValues(
        IMarket.FundingValues calldata _prevFunding,
        IMarket.FundingValues calldata _funding
    ) internal view {
        // Funding Rate should update to current block timestamp
        if (_funding.lastFundingUpdate != block.timestamp) {
            revert Position_FundingTimestamp();
        }
        // If Funding Rate Velocity was non 0, funding rate should change
        if (_prevFunding.fundingRateVelocity != 0) {
            int256 timeElapsed = (block.timestamp - _prevFunding.lastFundingUpdate).toInt256();
            // currentFundingRate = prevRate + velocity * (timeElapsetd / 1 days)
            int256 expectedRate =
                _prevFunding.fundingRate + mulDivSigned(_prevFunding.fundingRateVelocity, timeElapsed, 1 days);
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
        IMarket.BorrowingValues calldata _prevBorrowing,
        IMarket.BorrowingValues calldata _borrowing,
        uint256 _sizeDelta,
        bool _isLong
    ) internal view {
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
        IMarket.OpenInterestValues calldata _prevOpenInterest,
        IMarket.OpenInterestValues calldata _openInterest,
        uint256 _sizeDelta,
        bool _isLong,
        bool _isIncrease
    ) internal pure {
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

    function _validatePnlValues(IMarket.PnlValues calldata _prevPnl, IMarket.PnlValues calldata _pnl, bool _isLong)
        internal
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
}
