// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IMarket} from "../markets/interfaces/IMarket.sol";
import {IVault} from "../markets/interfaces/IVault.sol";
import {Position} from "./Position.sol";
import {MarketUtils} from "../markets/MarketUtils.sol";
import {Funding} from "../libraries/Funding.sol";
import {Borrowing} from "../libraries/Borrowing.sol";
import {Casting} from "../libraries/Casting.sol";
import {Units} from "../libraries/Units.sol";
import {Oracle} from "../oracle/Oracle.sol";
import {ITradeStorage} from "./interfaces/ITradeStorage.sol";
import {IPriceFeed} from "../oracle/interfaces/IPriceFeed.sol";
import {PriceImpact} from "../libraries/PriceImpact.sol";
import {MarketUtils} from "../markets/MarketUtils.sol";
import {Referral} from "../referrals/Referral.sol";
import {IReferralStorage} from "../referrals/interfaces/IReferralStorage.sol";
import {ITradeEngine} from "./interfaces/ITradeEngine.sol";
import {MathUtils} from "../libraries/MathUtils.sol";
import {OwnableRoles} from "../auth/OwnableRoles.sol";
import {MarketId} from "../types/MarketId.sol";

// Library for Handling Trade related logic
library Execution {
    using Casting for uint256;
    using Casting for int256;
    using MathUtils for uint256;
    using Units for uint256;
    using Units for int256;

    error Execution_MinCollateralThreshold();
    error Execution_LiquidatablePosition();
    error Execution_FeesExceedCollateralDelta();
    error Execution_LimitPriceNotMet(uint256 limitPrice, uint256 markPrice);
    error Execution_PnlToPoolRatioNotExceeded(int256 pnlFactor, uint256 maxPnlFactor);
    error Execution_PNLFactorNotReduced();
    error Execution_PositionExists();
    error Execution_PositionNotProfitable();
    error Execution_InvalidPosition();
    error Execution_InvalidExecutor();
    error Execution_ZeroFees();
    error Execution_AccessDenied();
    error Execution_InvalidOrderKey();

    /**
     * =========================================== Data Structures ===========================================
     */
    struct FeeState {
        uint256 afterFeeAmount;
        int256 fundingFee;
        uint256 borrowFee;
        uint256 positionFee;
        uint256 feeForExecutor;
        uint256 affiliateRebate;
        int256 realizedPnl;
        uint256 amountOwedToUser;
        uint256 feesToAccumulate;
        address referrer;
        bool isLiquidation;
        bool isFullDecrease;
    }

    // stated Values for Execution
    struct Prices {
        uint256 indexPrice;
        uint256 indexBaseUnit;
        uint256 impactedPrice;
        uint256 longMarketTokenPrice;
        uint256 shortMarketTokenPrice;
        int256 priceImpactUsd;
        uint256 collateralPrice;
        uint256 collateralBaseUnit;
    }

    uint64 private constant LONG_BASE_UNIT = 1e18;
    uint64 private constant SHORT_BASE_UNIT = 1e6;
    uint64 private constant PRECISION = 1e18;
    uint64 private constant MAX_PNL_FACTOR = 0.45e18;
    uint64 private constant TARGET_PNL_FACTOR = 0.35e18;
    uint64 private constant MIN_PROFIT_PERCENTAGE = 0.05e18;
    uint256 private constant _ROLE_1 = 1 << 1;

    /**
     * =========================================== Construction Functions ===========================================
     */
    function initiate(
        MarketId _id,
        IMarket market,
        IVault vault,
        IPriceFeed priceFeed,
        bytes32 _orderKey,
        bytes32 _requestKey,
        address _feeReceiver
    ) external view returns (Prices memory prices, Position.Request memory request) {
        ITradeStorage tradeStorage = ITradeStorage(msg.sender);
        if (tradeStorage != market.tradeStorage()) revert Execution_AccessDenied();

        request = tradeStorage.getOrder(_id, _orderKey);

        // If the order doesn't exist, revert
        if (request.user == address(0)) revert Execution_InvalidOrderKey();

        if (request.input.isLimit) validatePriceRequest(priceFeed, _feeReceiver, _requestKey);

        prices = getTokenPrices(
            priceFeed,
            request.input.ticker,
            uint48(request.requestTimestamp),
            request.input.isLong,
            request.input.isIncrease
        );

        if (request.input.isLimit) {
            _checkLimitPrice(prices.indexPrice, request.input.limitPrice, request.input.triggerAbove);
        }

        if (request.input.sizeDelta != 0) {
            (prices.impactedPrice, prices.priceImpactUsd) = PriceImpact.execute(_id, market, vault, request, prices);

            if (request.input.isIncrease) {
                MarketUtils.validateAllocation(
                    _id,
                    market,
                    vault,
                    request.input.ticker,
                    request.input.sizeDelta,
                    prices.indexPrice,
                    prices.collateralPrice,
                    prices.indexBaseUnit,
                    request.input.isLong
                );
            }
        }
    }

    function initiateAdlOrder(
        MarketId _id,
        IMarket market,
        IVault vault,
        IPriceFeed priceFeed,
        Position.Data memory _position,
        uint48 _requestTimestamp,
        address _feeReceiver
    ) external view returns (Prices memory prices, Position.Settlement memory params, int256 startingPnlFactor) {
        if (ITradeStorage(msg.sender) != market.tradeStorage()) revert Execution_AccessDenied();

        prices = getTokenPrices(priceFeed, _position.ticker, _requestTimestamp, _position.isLong, false);

        startingPnlFactor = _getPnlFactor(_id, market, vault, prices, _position.ticker, _position.isLong);
        uint256 absPnlFactor = startingPnlFactor.abs();

        if (absPnlFactor < MAX_PNL_FACTOR || startingPnlFactor < 0) {
            revert Execution_PnlToPoolRatioNotExceeded(startingPnlFactor, MAX_PNL_FACTOR);
        }

        int256 pnl = Position.getPositionPnl(
            _position.size, _position.weightedAvgEntryPrice, prices.indexPrice, prices.indexBaseUnit, _position.isLong
        );

        if (pnl < 0) revert Execution_PositionNotProfitable();

        uint256 percentageToAdl = Position.calculateAdlPercentage(absPnlFactor, pnl, _position.size);

        uint256 poolUsd = _getPoolUsd(_id, market, vault, prices, _position.ticker, _position.isLong);
        prices.impactedPrice = _executeAdlImpact(
            prices.indexPrice, _position.weightedAvgEntryPrice, pnl.abs(), poolUsd, absPnlFactor, _position.isLong
        );

        prices.priceImpactUsd = 0;

        params = _createAdlOrder(_position, prices, percentageToAdl, _feeReceiver);
    }

    /**
     * =========================================== Main Execution Functions ===========================================
     */
    function decreaseCollateral(
        MarketId _id,
        IMarket market,
        ITradeStorage tradeStorage,
        IReferralStorage referralStorage,
        Position.Settlement memory _params,
        Prices memory _prices,
        uint256 _minCollateralUsd,
        bytes32 _positionKey
    ) internal view returns (Position.Data memory position, FeeState memory feeState) {
        position = tradeStorage.getPosition(_id, _positionKey);
        if (position.user == address(0)) revert Execution_InvalidPosition();
        if (
            _params.request.input.collateralDelta.toUsd(_prices.collateralPrice, _prices.collateralBaseUnit)
                > position.collateral
        ) revert Execution_InvalidPosition();

        (position, feeState) = _calculateFees(
            _id,
            market,
            referralStorage,
            position,
            feeState,
            _prices,
            _params.request.input.sizeDelta,
            _params.request.input.collateralDelta
        );

        feeState.afterFeeAmount = _calculateAmountAfterFees(
            _params.request.input.collateralDelta,
            feeState.positionFee,
            feeState.feeForExecutor,
            feeState.affiliateRebate,
            feeState.borrowFee,
            feeState.fundingFee
        );

        uint256 collateralDeltaUsd =
            _params.request.input.collateralDelta.toUsd(_prices.collateralPrice, _prices.collateralBaseUnit);

        position = _updatePosition(position, collateralDeltaUsd, 0, _prices.impactedPrice, false);

        uint256 remainingCollateralUsd = position.collateral;

        if (remainingCollateralUsd < _minCollateralUsd) revert Execution_MinCollateralThreshold();

        if (checkIsLiquidatable(_id, market, position, _prices)) revert Execution_LiquidatablePosition();

        Position.checkLeverage(_id, market, _params.request.input.ticker, position.size, remainingCollateralUsd);
    }

    function createNewPosition(
        MarketId _id,
        IMarket market,
        ITradeStorage tradeStorage,
        IReferralStorage referralStorage,
        Position.Settlement memory _params,
        Prices memory _prices,
        uint256 _minCollateralUsd,
        bytes32 _positionKey
    ) internal view returns (Position.Data memory position, FeeState memory feeState) {
        if (tradeStorage.getPosition(_id, _positionKey).user != address(0)) revert Execution_PositionExists();

        feeState = _calculatePositionFees(
            referralStorage,
            feeState,
            _params.request.input.sizeDelta,
            _params.request.input.collateralDelta,
            _prices.collateralPrice,
            _prices.collateralBaseUnit,
            _params.request.user
        );

        feeState.afterFeeAmount = _calculateAmountAfterFees(
            _params.request.input.collateralDelta,
            feeState.positionFee,
            feeState.feeForExecutor,
            feeState.affiliateRebate,
            feeState.borrowFee,
            feeState.fundingFee
        );

        uint256 collateralDeltaUsd = feeState.afterFeeAmount.toUsd(_prices.collateralPrice, _prices.collateralBaseUnit);

        if (collateralDeltaUsd < _minCollateralUsd) revert Execution_MinCollateralThreshold();

        position = Position.generateNewPosition(_id, market, _params.request, _prices.impactedPrice, collateralDeltaUsd);

        Position.checkLeverage(
            _id, market, _params.request.input.ticker, _params.request.input.sizeDelta, collateralDeltaUsd
        );
    }

    function increasePosition(
        MarketId _id,
        IMarket market,
        ITradeStorage tradeStorage,
        IReferralStorage referralStorage,
        Position.Settlement memory _params,
        Prices memory _prices,
        bytes32 _positionKey
    ) internal view returns (FeeState memory feeState, Position.Data memory position) {
        position = tradeStorage.getPosition(_id, _positionKey);
        if (position.user == address(0)) revert Execution_InvalidPosition();

        (position, feeState) = _calculateFees(
            _id,
            market,
            referralStorage,
            position,
            feeState,
            _prices,
            _params.request.input.sizeDelta,
            _params.request.input.collateralDelta
        );

        feeState.afterFeeAmount = _calculateAmountAfterFees(
            _params.request.input.collateralDelta,
            feeState.positionFee,
            feeState.feeForExecutor,
            feeState.affiliateRebate,
            feeState.borrowFee,
            feeState.fundingFee
        );

        uint256 collateralDeltaUsd = feeState.afterFeeAmount.toUsd(_prices.collateralPrice, _prices.collateralBaseUnit);

        position =
            _updatePosition(position, collateralDeltaUsd, _params.request.input.sizeDelta, _prices.impactedPrice, true);

        Position.checkLeverage(_id, market, position.ticker, position.size, position.collateral);
    }

    function decreasePosition(
        MarketId _id,
        IMarket market,
        ITradeStorage tradeStorage,
        IReferralStorage referralStorage,
        Position.Settlement memory _params,
        Prices memory _prices,
        uint256 _minCollateralUsd,
        uint256 _alternativeFee, // covers liquidations and adls
        bytes32 _positionKey
    ) internal view returns (Position.Data memory position, FeeState memory feeState) {
        position = tradeStorage.getPosition(_id, _positionKey);
        if (position.user == address(0)) revert Execution_InvalidPosition();

        if (_params.request.requestType == Position.RequestType.STOP_LOSS) {
            position.stopLossKey = bytes32(0);
        } else if (_params.request.requestType == Position.RequestType.TAKE_PROFIT) {
            position.takeProfitKey = bytes32(0);
        }

        (_params.request.input.collateralDelta, _params.request.input.sizeDelta, feeState.isFullDecrease) =
            _validateCollateralDelta(position, _params, _prices);

        (position, feeState) = _calculateFees(
            _id,
            market,
            referralStorage,
            position,
            feeState,
            _prices,
            _params.request.input.sizeDelta,
            _params.request.input.collateralDelta
        );

        // No Calculation for After Fee Amount here: liquidations can be insolvent, so it's only caclulated for the decrease case.
        feeState.realizedPnl = _calculatePnl(_prices, position, _params.request.input.sizeDelta);

        if (_params.isAdl) {
            feeState.feeForExecutor = _calculateFeeForAdl(
                _params.request.input.sizeDelta, _prices.collateralPrice, _prices.collateralBaseUnit, _alternativeFee
            );
        }

        uint256 losses = feeState.borrowFee + feeState.positionFee + feeState.feeForExecutor + feeState.affiliateRebate;

        if (feeState.realizedPnl < 0) losses += feeState.realizedPnl.abs();

        if (feeState.fundingFee < 0) losses += feeState.fundingFee.abs();

        uint256 maintenanceCollateral = _getMaintenanceCollateral(_id, market, position);

        if (losses.toUsd(_prices.collateralPrice, _prices.collateralBaseUnit) >= maintenanceCollateral) {
            (_params, feeState) =
                _initiateLiquidation(_params, _prices, feeState, position.size, position.collateral, _alternativeFee);
        } else {
            (position, feeState.afterFeeAmount) =
                _initiateDecreasePosition(_id, market, _params, position, _prices, feeState, _minCollateralUsd);
        }
    }

    /**
     * =========================================== Validation Functions ===========================================
     */
    function validateAdl(
        MarketId _id,
        IMarket market,
        IVault vault,
        Prices memory _prices,
        int256 _startingPnlFactor,
        string memory _ticker,
        bool _isLong
    ) internal view {
        int256 newPnlFactor = _getPnlFactor(_id, market, vault, _prices, _ticker, _isLong);

        if (newPnlFactor >= _startingPnlFactor) revert Execution_PNLFactorNotReduced();
    }

    /**
     * @dev This function ensures that those who request a price update are given a time window to enable
     * them to execute the request and claim the execution fee.
     *
     * This is required for alternative orders, where keepers are required to watch active orders
     * and execute them once valid.
     *
     * Without this check, any user could wait for another to request a price update and then execute the order
     * themselves, undeservedly claiming the execution fee.
     *
     * After timeToExpiration, anyone can execute the request.
     */
    function validatePriceRequest(IPriceFeed priceFeed, address _caller, bytes32 _requestKey) internal view {
        IPriceFeed.RequestData memory data = priceFeed.getRequestData(_requestKey);

        if (data.requester != _caller) {
            // If the caller is not the requester, they must wait for the timeToExpiration to execute the request
            if (block.timestamp < data.blockTimestamp + priceFeed.timeToExpiration()) {
                revert Execution_InvalidExecutor();
            }
        }
    }

    /**
     * =========================================== Oracle Functions ===========================================
     */

    /**
     * Cache the signed prices for each token
     * If request is limit, the keeper should've requested a price update themselves.
     * If the request is a market, simply fetch and fulfill the request, making sure it exists
     */
    function getTokenPrices(
        IPriceFeed priceFeed,
        string memory _indexTicker,
        uint48 _requestTimestamp,
        bool _isLong,
        bool _isIncrease
    ) public view returns (Prices memory prices) {
        // Determine whether to maximize or minimize price to round in protocol's favor
        bool maximizePrice = _isLong != _isIncrease;

        prices.indexPrice = _isLong
            ? _isIncrease
                ? Oracle.getMaxPrice(priceFeed, _indexTicker, _requestTimestamp)
                : Oracle.getMinPrice(priceFeed, _indexTicker, _requestTimestamp)
            : _isIncrease
                ? Oracle.getMinPrice(priceFeed, _indexTicker, _requestTimestamp)
                : Oracle.getMaxPrice(priceFeed, _indexTicker, _requestTimestamp);

        if (maximizePrice) {
            (prices.longMarketTokenPrice, prices.shortMarketTokenPrice) =
                Oracle.getMaxVaultPrices(priceFeed, _requestTimestamp);
        } else {
            (prices.longMarketTokenPrice, prices.shortMarketTokenPrice) =
                Oracle.getMinVaultPrices(priceFeed, _requestTimestamp);
        }

        prices.collateralPrice = _isLong ? prices.longMarketTokenPrice : prices.shortMarketTokenPrice;
        prices.collateralBaseUnit = _isLong ? LONG_BASE_UNIT : SHORT_BASE_UNIT;

        prices.indexBaseUnit = Oracle.getBaseUnit(priceFeed, _indexTicker);
    }

    function checkIsLiquidatable(MarketId _id, IMarket market, Position.Data memory _position, Prices memory _prices)
        public
        view
        returns (bool isLiquidatable)
    {
        int256 pnl = Position.getPositionPnl(
            _position.size, _position.weightedAvgEntryPrice, _prices.indexPrice, _prices.indexBaseUnit, _position.isLong
        );

        uint256 borrowingFeesUsd = Position.getTotalBorrowFeesUsd(_id, market, _position);

        int256 fundingFeesUsd = Position.getTotalFundingFees(_id, market, _position, _prices.indexPrice);

        int256 losses = pnl + borrowingFeesUsd.toInt256() + fundingFeesUsd;

        if (losses < 0 && losses.abs() > _position.collateral) {
            isLiquidatable = true;
        } else {
            isLiquidatable = false;
        }
    }

    /**
     * =========================================== Private Helper Functions ===========================================
     */
    /// @dev Applies all changes to an active position
    function _updatePosition(
        Position.Data memory _position,
        uint256 _collateralDeltaUsd,
        uint256 _sizeDelta,
        uint256 _impactedPrice,
        bool _isIncrease
    ) private view returns (Position.Data memory) {
        _position.lastUpdate = uint48(block.timestamp);

        if (_isIncrease) {
            _position.collateral += _collateralDeltaUsd;

            if (_sizeDelta > 0) {
                _position.weightedAvgEntryPrice = MarketUtils.calculateWeightedAverageEntryPrice(
                    _position.weightedAvgEntryPrice, _position.size, _sizeDelta.toInt256(), _impactedPrice
                );

                _position.size += _sizeDelta;
            }
        } else {
            _position.collateral -= _collateralDeltaUsd;

            if (_sizeDelta > 0) {
                _position.weightedAvgEntryPrice = MarketUtils.calculateWeightedAverageEntryPrice(
                    _position.weightedAvgEntryPrice, _position.size, -_sizeDelta.toInt256(), _impactedPrice
                );

                _position.size -= _sizeDelta;
            }
        }

        return _position;
    }

    function _createAdlOrder(
        Position.Data memory _position,
        Prices memory _prices,
        uint256 _percentageToAdl,
        address _feeReceiver
    ) private view returns (Position.Settlement memory) {
        uint256 sizeDelta = _position.size.percentage(_percentageToAdl);

        uint256 collateralDelta = _position.collateral.percentage(_percentageToAdl).fromUsd(
            _prices.collateralPrice, _prices.collateralBaseUnit
        );

        return Position.createAdlOrder(_position, sizeDelta, collateralDelta, _feeReceiver);
    }

    function _calculateFees(
        MarketId _id,
        IMarket market,
        IReferralStorage referralStorage,
        Position.Data memory _position,
        FeeState memory _feeState,
        Prices memory _prices,
        uint256 _sizeDelta,
        uint256 _collateralDelta
    ) private view returns (Position.Data memory, FeeState memory) {
        _feeState = _calculatePositionFees(
            referralStorage,
            _feeState,
            _sizeDelta,
            _collateralDelta,
            _prices.collateralPrice,
            _prices.collateralBaseUnit,
            _position.user
        );

        (_position, _feeState.borrowFee) = _processBorrowFees(_id, market, _position, _prices);

        (_position, _feeState.fundingFee) = _processFundingFees(_id, market, _position, _prices, _sizeDelta);

        return (_position, _feeState);
    }

    function _calculatePnl(Prices memory _prices, Position.Data memory _position, uint256 _sizeDelta)
        private
        pure
        returns (int256 pnl)
    {
        pnl = Position.getRealizedPnl(
            _position.size,
            _sizeDelta,
            _position.weightedAvgEntryPrice,
            _prices.impactedPrice,
            _prices.indexBaseUnit,
            _prices.collateralPrice,
            _prices.collateralBaseUnit,
            _position.isLong
        );
    }

    function _calculateFeeForAdl(
        uint256 _sizeDelta,
        uint256 _collateralPrice,
        uint256 _collateralBaseUnit,
        uint256 _adlFeePercentage
    ) private pure returns (uint256 adlFee) {
        uint256 adlFeeUsd = _sizeDelta.percentage(_adlFeePercentage);

        adlFee = adlFeeUsd.fromUsd(_collateralPrice, _collateralBaseUnit);
    }

    function _processFundingFees(
        MarketId _id,
        IMarket market,
        Position.Data memory _position,
        Prices memory _prices,
        uint256 _sizeDelta
    ) private view returns (Position.Data memory, int256 fundingFee) {
        (int256 fundingFeeUsd, int256 nextFundingAccrued) = Position.getFundingFeeDelta(
            _id, market, _position.ticker, _prices.indexPrice, _sizeDelta, _position.fundingParams.lastFundingAccrued
        );

        _position.fundingParams.lastFundingAccrued = nextFundingAccrued;

        fundingFee += fundingFeeUsd < 0
            ? -fundingFeeUsd.fromUsdSigned(_prices.collateralPrice, _prices.collateralBaseUnit).toInt256()
            : fundingFeeUsd.fromUsdSigned(_prices.collateralPrice, _prices.collateralBaseUnit).toInt256();

        _position.fundingParams.fundingOwed = 0;

        return (_position, fundingFee);
    }

    function _processBorrowFees(MarketId _id, IMarket market, Position.Data memory _position, Prices memory _prices)
        private
        view
        returns (Position.Data memory, uint256 borrowFee)
    {
        borrowFee = Position.getTotalBorrowFees(_id, market, _position, _prices);

        _position.borrowingParams.feesOwed = 0;

        (_position.borrowingParams.lastLongCumulativeBorrowFee, _position.borrowingParams.lastShortCumulativeBorrowFee)
        = market.getCumulativeBorrowFees(_id, _position.ticker);

        return (_position, borrowFee);
    }

    function _initiateLiquidation(
        Position.Settlement memory _params,
        Prices memory _prices,
        FeeState memory _feeState,
        uint256 _positionSize,
        uint256 _collateralAmount,
        uint256 _liquidationFee
    ) private pure returns (Position.Settlement memory, FeeState memory) {
        _params.request.input.collateralDelta =
            _collateralAmount.fromUsd(_prices.collateralPrice, _prices.collateralBaseUnit);

        _params.request.input.sizeDelta = _positionSize;

        _feeState.amountOwedToUser = _feeState.fundingFee > 0
            ? _feeState.fundingFee.fromUsdSigned(_prices.collateralPrice, _prices.collateralBaseUnit)
            : 0;

        if (_feeState.realizedPnl > 0) _feeState.amountOwedToUser += _feeState.realizedPnl.abs();

        _feeState.feesToAccumulate = _feeState.borrowFee + _feeState.positionFee;

        _feeState.feeForExecutor = _params.request.input.collateralDelta.percentage(_liquidationFee);

        _feeState.affiliateRebate = 0;

        _feeState.isLiquidation = true;

        _feeState.isFullDecrease = true;

        return (_params, _feeState);
    }

    function _initiateDecreasePosition(
        MarketId _id,
        IMarket market,
        Position.Settlement memory _params,
        Position.Data memory _position,
        Prices memory _prices,
        FeeState memory _feeState,
        uint256 _minCollateralUsd
    ) private view returns (Position.Data memory, uint256) {
        _feeState.afterFeeAmount = _calculateAmountAfterFees(
            _params.request.input.collateralDelta,
            _feeState.positionFee,
            _feeState.feeForExecutor,
            _feeState.affiliateRebate,
            _feeState.borrowFee,
            _feeState.fundingFee
        );

        _position = _updatePosition(
            _position,
            _params.request.input.collateralDelta.toUsd(_prices.collateralPrice, _prices.collateralBaseUnit),
            _params.request.input.sizeDelta,
            _prices.impactedPrice,
            false
        );

        _feeState.afterFeeAmount = _feeState.realizedPnl > 0
            ? _feeState.afterFeeAmount + _feeState.realizedPnl.abs()
            : _feeState.afterFeeAmount - _feeState.realizedPnl.abs();

        // Check if the Decrease puts the position below the min collateral threshold
        // Only check these if it's not a full decrease
        if (!_feeState.isFullDecrease) {
            if (_position.collateral < _minCollateralUsd) revert Execution_MinCollateralThreshold();

            Position.checkLeverage(_id, market, _position.ticker, _position.size, _position.collateral);
        }

        return (_position, _feeState.afterFeeAmount);
    }

    function _calculatePositionFees(
        IReferralStorage referralStorage,
        FeeState memory _feeState,
        uint256 _sizeDelta,
        uint256 _collateralDelta,
        uint256 _collateralPrice,
        uint256 _collateralBaseUnit,
        address _user
    ) private view returns (FeeState memory) {
        (_feeState.positionFee, _feeState.feeForExecutor) = Position.calculateFee(
            ITradeEngine(address(this)).tradingFee(),
            ITradeEngine(address(this)).feeForExecution(),
            _sizeDelta,
            _collateralDelta,
            _collateralPrice,
            _collateralBaseUnit
        );

        (_feeState.positionFee, _feeState.affiliateRebate, _feeState.referrer) =
            Referral.applyFeeDiscount(referralStorage, _user, _feeState.positionFee);

        if (_feeState.positionFee == 0 || _feeState.feeForExecutor == 0) revert Execution_ZeroFees();

        return _feeState;
    }
    /**
     * Adjusts the execution price for ADL'd positions within specific boundaries to maintain market health.
     * Impacted price is clamped between the average entry price (adjusted for a min profit) & index price.
     *
     * Steps:
     * 1. Calculate acceleration factor based on the delta between the current PnL to pool ratio and the target ratio.
     *    accelerationFactor = (pnl to pool ratio - target pnl ratio) / target pnl ratio
     *
     * 2. Compute the effective PnL impact adjusted by this acceleration factor.
     *    pnlImpact = pnlBeingRealized * accelerationFactor
     *
     * 3. Determine the impact this PnL has as a percentage of the total pool.
     *    poolImpact = pnlImpact / _poolUsd (Capped at 100%)
     *
     * 4. Calculate min profit price (price where profit = minProfitPercentage)
     *    minProfitPrice = _averageEntryPrice +- (_averageEntryPrice * minProfitPercentage)
     *
     * 5. Calculate the price delta based on the pool impact.
     *    priceDelta = (_indexPrice - minProfitPrice) * poolImpact --> returns a % of the max price delta
     *
     * 6. Apply the price delta to the index price.
     *    impactedPrice = _indexPrice =- priceDelta
     *
     * This function is crucial for ensuring market solvency in extreme situations.
     */

    function _executeAdlImpact(
        uint256 _indexPrice,
        uint256 _averageEntryPrice,
        uint256 _pnlBeingRealized,
        uint256 _poolUsd,
        uint256 _pnlToPoolRatio,
        bool _isLong
    ) private pure returns (uint256 impactedPrice) {
        uint256 accelerationFactor = (_pnlToPoolRatio - TARGET_PNL_FACTOR).percentage(TARGET_PNL_FACTOR);

        uint256 pnlImpact = _pnlBeingRealized * accelerationFactor / PRECISION;

        uint256 poolImpact = pnlImpact.percentage(_poolUsd);

        if (poolImpact > PRECISION) poolImpact = PRECISION;

        // Calculate the minimum profit price for the position, where profit = 5% of position (average entry price +- 5%)
        uint256 minProfitPrice = _isLong
            ? _averageEntryPrice + (_averageEntryPrice.percentage(MIN_PROFIT_PERCENTAGE))
            : _averageEntryPrice - (_averageEntryPrice.percentage(MIN_PROFIT_PERCENTAGE));

        uint256 priceDelta = (_indexPrice.absDiff(minProfitPrice) * poolImpact) / PRECISION;

        if (_isLong) impactedPrice = _indexPrice - priceDelta;
        else impactedPrice = _indexPrice + priceDelta;
    }

    /// @dev Private function to prevent STD Error
    function _getPnlFactor(
        MarketId _id,
        IMarket market,
        IVault vault,
        Prices memory _prices,
        string memory _ticker,
        bool _isLong
    ) private view returns (int256 pnlFactor) {
        pnlFactor = MarketUtils.getPnlFactor(
            _id,
            market,
            vault,
            _ticker,
            _prices.indexPrice,
            _prices.indexBaseUnit,
            _prices.collateralPrice,
            _prices.collateralBaseUnit,
            _isLong
        );
    }

    function _checkLimitPrice(uint256 _indexPrice, uint256 _limitPrice, bool _triggerAbove) private pure {
        bool limitPriceCondition = _triggerAbove ? _indexPrice >= _limitPrice : _indexPrice <= _limitPrice;
        if (!limitPriceCondition) revert Execution_LimitPriceNotMet(_limitPrice, _indexPrice);
    }

    /// @dev Private function to prevent STD Error
    function _getPoolUsd(
        MarketId _id,
        IMarket market,
        IVault vault,
        Prices memory _prices,
        string memory _ticker,
        bool _isLong
    ) private view returns (uint256 poolUsd) {
        return MarketUtils.getPoolBalanceUsd(
            _id, market, vault, _ticker, _prices.collateralPrice, _prices.collateralBaseUnit, _isLong
        );
    }

    function _calculateAmountAfterFees(
        uint256 _collateralDelta,
        uint256 _positionFee,
        uint256 _feeForExecutor,
        uint256 _affiliateRebate,
        uint256 _borrowFee,
        int256 _fundingFee
    ) private pure returns (uint256 afterFeeAmount) {
        uint256 totalFees = _positionFee + _feeForExecutor + _affiliateRebate + _borrowFee;

        if (_fundingFee < 0) totalFees += _fundingFee.abs();
        else afterFeeAmount += _fundingFee.abs();

        if (totalFees >= _collateralDelta) revert Execution_FeesExceedCollateralDelta();

        afterFeeAmount = _collateralDelta - totalFees;
    }

    function _validateCollateralDelta(
        Position.Data memory _position,
        Position.Settlement memory _params,
        Prices memory _prices
    ) private pure returns (uint256 collateralDelta, uint256 sizeDelta, bool isFullDecrease) {
        if (
            _params.request.input.sizeDelta >= _position.size
                || _params.request.input.collateralDelta.toUsd(_prices.collateralPrice, _prices.collateralBaseUnit)
                    >= _position.collateral
        ) {
            collateralDelta = _position.collateral.fromUsd(_prices.collateralPrice, _prices.collateralBaseUnit);
            sizeDelta = _position.size;
            isFullDecrease = true;
        } else if (_params.request.input.collateralDelta == 0) {
            // If no collateral delta specified, make it proportional with size delta
            collateralDelta = _position.collateral.percentage(_params.request.input.sizeDelta, _position.size).fromUsd(
                _prices.collateralPrice, _prices.collateralBaseUnit
            );
            sizeDelta = _params.request.input.sizeDelta;
        } else {
            collateralDelta = _params.request.input.collateralDelta;
            sizeDelta = _params.request.input.sizeDelta;
        }
    }

    function _getMaintenanceCollateral(MarketId _id, IMarket market, Position.Data memory _position)
        private
        view
        returns (uint256 maintenanceCollateral)
    {
        uint256 maintenancePercentage = market.getMaintenanceMargin(_id, _position.ticker).expandDecimals(4, 18);
        maintenanceCollateral = _position.collateral.percentage(maintenancePercentage);
    }
}
