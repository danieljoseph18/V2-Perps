// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IMarket} from "../markets/interfaces/IMarket.sol";
import {IMarketMaker} from "../markets/interfaces/IMarketMaker.sol";
import {Position} from "./Position.sol";
import {MarketUtils} from "../markets/MarketUtils.sol";
import {Funding} from "../libraries/Funding.sol";
import {Borrowing} from "../libraries/Borrowing.sol";
import {mulDiv} from "@prb/math/Common.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Oracle} from "../oracle/Oracle.sol";
import {ITradeStorage} from "./interfaces/ITradeStorage.sol";
import {IPriceFeed} from "../oracle/interfaces/IPriceFeed.sol";
import {PriceImpact} from "../libraries/PriceImpact.sol";
import {MarketUtils} from "../markets/MarketUtils.sol";
import {Referral} from "../referrals/Referral.sol";
import {IReferralStorage} from "../referrals/interfaces/IReferralStorage.sol";
import {console, console2} from "forge-std/Test.sol";

// Library for Handling Trade related logic
library Execution {
    using SignedMath for int256;
    using SafeCast for uint256;

    error Execution_FeeExceedsDelta();
    error Execution_MinCollateralThreshold();
    error Execution_LiquidatablePosition();
    error Execution_FeesExceedCollateralDelta();
    error Execution_InvalidPriceRetrieval();
    error Execution_InvalidRequestKey();
    error Execution_InvalidFeeReceiver();
    error Execution_LimitPriceNotMet(uint256 limitPrice, uint256 markPrice);
    error Execution_PnlToPoolRatioNotExceeded(int256 pnlFactor, uint256 maxPnlFactor);
    error Execution_PositionNotActive();
    error Execution_PNLFactorNotReduced();
    error Execution_PositionExists();

    event AdlTargetRatioReached(address indexed market, int256 pnlFactor, bool isLong);

    /**
     * ========================= Data Structures =========================
     */
    struct DecreaseState {
        int256 decreasePnl;
        uint256 afterFeeAmount;
        bool isLiquidation;
        uint256 feesOwedToUser;
        uint256 feesToAccumulate;
        uint256 liqFee;
        bool isFullDecrease;
    }

    // stated Values for Execution
    struct State {
        uint256 indexPrice;
        uint256 indexBaseUnit;
        uint256 impactedPrice;
        uint256 longMarketTokenPrice;
        uint256 shortMarketTokenPrice;
        uint256 collateralDeltaUsd;
        int256 priceImpactUsd;
        uint256 collateralPrice;
        uint256 collateralBaseUnit;
        uint256 borrowFee;
        int256 fundingFee;
        uint256 fee;
        uint256 affiliateRebate;
        address referrer;
    }

    uint256 private constant LONG_BASE_UNIT = 1e18;
    uint256 private constant SHORT_BASE_UNIT = 1e6;
    uint256 private constant PRECISION = 1e18;

    /**
     * ========================= Construction Functions =========================
     */
    function constructParams(
        IMarket market,
        ITradeStorage tradeStorage,
        IPriceFeed priceFeed,
        IReferralStorage referralStorage,
        bytes32 _orderKey,
        address _feeReceiver
    ) external view returns (State memory state, Position.Request memory request) {
        // Fetch and validate request from key
        request = tradeStorage.getOrder(_orderKey);
        if (request.user == address(0)) revert Execution_InvalidRequestKey();
        if (_feeReceiver == address(0)) revert Execution_InvalidFeeReceiver();
        // Validate the request before continuing execution

        // Fetch and validate price
        state =
            cacheTokenPrices(priceFeed, state, request.input.assetId, request.input.isLong, request.input.isIncrease);

        Position.validateRequest(market, request, state);

        // Check the Price for Limit orders
        if (request.input.isLimit) {
            bool limitPriceCondition;
            // For TP -> Position must be in profit
            if (request.requestType == Position.RequestType.TAKE_PROFIT) {
                limitPriceCondition = request.input.isLong
                    ? state.indexPrice >= request.input.limitPrice
                    : state.indexPrice <= request.input.limitPrice;
            } else {
                limitPriceCondition = request.input.isLong
                    ? state.indexPrice <= request.input.limitPrice
                    : state.indexPrice >= request.input.limitPrice;
            }
            if (!limitPriceCondition) revert Execution_LimitPriceNotMet(request.input.limitPrice, state.indexPrice);
        }

        if (request.input.sizeDelta != 0) {
            // Execute Price Impact
            (state.impactedPrice, state.priceImpactUsd) = PriceImpact.execute(market, request, state);
            console2.log("Price impact after execution: ", state.priceImpactUsd);
            console.log("Impacted Price after execution: ", state.impactedPrice);
            // state Size Delta USD

            MarketUtils.validateAllocation(
                market,
                request.input.assetId,
                request.input.sizeDelta,
                state.collateralPrice,
                state.collateralBaseUnit,
                request.input.isLong
            );
        }

        // Calculate Fee
        state.fee = Position.calculateFee(
            tradeStorage,
            request.input.sizeDelta,
            request.input.collateralDelta,
            state.collateralPrice,
            state.collateralBaseUnit
        );

        // Calculate & Apply Fee Discount for Referral Code
        (state.fee, state.affiliateRebate, state.referrer) =
            Referral.applyFeeDiscount(referralStorage, request.user, state.fee);
    }

    function constructAdlOrder(
        IMarket market,
        ITradeStorage tradeStorage,
        IPriceFeed priceFeed,
        bytes32 _positionKey,
        uint256 _sizeDelta
    )
        external
        view
        returns (
            State memory state,
            Position.Settlement memory params,
            Position.Data memory position,
            uint256 targetPnlFactor,
            int256 startingPnlFactor
        )
    {
        // Check the position in question is active
        position = tradeStorage.getPosition(_positionKey);
        if (position.positionSize == 0) revert Execution_PositionNotActive();
        targetPnlFactor = MarketUtils.getAdlConfig(market, position.assetId).targetPnlFactor;
        // Get current MarketUtils and token data
        state = cacheTokenPrices(priceFeed, state, position.assetId, position.isLong, false);

        // Set the impacted price to the index price => 0 price impact on ADLs
        state.impactedPrice = state.indexPrice;
        state.priceImpactUsd = 0;
        // Get starting PNL Factor
        startingPnlFactor = _getPnlFactor(market, state, position.assetId, position.isLong);
        // fetch max pnl to pool ratio
        uint256 maxPnlFactor = MarketUtils.getMaxPnlFactor(market, position.assetId);

        // Check the PNL Factor is greater than the max PNL Factor
        if (startingPnlFactor.abs() <= maxPnlFactor || startingPnlFactor < 0) {
            revert Execution_PnlToPoolRatioNotExceeded(startingPnlFactor, maxPnlFactor);
        }

        // Construct an ADL Order
        params = Position.createAdlOrder(position, _sizeDelta);
    }

    /**
     * ========================= Main Execution Functions =========================
     */
    function increaseCollateral(
        IMarket market,
        ITradeStorage tradeStorage,
        Position.Settlement memory _params,
        State memory _state,
        bytes32 _positionKey
    ) external view returns (Position.Data memory, State memory) {
        // Fetch and Validate the Position
        Position.Data memory position = tradeStorage.getPosition(_positionKey);
        if (position.user == address(0)) revert Execution_PositionNotActive();
        uint256 collateralBefore = position.collateralAmount;
        uint256 collateralIn = _params.request.input.collateralDelta;

        // Subtract fee from collateral delta
        _params.request.input.collateralDelta -= _state.fee;

        if (_state.affiliateRebate > 0) {
            _params.request.input.collateralDelta -= _state.affiliateRebate;
        }

        // Process any Outstanding Borrow Fees
        (position, _state.borrowFee) = _processBorrowFees(market, position, _params, _state);
        // Process any Outstanding Funding Fees
        (position, _state.fundingFee) = _processFundingFees(market, position, _params, _state);
        // Calculate the amount of collateral left after fees
        if (_state.borrowFee >= _params.request.input.collateralDelta) revert Execution_FeeExceedsDelta();
        uint256 afterFeeAmount = _params.request.input.collateralDelta - _state.borrowFee;
        // Account for Funding
        if (_state.fundingFee < 0) afterFeeAmount -= _state.fundingFee.abs();
        else if (_state.fundingFee > 0) afterFeeAmount += _state.fundingFee.abs();
        // Edit the Position for Increase
        position = _editPosition(position, _state, afterFeeAmount, 0, true);
        // Check the Leverage
        Position.checkLeverage(
            market,
            _params.request.input.assetId,
            position.positionSize,
            mulDiv(position.collateralAmount, _state.collateralPrice, _state.collateralBaseUnit) // Collat in USD
        );
        // Validate the Position Change
        Position.validateCollateralIncrease(
            position,
            collateralBefore,
            collateralIn,
            _state.fee,
            _state.fundingFee,
            _state.borrowFee,
            _state.affiliateRebate
        );
        return (position, _state);
    }

    function decreaseCollateral(
        IMarket market,
        ITradeStorage tradeStorage,
        Position.Settlement memory _params,
        State memory _state,
        uint256 _minCollateralUsd,
        uint256 _liquidationFeeUsd,
        bytes32 _positionKey
    ) external view returns (Position.Data memory, State memory, uint256 amountOut) {
        // Fetch and Validate the Position
        Position.Data memory position = tradeStorage.getPosition(_positionKey);
        if (position.user == address(0)) revert Execution_PositionNotActive();
        uint256 collateralBefore = position.collateralAmount;

        // Process any Outstanding Borrow  Fees
        (position, _state.borrowFee) = _processBorrowFees(market, position, _params, _state);
        // Process any Outstanding Funding Fees
        (position, _state.fundingFee) = _processFundingFees(market, position, _params, _state);
        // Edit the Position (subtract full collateral delta)
        position = _editPosition(position, _state, _params.request.input.collateralDelta, 0, false);
        // Get remaining collateral in USD
        uint256 remainingCollateralUsd =
            mulDiv(position.collateralAmount, _state.collateralPrice, _state.collateralBaseUnit);
        // Check if the Decrease puts the position below the min collateral threshold
        if (remainingCollateralUsd < _minCollateralUsd) revert Execution_MinCollateralThreshold();
        if (_checkIsLiquidatable(market, position, _state, _liquidationFeeUsd)) {
            revert Execution_LiquidatablePosition();
        }
        // Check the Leverage
        Position.checkLeverage(market, _params.request.input.assetId, position.positionSize, remainingCollateralUsd);
        // Get Amount Out
        amountOut = _params.request.input.collateralDelta - _state.fee - _state.affiliateRebate - _state.borrowFee;
        // Add / Subtract funding fees
        if (_state.fundingFee < 0) {
            // User Paid Funding
            amountOut -= _state.fundingFee.abs();
        } else if (_state.fundingFee > 0) {
            // User got Paid Funding
            amountOut += _state.fundingFee.abs();
        }
        // Validate the Position Change
        _validateCollateralDecrease(position, _state, amountOut, collateralBefore);

        return (position, _state, amountOut);
    }

    // No Funding Involvement
    function createNewPosition(
        IMarket market,
        ITradeStorage tradeStorage,
        Position.Settlement memory _params,
        State memory _state,
        uint256 _minCollateralUsd,
        bytes32 _positionKey
    ) external view returns (Position.Data memory, State memory) {
        if (tradeStorage.getPosition(_positionKey).user != address(0)) revert Execution_PositionExists();
        uint256 initialCollateralDelta = _params.request.input.collateralDelta;
        // Subtract Fee from Collateral Delta
        _params.request.input.collateralDelta -= _state.fee;
        // Subtract the fee paid to the refferer
        if (_state.affiliateRebate > 0) {
            _params.request.input.collateralDelta -= _state.affiliateRebate;
        }
        // Cache Collateral Delta in USD
        _state.collateralDeltaUsd =
            mulDiv(_params.request.input.collateralDelta, _state.collateralPrice, _state.collateralBaseUnit);
        // Check that the Position meets the minimum collateral threshold
        if (_state.collateralDeltaUsd < _minCollateralUsd) revert Execution_MinCollateralThreshold();
        // Generate the Position
        Position.Data memory position = Position.generateNewPosition(market, _params.request, _state);
        // Check the Position's Leverage is Valid
        Position.checkLeverage(
            market, _params.request.input.assetId, _params.request.input.sizeDelta, _state.collateralDeltaUsd
        );
        // Validate the Position
        Position.validateNewPosition(
            initialCollateralDelta, position.collateralAmount, _state.fee, _state.affiliateRebate
        );
        // Return the Position
        return (position, _state);
    }

    function increasePosition(
        IMarket market,
        ITradeStorage tradeStorage,
        Position.Settlement memory _params,
        State memory _state,
        bytes32 _positionKey
    ) external view returns (Position.Data memory, State memory) {
        Position.Data memory position = tradeStorage.getPosition(_positionKey);
        if (position.user == address(0)) revert Execution_PositionNotActive();
        uint256 collateralBefore = position.collateralAmount;
        uint256 sizeBefore = position.positionSize;
        uint256 collateralIn = _params.request.input.collateralDelta;
        // Subtract Fee from Collateral Delta
        _params.request.input.collateralDelta -= _state.fee;
        // Process any Outstanding Borrow Fees
        (position, _state.borrowFee) = _processBorrowFees(market, position, _params, _state);
        // Process any Outstanding Funding Fees
        (position, _state.fundingFee) = _processFundingFees(market, position, _params, _state);
        // Settle outstanding fees
        if (_state.borrowFee >= _params.request.input.collateralDelta) revert Execution_FeesExceedCollateralDelta();
        // Subtract fees from collateral delta
        _params.request.input.collateralDelta -= _state.borrowFee;
        // Process the Funding Fee
        if (_state.fundingFee < 0) {
            // User Owes Funding
            _params.request.input.collateralDelta -= _state.fundingFee.abs();
        } else {
            // User has earned funding
            _params.request.input.collateralDelta += _state.fundingFee.abs();
        }
        // Update the Existing Position
        position = _editPosition(
            position, _state, _params.request.input.collateralDelta, _params.request.input.sizeDelta, true
        );
        // Check the Leverage
        Position.checkLeverage(
            market,
            _params.request.input.assetId,
            position.positionSize,
            mulDiv(position.collateralAmount, _state.collateralPrice, _state.collateralBaseUnit)
        );

        // Validate the Position Change
        _validatePositionIncrease(
            position, _state, collateralBefore, sizeBefore, collateralIn, _params.request.input.sizeDelta
        );

        return (position, _state);
    }

    function decreasePosition(
        IMarket market,
        ITradeStorage tradeStorage,
        Position.Settlement memory _params,
        State memory _state,
        uint256 _minCollateralUsd,
        uint256 _liquidationFee,
        bytes32 _positionKey
    ) external view returns (Position.Data memory, DecreaseState memory decreaseState, State memory) {
        // Fetch and Validate the Position
        Position.Data memory position = tradeStorage.getPosition(_positionKey);
        if (position.user == address(0)) revert Execution_PositionNotActive();
        uint256 collateralBefore = position.collateralAmount;
        uint256 sizeBefore = position.positionSize;
        // If SL / TP, clear from the position
        if (_params.request.requestType == Position.RequestType.STOP_LOSS) {
            position.stopLossKey = bytes32(0);
        } else if (_params.request.requestType == Position.RequestType.TAKE_PROFIT) {
            position.takeProfitKey = bytes32(0);
        }
        // Handle case where user wants to close the entire position, but size / collateral aren't proportional
        if (_params.request.input.collateralDelta == position.collateralAmount) {
            _params.request.input.sizeDelta = position.positionSize;
            decreaseState.isFullDecrease = true;
        } else if (_params.request.input.sizeDelta == position.positionSize) {
            _params.request.input.collateralDelta = position.collateralAmount;
            decreaseState.isFullDecrease = true;
        }

        // Process any Outstanding Borrow Fees
        (position, _state.borrowFee) = _processBorrowFees(market, position, _params, _state);
        // Process any Outstanding Funding Fees
        (position, _state.fundingFee) = _processFundingFees(market, position, _params, _state);
        // Calculate Pnl for decrease
        decreaseState.decreasePnl = _calculatePnl(_state, position, _params.request.input.sizeDelta);

        position = _editPosition(
            position, _state, _params.request.input.collateralDelta, _params.request.input.sizeDelta, false
        );

        uint256 losses = _state.borrowFee + _state.fee;

        /**
         * Subtract any losses owed from the position.
         * Positive PNL / Funding is paid from LP, so has no effect on position's collateral
         */
        if (decreaseState.decreasePnl < 0) {
            losses += decreaseState.decreasePnl.abs();
        }
        if (_state.fundingFee < 0) {
            losses += _state.fundingFee.abs();
        }

        // Liquidation Case
        // @audit - check insolvency case -> E.g if liq fee can't be paid etc.
        if (losses >= _params.request.input.collateralDelta) {
            // 1. Calculate the Fees Owed to the User
            decreaseState.feesOwedToUser = _state.fundingFee > 0
                ? mulDiv(_state.fundingFee.abs(), _state.collateralBaseUnit, _state.collateralPrice)
                : 0;
            if (decreaseState.decreasePnl > 0) decreaseState.feesOwedToUser += decreaseState.decreasePnl.abs();
            // 2. Calculate the Fees to Accumulate
            decreaseState.feesToAccumulate = _state.borrowFee;
            // 3. Calculate the Liquidation Fee
            decreaseState.liqFee = mulDiv(position.collateralAmount, _liquidationFee, PRECISION);
            // 4. Set the Liquidation Flag
            decreaseState.isLiquidation = true;
        } else {
            // Calculate the amount of collateral left after fees
            // = Collateral Delta - Borrow Fees - Fee - Losses
            decreaseState.afterFeeAmount = _params.request.input.collateralDelta - losses;

            _validatePositionDecrease(
                position, decreaseState, _state, _params.request.input.sizeDelta, collateralBefore, sizeBefore
            );

            // Check if the Decrease puts the position below the min collateral threshold
            // Only check these if it's not a full decrease
            if (!decreaseState.isFullDecrease) {
                // Get remaining collateral in USD
                uint256 remainingCollateralUsd =
                    mulDiv(position.collateralAmount, _state.collateralPrice, _state.collateralBaseUnit);
                if (remainingCollateralUsd < _minCollateralUsd) revert Execution_MinCollateralThreshold();
            }
        }

        return (position, decreaseState, _state);
    }

    /**
     * ========================= Validation Functions =========================
     */
    function validateAdl(
        IMarket market,
        State memory _state,
        int256 _startingPnlFactor,
        uint256 _targetPnlFactor,
        bytes32 _assetId,
        bool _isLong
    ) external {
        // Get the new PNL to pool ratio
        int256 newPnlFactor = _getPnlFactor(market, _state, _assetId, _isLong);
        // PNL to pool has reduced
        if (newPnlFactor >= _startingPnlFactor) revert Execution_PNLFactorNotReduced();
        // Check if the new PNL to pool ratio is below the threshold
        // Fire event to alert the keepers
        if (newPnlFactor.abs() <= _targetPnlFactor) {
            emit AdlTargetRatioReached(address(market), newPnlFactor, _isLong);
        }
    }

    /**
     * ========================= Oracle Functions =========================
     */

    /**
     * Cache the signed prices for each token
     */
    function cacheTokenPrices(
        IPriceFeed priceFeed,
        State memory _state,
        bytes32 _assetId,
        bool _isLong,
        bool _isIncrease
    ) public view returns (State memory) {
        // Determine price fetch strategy based on whether it's a limit order or not
        bool maximizePrice = _isLong != _isIncrease;

        // Fetch index price based on order type and direction
        _state.indexPrice = _isLong
            ? _isIncrease ? Oracle.getMaxPrice(priceFeed, _assetId) : Oracle.getMinPrice(priceFeed, _assetId)
            : _isIncrease ? Oracle.getMinPrice(priceFeed, _assetId) : Oracle.getMaxPrice(priceFeed, _assetId);

        if (_state.indexPrice == 0) revert Execution_InvalidPriceRetrieval();

        // Market Token Prices and Base Units
        (_state.longMarketTokenPrice, _state.shortMarketTokenPrice) =
            Oracle.getMarketTokenPrices(priceFeed, maximizePrice);

        _state.collateralPrice = _isLong ? _state.longMarketTokenPrice : _state.shortMarketTokenPrice;
        _state.collateralBaseUnit = _isLong ? LONG_BASE_UNIT : SHORT_BASE_UNIT;

        _state.indexBaseUnit = Oracle.getBaseUnit(priceFeed, _assetId);

        return _state;
    }

    /**
     * ========================= Internal Helper Functions =========================
     */
    /// @dev Applies all changes to an active position
    function _editPosition(
        Position.Data memory _position,
        State memory _state,
        uint256 _collateralDelta,
        uint256 _sizeDelta,
        bool _isIncrease
    ) internal view returns (Position.Data memory) {
        _position.lastUpdate = block.timestamp;
        if (_isIncrease) {
            // Increase the Position's collateral
            _position.collateralAmount += _collateralDelta;
            if (_sizeDelta > 0) {
                _position.weightedAvgEntryPrice = MarketUtils.calculateWeightedAverageEntryPrice(
                    _position.weightedAvgEntryPrice, _position.positionSize, _sizeDelta.toInt256(), _state.impactedPrice
                );
                _position.positionSize += _sizeDelta;
            }
        } else {
            _position.collateralAmount -= _collateralDelta;
            if (_sizeDelta > 0) {
                _position.weightedAvgEntryPrice = MarketUtils.calculateWeightedAverageEntryPrice(
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

    function _checkIsLiquidatable(
        IMarket market,
        Position.Data memory _position,
        State memory _state,
        uint256 _liquidationFeeUsd
    ) public view returns (bool isLiquidatable) {
        // Get the value of all collateral remaining in the position
        uint256 collateralValueUsd =
            mulDiv(_position.collateralAmount, _state.collateralPrice, _state.collateralBaseUnit);
        // Get the PNL for the position
        int256 pnl = Position.getPositionPnl(
            _position.positionSize,
            _position.weightedAvgEntryPrice,
            _state.indexPrice,
            _state.indexBaseUnit,
            _position.isLong
        );
        // Get the Borrow Fees Owed in USD
        uint256 borrowingFeesUsd = Position.getTotalBorrowFeesUsd(market, _position);
        // Get the Funding Fees Owed in USD
        int256 fundingFeesUsd = Position.getTotalFundingFees(market, _position, _state.indexPrice);
        // Calculate the total losses
        int256 losses = pnl + borrowingFeesUsd.toInt256() + fundingFeesUsd + _liquidationFeeUsd.toInt256();
        // Check if the losses exceed the collateral value
        if (losses < 0 && losses.abs() > collateralValueUsd) {
            isLiquidatable = true;
        } else {
            isLiquidatable = false;
        }
    }

    function _calculatePnl(State memory _state, Position.Data memory _position, uint256 _sizeDelta)
        internal
        pure
        returns (int256 pnl)
    {
        pnl = Position.getRealizedPnl(
            _position.positionSize,
            _sizeDelta,
            _position.weightedAvgEntryPrice,
            _state.impactedPrice,
            _state.indexBaseUnit,
            _state.collateralPrice,
            _state.collateralBaseUnit,
            _position.isLong
        );
    }

    function _processFundingFees(
        IMarket market,
        Position.Data memory _position,
        Position.Settlement memory _params,
        State memory _state
    ) internal view returns (Position.Data memory, int256 fundingFee) {
        // Calculate and subtract the funding fee
        (int256 fundingFeeUsd, int256 nextFundingAccrued) = Position.getFundingFeeDelta(
            market,
            _params.request.input.assetId,
            _state.indexPrice,
            _params.request.input.sizeDelta,
            _position.fundingParams.lastFundingAccrued
        );
        // Reset the last funding accrued
        _position.fundingParams.lastFundingAccrued = nextFundingAccrued;
        // Store Funding Fees in Collateral Tokens -> Will be Paid out / Settled as PNL with Decrease
        fundingFee += fundingFeeUsd < 0
            ? -mulDiv(fundingFeeUsd.abs(), _state.collateralBaseUnit, _state.collateralPrice).toInt256()
            : mulDiv(fundingFeeUsd.abs(), _state.collateralBaseUnit, _state.collateralPrice).toInt256();
        // Reset the funding owed
        _position.fundingParams.fundingOwed = 0;

        return (_position, fundingFee);
    }

    function _processBorrowFees(
        IMarket market,
        Position.Data memory _position,
        Position.Settlement memory _params,
        State memory _state
    ) internal view returns (Position.Data memory, uint256 borrowFee) {
        // Calculate and subtract the Borrowing Fee
        borrowFee = Position.getTotalBorrowFees(market, _position, _state);

        _position.borrowingParams.feesOwed = 0;
        if (borrowFee > _params.request.input.collateralDelta) revert Execution_FeeExceedsDelta();

        // Update the position's borrowing parameters
        (_position.borrowingParams.lastLongCumulativeBorrowFee, _position.borrowingParams.lastShortCumulativeBorrowFee)
        = MarketUtils.getCumulativeBorrowFees(market, _position.assetId);

        return (_position, borrowFee);
    }

    /**
     * Extrapolated into an internal function to prevent STD Errors
     */
    function _getPnlFactor(IMarket market, Execution.State memory _state, bytes32 _assetId, bool _isLong)
        internal
        view
        returns (int256 pnlFactor)
    {
        pnlFactor = MarketUtils.getPnlFactor(
            market,
            _assetId,
            _state.indexPrice,
            _state.indexBaseUnit,
            _state.collateralPrice,
            _state.collateralBaseUnit,
            _isLong
        );
    }

    function _validateCollateralDecrease(
        Position.Data memory _position,
        Execution.State memory _state,
        uint256 _amountOut,
        uint256 _initialCollateral
    ) internal pure {
        // Validate the Position Change
        Position.validateCollateralDecrease(
            _position,
            _initialCollateral,
            _amountOut,
            _state.fee,
            _state.fundingFee,
            _state.borrowFee,
            _state.affiliateRebate
        );
    }

    function _validatePositionIncrease(
        Position.Data memory _position,
        Execution.State memory _state,
        uint256 _initialCollateral,
        uint256 _initialSize,
        uint256 _collateralIn,
        uint256 _sizeDelta
    ) internal pure {
        Position.validateIncreasePosition(
            _position,
            _initialCollateral,
            _initialSize,
            _collateralIn,
            _state.fee,
            _state.affiliateRebate,
            _state.fundingFee,
            _state.borrowFee,
            _sizeDelta
        );
    }

    /// @dev Internal function to prevent STD Err
    function _validatePositionDecrease(
        Position.Data memory _position,
        Execution.DecreaseState memory _decreaseState,
        Execution.State memory _state,
        uint256 _sizeDelta,
        uint256 _initialCollateral,
        uint256 _initialSize
    ) internal pure {
        Position.validateDecreasePosition(
            _position,
            _initialCollateral,
            _initialSize,
            _decreaseState.afterFeeAmount,
            _state.fee,
            _state.affiliateRebate,
            _decreaseState.decreasePnl,
            _state.fundingFee,
            _state.borrowFee,
            _sizeDelta
        );
    }
}
