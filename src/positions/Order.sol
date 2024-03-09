// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {IMarket} from "../markets/interfaces/IMarket.sol";
import {IMarketMaker} from "../markets/interfaces/IMarketMaker.sol";
import {Position} from "./Position.sol";
import {MarketUtils} from "../markets/MarketUtils.sol";
import {Funding} from "../libraries/Funding.sol";
import {Borrowing} from "../libraries/Borrowing.sol";
import {Pricing} from "../libraries/Pricing.sol";
import {mulDiv} from "@prb/math/Common.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Oracle} from "../oracle/Oracle.sol";
import {Fee} from "../libraries/Fee.sol";
import {ITradeStorage} from "./interfaces/ITradeStorage.sol";
import {IPriceFeed} from "../oracle/interfaces/IPriceFeed.sol";
import {PriceImpact} from "../libraries/PriceImpact.sol";

// Library for Handling Trade related logic
library Order {
    using SignedMath for int256;
    using SafeCast for uint256;

    uint256 internal constant PRECISION = 1e18;
    uint256 private constant MIN_SLIPPAGE = 0.0001e18; // 0.01%
    uint256 private constant MAX_SLIPPAGE = 0.9999e18; // 99.99%

    /**
     * ========================= Data Structures =========================
     */
    struct DecreaseState {
        uint256 sizeDelta;
        int256 decreasePnl;
        uint256 afterFeeAmount;
        uint256 positionFee;
    }

    // stated Values for Execution
    struct ExecutionState {
        IMarket market;
        uint256 indexPrice;
        uint256 indexBaseUnit;
        uint256 impactedPrice;
        uint256 longMarketTokenPrice;
        uint256 shortMarketTokenPrice;
        int256 sizeDeltaUsd;
        int256 collateralDeltaUsd;
        int256 priceImpactUsd;
        uint256 collateralPrice;
        uint256 collateralBaseUnit;
        int256 fundingFee;
        uint256 borrowFee;
        uint256 fee;
        uint256 feeDiscount;
        address referrer;
    }

    struct CreationState {
        uint256 collateralRefPrice;
        address market;
        bytes32 positionKey;
        uint256 indexRefPrice;
        uint256 indexBaseUnit;
        uint256 sizeDeltaUsd;
        uint256 collateralDeltaUsd;
        uint256 collateralBaseUnit;
        uint256 minCollateralUsd;
        uint256 collateralAmountUsd;
        uint256 positionSizeUsd;
        Position.RequestType requestType;
    }

    /**
     * ========================= Construction Functions =========================
     */
    function constructExecuteParams(
        ITradeStorage tradeStorage,
        IMarketMaker marketMaker,
        IPriceFeed priceFeed,
        bytes32 _orderKey,
        address _feeReceiver,
        Oracle.TradingEnabled memory _isTradingEnabled
    ) external view returns (ExecutionState memory state, Position.Request memory request) {
        // Fetch and validate request from key
        request = tradeStorage.getOrder(_orderKey);
        require(request.user != address(0), "Order: Request Key");
        require(_feeReceiver != address(0), "Order: Fee Receiver");
        // Get the asset and validate trading is enabled
        Oracle.validateTradingHours(priceFeed, request.input.indexToken, _isTradingEnabled);
        // Fetch and validate price
        state = retrieveTokenPrices(
            priceFeed,
            state,
            request.input.indexToken,
            request.requestBlock,
            request.input.isLong,
            request.input.isIncrease,
            request.input.isLimit
        );

        if (request.input.isLimit) Position.checkLimitPrice(state.indexPrice, request.input);

        // state Variables
        state.market = IMarket(marketMaker.tokenToMarkets(request.input.indexToken));
        state.collateralDeltaUsd = _calculateValueUsd(
            request.input.collateralDelta, state.collateralPrice, state.collateralBaseUnit, request.input.isIncrease
        );

        if (request.input.sizeDelta != 0) {
            // Execute Price Impact
            (state.impactedPrice, state.priceImpactUsd) = PriceImpact.execute(state.market, priceFeed, request, state);
            // state Size Delta USD
            state.sizeDeltaUsd = _calculateValueUsd(
                request.input.sizeDelta, state.indexPrice, state.indexBaseUnit, request.input.isIncrease
            );

            MarketUtils.validateAllocation(
                state.market,
                request.input.indexToken,
                state.sizeDeltaUsd.abs(),
                state.collateralPrice,
                state.collateralBaseUnit,
                request.input.isLong
            );
        }
    }

    // SL / TP are Decrease Orders tied to a Position
    function constructConditionalOrders(
        Position.Data memory _position,
        Position.Conditionals memory _conditionals,
        uint256 _referencePrice
    ) external view returns (Position.Request memory stopLossOrder, Position.Request memory takeProfitOrder) {
        // Validate the Conditionals
        Position.validateConditionals(_conditionals, _referencePrice, _position.isLong);
        // Construct the stop loss based on the values
        if (_conditionals.stopLossSet) {
            stopLossOrder = Position.Request({
                input: Position.Input({
                    indexToken: _position.indexToken,
                    collateralToken: _position.collateralToken,
                    collateralDelta: mulDiv(_position.collateralAmount, _conditionals.stopLossPercentage, PRECISION),
                    sizeDelta: mulDiv(_position.positionSize, _conditionals.stopLossPercentage, PRECISION),
                    limitPrice: _conditionals.stopLossPrice,
                    maxSlippage: MAX_SLIPPAGE,
                    executionFee: 0, // @audit - how do we get user to pay for execution?
                    isLong: !_position.isLong,
                    isLimit: true,
                    isIncrease: false,
                    shouldWrap: true,
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
                    indexToken: _position.indexToken,
                    collateralToken: _position.collateralToken,
                    collateralDelta: mulDiv(_position.collateralAmount, _conditionals.takeProfitPercentage, PRECISION),
                    sizeDelta: mulDiv(_position.positionSize, _conditionals.takeProfitPercentage, PRECISION),
                    limitPrice: _conditionals.takeProfitPrice,
                    maxSlippage: MAX_SLIPPAGE,
                    executionFee: 0, // @audit - how do we get user to pay for execution?
                    isLong: !_position.isLong,
                    isLimit: true,
                    isIncrease: false,
                    shouldWrap: true,
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

    /**
     * ========================= Validation Functions =========================
     */
    function validateInitialParameters(
        IMarketMaker marketMaker,
        ITradeStorage tradeStorage,
        IPriceFeed priceFeed,
        Position.Input memory _trade
    ) external view returns (CreationState memory state) {
        require(_trade.maxSlippage >= MIN_SLIPPAGE && _trade.maxSlippage <= MAX_SLIPPAGE, "Order: Slippage");
        require(_trade.collateralDelta != 0, "Order: Collateral Delta");

        if (_trade.isLong) {
            state.collateralRefPrice = Oracle.getLongReferencePrice(priceFeed);
        } else {
            state.collateralRefPrice = Oracle.getShortReferencePrice(priceFeed);
        }

        state.market = marketMaker.tokenToMarkets(_trade.indexToken);
        require(state.market != address(0), "Order: Market Doesn't Exist");

        state.positionKey = keccak256(abi.encode(_trade.indexToken, msg.sender, _trade.isLong));

        state.indexRefPrice = Oracle.getReferencePrice(priceFeed, priceFeed.getAsset(_trade.indexToken));

        state.indexBaseUnit = Oracle.getBaseUnit(priceFeed, _trade.indexToken);
        state.sizeDeltaUsd = mulDiv(_trade.sizeDelta, state.indexRefPrice, state.indexBaseUnit);

        if (_trade.isLimit) {
            require(_trade.limitPrice > 0, "Order: Limit Price");
            if (_trade.isLong) {
                require(_trade.limitPrice <= state.indexRefPrice, "Order: ref price > limit price");
            } else {
                require(_trade.limitPrice >= state.indexRefPrice, "Order: ref price < limit price");
            }
        }

        state.collateralBaseUnit = Oracle.getBaseUnit(priceFeed, _trade.collateralToken);
        state.collateralDeltaUsd = mulDiv(_trade.collateralDelta, state.collateralRefPrice, state.collateralBaseUnit);
        state.minCollateralUsd = tradeStorage.minCollateralUsd();
    }

    function validateParamsForType(
        Position.Input memory _trade,
        CreationState memory _state,
        uint256 _collateralAmount,
        uint256 _positionSize
    ) external view returns (CreationState memory) {
        // Validate for each request type
        if (_state.requestType == Position.RequestType.CREATE_POSITION) {
            Position.validateConditionals(_trade.conditionals, _state.indexRefPrice, _trade.isLong);
            checkMinCollateral(
                _trade.collateralDelta, _state.collateralRefPrice, _state.collateralBaseUnit, _state.minCollateralUsd
            );
            Position.checkLeverage(
                IMarket(_state.market), _trade.indexToken, _state.sizeDeltaUsd, _state.collateralDeltaUsd
            );
        } else if (_state.requestType == Position.RequestType.POSITION_INCREASE) {
            // Clear the Conditionals
            _trade.conditionals = Position.Conditionals(false, false, 0, 0, 0, 0);
        } else if (_state.requestType == Position.RequestType.POSITION_DECREASE) {
            checkMinCollateral(
                _collateralAmount - _trade.collateralDelta,
                _state.collateralRefPrice,
                _state.collateralBaseUnit,
                _state.minCollateralUsd
            );
            // Clear the Conditionals
            _trade.conditionals = Position.Conditionals(false, false, 0, 0, 0, 0);
        } else if (_state.requestType == Position.RequestType.COLLATERAL_INCREASE) {
            // convert existing collateral amount to usd
            _state.collateralAmountUsd = mulDiv(_collateralAmount, _state.collateralRefPrice, _state.collateralBaseUnit);
            // conver position size to usd
            _state.positionSizeUsd = mulDiv(_positionSize, _state.indexRefPrice, _state.indexBaseUnit);
            // subtract collateral delta usd
            _state.collateralAmountUsd += _state.collateralDeltaUsd;
            // chcek it doesnt go below min leverage
            Position.checkLeverage(
                IMarket(_state.market), _trade.indexToken, _state.positionSizeUsd, _state.collateralAmountUsd
            );
            // Clear the Conditionals
            _trade.conditionals = Position.Conditionals(false, false, 0, 0, 0, 0);
        } else if (_state.requestType == Position.RequestType.COLLATERAL_DECREASE) {
            checkMinCollateral(
                _collateralAmount - _trade.collateralDelta,
                _state.collateralRefPrice,
                _state.collateralBaseUnit,
                _state.minCollateralUsd
            );
            // convert existing collateral amount to usd
            _state.collateralAmountUsd = mulDiv(_collateralAmount, _state.collateralRefPrice, _state.collateralBaseUnit);
            // conver position size to usd
            _state.positionSizeUsd = mulDiv(_positionSize, _state.indexRefPrice, _state.indexBaseUnit);
            // subtract collateral delta usd
            _state.collateralAmountUsd -= _state.collateralDeltaUsd;
            // chcek it doesnt go below min leverage
            Position.checkLeverage(
                IMarket(_state.market), _trade.indexToken, _state.positionSizeUsd, _state.collateralAmountUsd
            );
            // Clear the Conditionals
            _trade.conditionals = Position.Conditionals(false, false, 0, 0, 0, 0);
        } else {
            revert("Order: Invalid Request Type");
        }
        return _state;
    }

    /**
     * ========================= Main Execution Functions =========================
     */

    // @audit - check the position isn't put below min leverage
    // @audit - should we process fees before updating the fee parameters?
    // No Funding Involvement
    function executeCollateralIncrease(
        Position.Data memory _position,
        Position.Execution memory _params,
        ExecutionState memory _state
    ) external view returns (Position.Data memory, ExecutionState memory) {
        // Subtract fee from collateral delta
        _params.request.input.collateralDelta -= _state.fee;
        // Update the Fee Parameters
        _position = _updateFeeParameters(_position, _state);
        // Process any Outstanding Borrow Fees
        (_position, _state.borrowFee) = _processBorrowFees(_position, _params, _state);
        // Calculate the amount of collateral left after fees
        uint256 afterFeeAmount = _params.request.input.collateralDelta - _state.borrowFee;
        require(afterFeeAmount > 0, "Order: After Fee");
        // Edit the Position for Increase
        _position = _editPosition(_position, _state, afterFeeAmount, 0, true);
        // Check the Leverage
        Position.checkLeverage(
            _state.market,
            _params.request.input.indexToken,
            mulDiv(_position.positionSize, _state.indexPrice, _state.indexBaseUnit),
            mulDiv(_position.collateralAmount, _state.collateralPrice, _state.collateralBaseUnit)
        );
        return (_position, _state);
    }

    // No Funding Involvement
    function executeCollateralDecrease(
        Position.Data memory _position,
        Position.Execution memory _params,
        ExecutionState memory _state,
        uint256 _minCollateralUsd,
        uint256 _liquidationFeeUsd
    ) external view returns (Position.Data memory, ExecutionState memory) {
        // Subtract Fee from Collateral Delta
        _params.request.input.collateralDelta -= _state.fee;
        // Update the Fee Parameters
        _position = _updateFeeParameters(_position, _state);
        // Process any Outstanding Borrow  Fees
        (_position, _state.borrowFee) = _processBorrowFees(_position, _params, _state);
        // Edit the Position (subtract full collateral delta)
        _position = _editPosition(_position, _state, _params.request.input.collateralDelta, 0, false);
        // Check if the Decrease puts the position below the min collateral threshold
        require(
            checkMinCollateral(
                _position.collateralAmount, _state.collateralPrice, _state.collateralBaseUnit, _minCollateralUsd
            ),
            "Order: Min Collat"
        );
        // Check if the Decrease makes the Position Liquidatable
        require(!_checkIsLiquidatable(_position, _state, _liquidationFeeUsd), "Order: Liquidatable");
        // Check the Leverage
        Position.checkLeverage(
            _state.market,
            _params.request.input.indexToken,
            mulDiv(_position.positionSize, _state.indexPrice, _state.indexBaseUnit),
            mulDiv(_position.collateralAmount, _state.collateralPrice, _state.collateralBaseUnit)
        );

        return (_position, _state);
    }

    // No Funding Involvement
    // @audit - need to conver fee from index token to collateral token
    function createNewPosition(
        Position.Execution memory _params,
        ExecutionState memory _state,
        uint256 _minCollateralUsd
    ) external view returns (Position.Data memory, ExecutionState memory) {
        // Convert fee from index token to collateral token
        _state.fee = Position.convertIndexAmountToCollateral(
            _state.fee, _state.indexPrice, _state.indexBaseUnit, _state.collateralPrice, _state.collateralBaseUnit
        );
        // Subtract Fee from Collateral Delta
        _params.request.input.collateralDelta -= _state.fee;
        // Check that the Position meets the minimum collateral threshold
        require(
            checkMinCollateral(
                _params.request.input.collateralDelta,
                _state.collateralPrice,
                _state.collateralBaseUnit,
                _minCollateralUsd
            ),
            "Order: Min Collat"
        );
        // Generate the Position
        Position.Data memory position = Position.generateNewPosition(_params.request, _state);
        // Check the Position's Leverage is Valid
        uint256 absSizeDelta = _state.sizeDeltaUsd.abs();
        Position.checkLeverage(
            _state.market, _params.request.input.indexToken, absSizeDelta, _state.collateralDeltaUsd.abs()
        );
        // Return the Position
        return (position, _state);
    }

    // Realise all previous funding and borrowing fees
    // For funding - reset the earnings after charging the previous amount
    function increaseExistingPosition(
        Position.Data memory _position,
        Position.Execution memory _params,
        ExecutionState memory _state
    ) external view returns (Position.Data memory, ExecutionState memory, uint256 sizeDeltaUsd, uint256 positionFee) {
        // Subtract Fee from Collateral Delta - @audit - can I move down to where other fees are subtracted?
        positionFee = Position.convertIndexAmountToCollateral(
            _state.fee, _state.indexPrice, _state.indexBaseUnit, _state.collateralPrice, _state.collateralBaseUnit
        );
        _params.request.input.collateralDelta -= positionFee;
        // Update the Fee Parameters
        _position = _updateFeeParameters(_position, _state);
        // Process any Outstanding Borrow Fees
        (_position, _state.borrowFee) = _processBorrowFees(_position, _params, _state);
        // Process any Outstanding Funding Fees
        (_position, _state.fundingFee) = _processFundingFees(_position, _params, _state);
        // Settle outstanding fees
        _params.request.input.collateralDelta -= _state.borrowFee;
        if (_state.fundingFee < 0) {
            _params.request.input.collateralDelta -= _state.fundingFee.abs();
        } else {
            // @audit - counts as position profit, need to handle accordingly
            // essentially subtract profit from LPs and add to position
            _params.request.input.collateralDelta += _state.fundingFee.abs();
        }

        // Update the Existing Position
        _position = _editPosition(
            _position, _state, _params.request.input.collateralDelta, _params.request.input.sizeDelta, true
        );

        sizeDeltaUsd = _state.sizeDeltaUsd.abs();
        // Check the Leverage
        Position.checkLeverage(
            _state.market,
            _params.request.input.indexToken,
            mulDiv(_position.positionSize, _state.indexPrice, _state.indexBaseUnit),
            mulDiv(_position.collateralAmount, _state.collateralPrice, _state.collateralBaseUnit)
        );

        return (_position, _state, sizeDeltaUsd, positionFee);
    }

    function decreaseExistingPosition(
        Position.Data memory _position,
        Position.Execution memory _params,
        ExecutionState memory _state,
        uint256 _minCollateralUsd,
        uint256 _liquidationFeeUsd
    ) external view returns (Position.Data memory, DecreaseState memory decreaseState, ExecutionState memory) {
        // Subtract Fee from Collateral Delta
        decreaseState.positionFee = Position.convertIndexAmountToCollateral(
            _state.fee, _state.indexPrice, _state.indexBaseUnit, _state.collateralPrice, _state.collateralBaseUnit
        );
        _params.request.input.collateralDelta -= decreaseState.positionFee;
        // Update the Fee Parameters
        _position = _updateFeeParameters(_position, _state);

        if (_params.request.input.collateralDelta == _position.collateralAmount) {
            decreaseState.sizeDelta = _position.positionSize;
        } else {
            decreaseState.sizeDelta =
                mulDiv(_position.positionSize, _params.request.input.collateralDelta, _position.collateralAmount);
        }

        decreaseState.decreasePnl = Pricing.getDecreasePositionPnl(
            _state.indexBaseUnit,
            decreaseState.sizeDelta,
            _position.weightedAvgEntryPrice,
            _state.impactedPrice,
            _state.collateralPrice,
            _state.collateralBaseUnit,
            _position.isLong
        );

        // Process any Outstanding Borrow Fees
        (_position, _state.borrowFee) = _processBorrowFees(_position, _params, _state);
        // Process any Outstanding Funding Fees
        (_position, _state.fundingFee) = _processFundingFees(_position, _params, _state);

        _position =
            _editPosition(_position, _state, _params.request.input.collateralDelta, decreaseState.sizeDelta, false);

        // Calculate the amount of collateral left after fees
        decreaseState.afterFeeAmount = _params.request.input.collateralDelta - _state.borrowFee;
        if (_state.fundingFee < 0) {
            decreaseState.afterFeeAmount -= _state.fundingFee.abs();
        } else {
            decreaseState.afterFeeAmount += _state.fundingFee.abs();
        }

        // Check if the Decrease puts the position below the min collateral threshold
        // Only check these if it's not a full decrease
        if (_position.collateralAmount != 0) {
            require(
                checkMinCollateral(
                    _position.collateralAmount, _state.collateralPrice, _state.collateralBaseUnit, _minCollateralUsd
                ),
                "Order: Min Collat"
            );
            // Check if the Decrease makes the Position Liquidatable
            require(!_checkIsLiquidatable(_position, _state, _liquidationFeeUsd), "Order: Liquidatable");
        }

        return (_position, decreaseState, _state);
    }

    // Checks if a position meets the minimum collateral threshold
    function checkMinCollateral(
        uint256 _collateralAmount,
        uint256 _collateralPriceUsd,
        uint256 _collateralBaseUnit,
        uint256 _minCollateralUsd
    ) public pure returns (bool isValid) {
        uint256 requestCollateralUsd = mulDiv(_collateralAmount, _collateralPriceUsd, _collateralBaseUnit);
        if (requestCollateralUsd < _minCollateralUsd) {
            isValid = false;
        } else {
            isValid = true;
        }
    }

    /**
     * ========================= Internal Helper Functions =========================
     */
    function _updateFeeParameters(Position.Data memory _position, ExecutionState memory _state)
        internal
        view
        returns (Position.Data memory)
    {
        // Borrowing Fees
        _position.borrowingParams.feesOwed = Borrowing.getTotalCollateralFeesOwed(_position, _state);
        (_position.borrowingParams.lastLongCumulativeBorrowFee, _position.borrowingParams.lastShortCumulativeBorrowFee)
        = _position.market.getCumulativeBorrowFees(_position.indexToken);
        return _position;
    }

    /// @dev Applies all changes to an active position
    function _editPosition(
        Position.Data memory _position,
        ExecutionState memory _state,
        uint256 _collateralDelta,
        uint256 _sizeDelta,
        bool _isIncrease
    ) internal view returns (Position.Data memory) {
        _position.lastUpdate = block.timestamp;
        if (_isIncrease) {
            // Increase the Position's collateral
            _position.collateralAmount += _collateralDelta;
            if (_sizeDelta > 0) {
                _position.weightedAvgEntryPrice = Pricing.calculateWeightedAverageEntryPrice(
                    _position.weightedAvgEntryPrice, _position.positionSize, _sizeDelta.toInt256(), _state.impactedPrice
                );
                _position.positionSize += _sizeDelta;
            }
        } else {
            _position.collateralAmount -= _collateralDelta;
            if (_sizeDelta > 0) {
                _position.weightedAvgEntryPrice = Pricing.calculateWeightedAverageEntryPrice(
                    _position.weightedAvgEntryPrice,
                    _position.positionSize,
                    -_sizeDelta.toInt256(),
                    _state.impactedPrice
                );
                _position.positionSize -= _sizeDelta;
            }
        }
        return _position;
    }

    // @gas - duplicate in position
    function _checkIsLiquidatable(
        Position.Data memory _position,
        ExecutionState memory _state,
        uint256 _liquidationFeeUsd
    ) public view returns (bool isLiquidatable) {
        uint256 collateralValueUsd =
            mulDiv(_position.collateralAmount, _state.collateralPrice, _state.collateralBaseUnit);
        uint256 totalFeesOwedUsd = Position.getTotalFeesOwedUsd(_position, _state);
        int256 pnl = Pricing.calculatePnL(_position, _state.indexPrice, _state.indexBaseUnit);
        uint256 losses = _liquidationFeeUsd + totalFeesOwedUsd + (pnl < 0 ? pnl.abs() : 0);
        isLiquidatable = collateralValueUsd <= losses;
    }

    function _processFundingFees(
        Position.Data memory _position,
        Position.Execution memory _params,
        ExecutionState memory _state
    ) internal view returns (Position.Data memory, int256 fundingFee) {
        // Calculate and subtract the funding fee
        (int256 fundingFeeUsd, int256 nextFundingAccrued) = Funding.getFeeForPositionChange(
            _state.market,
            _params.request.input.indexToken,
            _state.indexPrice,
            _state.sizeDeltaUsd,
            _position.lastFundingAccrued
        );
        _position.lastFundingAccrued = nextFundingAccrued;
        // Convert funding fee to collateral amount
        fundingFee = fundingFeeUsd < 0
            ? -_convertValueToCollateral(fundingFeeUsd.abs(), _state.collateralPrice, _state.collateralBaseUnit).toInt256()
            : _convertValueToCollateral(fundingFeeUsd.abs(), _state.collateralPrice, _state.collateralBaseUnit).toInt256();

        return (_position, fundingFee);
    }

    function _processBorrowFees(
        Position.Data memory _position,
        Position.Execution memory _params,
        ExecutionState memory _state
    ) internal view returns (Position.Data memory, uint256 borrowFee) {
        // Calculate and subtract the Borrowing Fee
        borrowFee = Borrowing.getTotalCollateralFeesOwed(_position, _state);
        _position.borrowingParams.feesOwed = 0;
        require(borrowFee <= _params.request.input.collateralDelta, "Order: Fee > CollateralDelta");

        return (_position, borrowFee);
    }

    function _calculateValueUsd(uint256 _tokenAmount, uint256 _tokenPrice, uint256 _tokenBaseUnit, bool _isIncrease)
        internal
        pure
        returns (int256 valueUsd)
    {
        uint256 absValueUsd = Position.getTradeValueUsd(_tokenAmount, _tokenPrice, _tokenBaseUnit);
        valueUsd = _isIncrease ? absValueUsd.toInt256() : -(absValueUsd).toInt256();
    }

    function _convertValueToCollateral(uint256 _valueUsd, uint256 _collateralPrice, uint256 _collateralBaseUnit)
        internal
        pure
        returns (uint256 collateralAmount)
    {
        collateralAmount = mulDiv(_valueUsd, _collateralBaseUnit, _collateralPrice);
    }

    // @audit - We're giving the position extra size by using max price
    /**
     * For Index Tokens:
     *
     * Long & Increase: Max Price
     * Long & Decrease: Min Price
     * Short & Increase: Min Price
     * Short & Decrease: Max Price
     *
     * For Market Tokens:
     *
     * Long & Increase: Min Price
     * Long & Decrease: Max Price
     * Short & Increase: Max Price
     * Short & Decrease: Min Price
     *
     * If the position is a limit / adl order, don't use the block prices, use the latest signed prices
     */
    function retrieveTokenPrices(
        IPriceFeed priceFeed,
        ExecutionState memory _state,
        address _indexToken,
        uint256 _requestBlock,
        bool _isLong,
        bool _isIncrease,
        bool _fetchLatest
    ) public view returns (ExecutionState memory) {
        // Determine price fetch strategy based on whether it's a limit order or not
        uint256 priceFetchBlock = _fetchLatest ? block.number : _requestBlock;
        bool maximizePrice = _isLong != _isIncrease;

        // Fetch index price based on order type and direction
        _state.indexPrice = _fetchLatest
            ? Oracle.getLatestPrice(priceFeed, _indexToken, maximizePrice)
            : _isLong
                ? _isIncrease
                    ? Oracle.getMaxPrice(priceFeed, _indexToken, priceFetchBlock)
                    : Oracle.getMinPrice(priceFeed, _indexToken, priceFetchBlock)
                : _isIncrease
                    ? Oracle.getMinPrice(priceFeed, _indexToken, priceFetchBlock)
                    : Oracle.getMaxPrice(priceFeed, _indexToken, priceFetchBlock);

        // Market Token Prices and Base Units
        (_state.longMarketTokenPrice, _state.shortMarketTokenPrice) = _fetchLatest
            ? Oracle.getLastMarketTokenPrices(priceFeed, maximizePrice)
            : Oracle.getMarketTokenPrices(priceFeed, priceFetchBlock, maximizePrice);

        _state.collateralPrice = _isLong ? _state.longMarketTokenPrice : _state.shortMarketTokenPrice;
        _state.collateralBaseUnit = _isLong ? Oracle.getLongBaseUnit(priceFeed) : Oracle.getShortBaseUnit(priceFeed);

        _state.indexBaseUnit = Oracle.getBaseUnit(priceFeed, _indexToken);

        return _state;
    }
}
