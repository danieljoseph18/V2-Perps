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
import {EnumerableSetLib} from "../libraries/EnumerableSetLib.sol";
import {MathUtils} from "../libraries/MathUtils.sol";
import {OwnableRoles} from "../auth/OwnableRoles.sol";

// Library for Handling Trade related logic
library Execution {
    using Casting for uint256;
    using Casting for int256;
    using MathUtils for uint256;
    using Units for uint256;
    using Units for int256;
    using EnumerableSetLib for EnumerableSetLib.Bytes32Set;

    error Execution_MinCollateralThreshold();
    error Execution_LiquidatablePosition();
    error Execution_FeesExceedCollateralDelta();
    error Execution_LimitPriceNotMet(uint256 limitPrice, uint256 markPrice);
    error Execution_PnlToPoolRatioNotExceeded(int256 pnlFactor, uint256 maxPnlFactor);
    error Execution_PositionNotActive();
    error Execution_PNLFactorNotReduced();
    error Execution_PositionExists();
    error Execution_PositionNotProfitable();
    error Execution_InvalidPosition();
    error Execution_InvalidExecutor();
    error Execution_StopLossAlreadySet();
    error Execution_TakeProfitAlreadySet();
    error Execution_OrderAlreadyExists();
    error Execution_OrderAdditionFailed();
    error Execution_ZeroFees();
    error Execution_AccessDenied();

    /**
     * ========================= Data Structures =========================
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

    /**
     * ========================= Construction Functions =========================
     */
    function initiate(
        ITradeStorage tradeStorage,
        IMarket market,
        IVault vault,
        IPriceFeed priceFeed,
        bytes32 _orderKey,
        bytes32 _requestKey,
        address _feeReceiver
    ) external view returns (Prices memory prices, Position.Request memory request) {
        // Check caller is TradeEngine for Market
        if (OwnableRoles(address(market)).rolesOf(msg.sender) != 1 << 5) revert Execution_AccessDenied();
        // Fetch and validate request from key
        request = tradeStorage.getOrder(_orderKey);
        // Validate the request before continuing execution
        if (request.input.isLimit) validatePriceRequest(priceFeed, _feeReceiver, _requestKey);

        // Fetch and validate price
        prices = getTokenPrices(
            priceFeed,
            request.input.ticker,
            uint48(request.requestTimestamp),
            request.input.isLong,
            request.input.isIncrease
        );
        // Check the Limit Price if it's a limit order
        if (request.input.isLimit) {
            _checkLimitPrice(prices.indexPrice, request.input.limitPrice, request.input.triggerAbove);
        }

        if (request.input.sizeDelta != 0) {
            // Execute Price Impact
            (prices.impactedPrice, prices.priceImpactUsd) = PriceImpact.execute(market, vault, request, prices);

            // Validate the available allocation if increase
            if (request.input.isIncrease) {
                MarketUtils.validateAllocation(
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
        IMarket market,
        IVault vault,
        IPriceFeed priceFeed,
        Position.Data memory _position,
        uint48 _requestTimestamp,
        address _feeReceiver
    ) external view returns (Prices memory prices, Position.Settlement memory params, int256 startingPnlFactor) {
        // Check caller is TradeEngine for Market
        if (OwnableRoles(address(market)).rolesOf(msg.sender) != 1 << 5) revert Execution_AccessDenied();
        // Get current MarketUtils and token data
        prices = getTokenPrices(priceFeed, _position.ticker, _requestTimestamp, _position.isLong, false);

        // Get starting PNL Factor
        startingPnlFactor = _getPnlFactor(market, vault, prices, _position.ticker, _position.isLong);
        uint256 absPnlFactor = startingPnlFactor.abs();

        // Check the PNL Factor is greater than the max PNL Factor
        if (absPnlFactor < MAX_PNL_FACTOR || startingPnlFactor < 0) {
            revert Execution_PnlToPoolRatioNotExceeded(startingPnlFactor, MAX_PNL_FACTOR);
        }

        // Check the Position being ADLd is profitable
        int256 pnl = Position.getPositionPnl(
            _position.size, _position.weightedAvgEntryPrice, prices.indexPrice, prices.indexBaseUnit, _position.isLong
        );

        if (pnl < 0) revert Execution_PositionNotProfitable();

        // Calculate the Percentage to ADL
        uint256 adlPercentage = Position.calculateAdlPercentage(absPnlFactor, pnl, _position.size);
        // Execute the ADL impact
        uint256 poolUsd = _getPoolUsd(market, vault, prices, _position.ticker, _position.isLong);
        prices.impactedPrice = _executeAdlImpact(
            prices.indexPrice, _position.weightedAvgEntryPrice, pnl.abs(), poolUsd, absPnlFactor, _position.isLong
        );

        prices.priceImpactUsd = 0;

        // Construct an ADL Order
        params = _createAdlOrder(_position, prices, adlPercentage, _feeReceiver);
    }

    /**
     * ========================= Main Execution Functions =========================
     */

    /// @notice Creates a new Order Request
    function createOrderRequest(Position.Request calldata _request, EnumerableSetLib.Bytes32Set storage orderSet)
        internal
    {
        ITradeStorage tradeStorage = ITradeStorage(address(this));
        // Generate the Key
        bytes32 orderKey = Position.generateOrderKey(_request);
        // Check if the Order already exists
        if (orderSet.contains(orderKey)) revert Execution_OrderAlreadyExists();
        // Add the Order to the Set
        bool success = orderSet.add(orderKey);
        if (!success) revert Execution_OrderAdditionFailed();
        // Add the order to the mapping
        tradeStorage.createOrder(_request);
        // If SL / TP, tie to the position
        _attachConditionalOrder(tradeStorage, _request, orderKey);
    }

    function decreaseCollateral(
        IMarket market,
        ITradeStorage tradeStorage,
        IReferralStorage referralStorage,
        Position.Settlement memory _params,
        Prices memory _prices,
        uint256 _minCollateralUsd,
        bytes32 _positionKey
    ) internal view returns (Position.Data memory position, FeeState memory feeState) {
        // Fetch and Validate the Position
        position = tradeStorage.getPosition(_positionKey);
        if (position.user == address(0)) revert Execution_InvalidPosition();
        // If collateral delta > collateral, revert
        if (
            _params.request.input.collateralDelta.toUsd(_prices.collateralPrice, _prices.collateralBaseUnit)
                > position.collateral
        ) revert Execution_InvalidPosition();

        // Calculate Fees
        (position, feeState) = _calculateFees(
            market,
            tradeStorage,
            referralStorage,
            position,
            feeState,
            _prices,
            _params.request.input.sizeDelta,
            _params.request.input.collateralDelta
        );

        // Get Amount Out
        feeState.afterFeeAmount = _calculateAmountAfterFees(
            _params.request.input.collateralDelta,
            feeState.positionFee,
            feeState.feeForExecutor,
            feeState.affiliateRebate,
            feeState.borrowFee,
            feeState.fundingFee
        );
        // Edit the Position (subtract full collateral delta)
        uint256 collateralDeltaUsd =
            _params.request.input.collateralDelta.toUsd(_prices.collateralPrice, _prices.collateralBaseUnit);
        position = _updatePosition(position, collateralDeltaUsd, 0, _prices.impactedPrice, false);
        // Get remaining collateral in USD
        uint256 remainingCollateralUsd = position.collateral;
        // Check if the Decrease puts the position below the min collateral threshold
        if (remainingCollateralUsd < _minCollateralUsd) revert Execution_MinCollateralThreshold();
        if (checkIsLiquidatable(market, position, _prices)) revert Execution_LiquidatablePosition();
        // Check the Leverage
        Position.checkLeverage(market, _params.request.input.ticker, position.size, remainingCollateralUsd);
    }

    // No Funding Involvement
    function createNewPosition(
        IMarket market,
        ITradeStorage tradeStorage,
        IReferralStorage referralStorage,
        Position.Settlement memory _params,
        Prices memory _prices,
        uint256 _minCollateralUsd,
        bytes32 _positionKey
    ) internal view returns (Position.Data memory position, FeeState memory feeState) {
        if (tradeStorage.getPosition(_positionKey).user != address(0)) revert Execution_PositionExists();

        // Calculate Fee + Fee for executor
        feeState = _calculatePositionFees(
            tradeStorage,
            referralStorage,
            _params.request.input.sizeDelta,
            _params.request.input.collateralDelta,
            _prices.collateralPrice,
            _prices.collateralBaseUnit,
            _params.request.user
        );

        // Calculate Amount After Fees
        feeState.afterFeeAmount = _calculateAmountAfterFees(
            _params.request.input.collateralDelta,
            feeState.positionFee,
            feeState.feeForExecutor,
            feeState.affiliateRebate,
            feeState.borrowFee,
            feeState.fundingFee
        );
        // Cache Collateral Delta in USD
        uint256 collateralDeltaUsd = feeState.afterFeeAmount.toUsd(_prices.collateralPrice, _prices.collateralBaseUnit);
        // Check that the Position meets the minimum collateral threshold
        if (collateralDeltaUsd < _minCollateralUsd) revert Execution_MinCollateralThreshold();

        // Generate the Position
        position = Position.generateNewPosition(market, _params.request, _prices.impactedPrice, collateralDeltaUsd);

        // Check the Position's Leverage is Valid
        Position.checkLeverage(
            market, _params.request.input.ticker, _params.request.input.sizeDelta, collateralDeltaUsd
        );
    }

    function increasePosition(
        IMarket market,
        ITradeStorage tradeStorage,
        IReferralStorage referralStorage,
        Position.Settlement memory _params,
        Prices memory _prices,
        bytes32 _positionKey
    ) internal view returns (FeeState memory feeState, Position.Data memory position) {
        position = tradeStorage.getPosition(_positionKey);
        if (position.user == address(0)) revert Execution_InvalidPosition();

        (position, feeState) = _calculateFees(
            market,
            tradeStorage,
            referralStorage,
            position,
            feeState,
            _prices,
            _params.request.input.sizeDelta,
            _params.request.input.collateralDelta
        );

        // Settle outstanding fees
        feeState.afterFeeAmount = _calculateAmountAfterFees(
            _params.request.input.collateralDelta,
            feeState.positionFee,
            feeState.feeForExecutor,
            feeState.affiliateRebate,
            feeState.borrowFee,
            feeState.fundingFee
        );

        // Update the Existing Position in Memory
        uint256 collateralDeltaUsd = feeState.afterFeeAmount.toUsd(_prices.collateralPrice, _prices.collateralBaseUnit);
        position =
            _updatePosition(position, collateralDeltaUsd, _params.request.input.sizeDelta, _prices.impactedPrice, true);

        // Check the Leverage
        Position.checkLeverage(market, position.ticker, position.size, position.collateral);
    }

    function decreasePosition(
        IMarket market,
        ITradeStorage tradeStorage,
        IReferralStorage referralStorage,
        Position.Settlement memory _params,
        Prices memory _prices,
        uint256 _minCollateralUsd,
        uint256 _liquidationFee,
        bytes32 _positionKey
    ) internal view returns (Position.Data memory position, FeeState memory feeState) {
        // Fetch and Validate the Position
        position = tradeStorage.getPosition(_positionKey);
        if (position.user == address(0)) revert Execution_InvalidPosition();

        // If SL / TP, clear from the position
        if (_params.request.requestType == Position.RequestType.STOP_LOSS) {
            position.stopLossKey = bytes32(0);
        } else if (_params.request.requestType == Position.RequestType.TAKE_PROFIT) {
            position.takeProfitKey = bytes32(0);
        }

        (_params.request.input.collateralDelta, _params.request.input.sizeDelta, feeState.isFullDecrease) =
            _validateCollateralDelta(position, _params, _prices);

        (position, feeState) = _calculateFees(
            market,
            tradeStorage,
            referralStorage,
            position,
            feeState,
            _prices,
            _params.request.input.sizeDelta,
            _params.request.input.collateralDelta
        );
        // No Calculation for After Fee Amount here --> liquidations can be insolvent, so it's only checked for decrease case.
        // Calculate Pnl for decrease
        feeState.realizedPnl = _calculatePnl(_prices, position, _params.request.input.sizeDelta);

        if (_params.isAdl) {
            feeState.feeForExecutor = _calculateFeeForAdl(
                _params.request.input.sizeDelta,
                _prices.collateralPrice,
                _prices.collateralBaseUnit,
                tradeStorage.adlFee()
            );
        }

        // Calculate the total losses accrued by the position
        uint256 losses = feeState.borrowFee + feeState.positionFee + feeState.feeForExecutor + feeState.affiliateRebate;
        if (feeState.realizedPnl < 0) losses += feeState.realizedPnl.abs();
        if (feeState.fundingFee < 0) losses += feeState.fundingFee.abs();
        uint256 maintenanceCollateral = _getMaintenanceCollateral(market, position);

        // Liquidation Case
        if (losses.toUsd(_prices.collateralPrice, _prices.collateralBaseUnit) >= maintenanceCollateral) {
            (_params, feeState) =
                _initiateLiquidation(_params, _prices, feeState, position.size, position.collateral, _liquidationFee);
        } else {
            // Decrease Case
            (position, feeState.afterFeeAmount) = _initiateDecreasePosition(
                market, _params, position, _prices, feeState, _minCollateralUsd, feeState.isFullDecrease
            );
        }
    }

    /**
     * ========================= Validation Functions =========================
     */
    function validateAdl(
        IMarket market,
        IVault vault,
        Prices memory _prices,
        int256 _startingPnlFactor,
        string memory _ticker,
        bool _isLong
    ) internal view {
        // Get the new PNL to pool ratio
        int256 newPnlFactor = _getPnlFactor(market, vault, _prices, _ticker, _isLong);
        // PNL to pool has reduced
        if (newPnlFactor >= _startingPnlFactor) revert Execution_PNLFactorNotReduced();
    }

    /**
     * @dev This function ensures that those who request a price update are given a time period to enable
     * them to execute the request and claim the execution fee.
     *
     * This is especially important for limit orders, where keepers are required to watch active orders
     * and execute them once valid.
     *
     * Without this check, any user could wait for another to request a price update and then execute the order
     * themselves, maliciously claiming the execution fee.
     *
     * After timeToExpiration, anyone can execute the request.
     */
    function validatePriceRequest(IPriceFeed priceFeed, address _caller, bytes32 _requestKey) internal view {
        // Check if the requester == caller
        IPriceFeed.RequestData memory data = priceFeed.getRequestData(_requestKey);
        if (data.requester != _caller) {
            // If not, check that sufficient time has passed for the caller to execute the request
            if (block.timestamp < data.blockTimestamp + priceFeed.timeToExpiration()) {
                revert Execution_InvalidExecutor();
            }
        }
    }

    /**
     * ========================= Oracle Functions =========================
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

        // Fetch index price based on order type and direction
        prices.indexPrice = _isLong
            ? _isIncrease
                ? Oracle.getMaxPrice(priceFeed, _indexTicker, _requestTimestamp)
                : Oracle.getMinPrice(priceFeed, _indexTicker, _requestTimestamp)
            : _isIncrease
                ? Oracle.getMinPrice(priceFeed, _indexTicker, _requestTimestamp)
                : Oracle.getMaxPrice(priceFeed, _indexTicker, _requestTimestamp);

        // Market Token Prices and Base Units
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

    function checkIsLiquidatable(IMarket market, Position.Data memory _position, Prices memory _prices)
        public
        view
        returns (bool isLiquidatable)
    {
        // Get the PNL for the position
        int256 pnl = Position.getPositionPnl(
            _position.size, _position.weightedAvgEntryPrice, _prices.indexPrice, _prices.indexBaseUnit, _position.isLong
        );

        // Get the Borrow Fees Owed in USD
        uint256 borrowingFeesUsd = Position.getTotalBorrowFeesUsd(market, _position);

        // Get the Funding Fees Owed in USD
        int256 fundingFeesUsd = Position.getTotalFundingFees(market, _position, _prices.indexPrice);

        // Calculate the total losses
        int256 losses = pnl + borrowingFeesUsd.toInt256() + fundingFeesUsd;

        // Check if the losses exceed the collateral value
        if (losses < 0 && losses.abs() > _position.collateral) {
            isLiquidatable = true;
        } else {
            isLiquidatable = false;
        }
    }

    /**
     * ========================= Private Helper Functions =========================
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
            // Increase the Position's collateral
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
        uint256 _adlPercentage,
        address _feeReceiver
    ) private view returns (Position.Settlement memory) {
        // Calculate the Size Delta
        uint256 sizeDelta = _position.size.percentage(_adlPercentage);
        // Calculate the collateral delta
        uint256 collateralDelta =
            _position.collateral.percentage(_adlPercentage).fromUsd(_prices.collateralPrice, _prices.collateralBaseUnit);
        // Construct an ADL Order
        return Position.createAdlOrder(_position, sizeDelta, collateralDelta, _feeReceiver);
    }

    function _calculateFees(
        IMarket market,
        ITradeStorage tradeStorage,
        IReferralStorage referralStorage,
        Position.Data memory _position,
        FeeState memory _feeState,
        Prices memory _prices,
        uint256 _sizeDelta,
        uint256 _collateralDelta
    ) private view returns (Position.Data memory, FeeState memory) {
        // Calculate Fee + Fee for executor
        _feeState = _calculatePositionFees(
            tradeStorage,
            referralStorage,
            _sizeDelta,
            _collateralDelta,
            _prices.collateralPrice,
            _prices.collateralBaseUnit,
            _position.user
        );

        // Process any Outstanding Borrow Fees
        (_position, _feeState.borrowFee) = _processBorrowFees(market, _position, _prices);
        // Process any Outstanding Funding Fees
        (_position, _feeState.fundingFee) = _processFundingFees(market, _position, _prices, _sizeDelta);

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
        // Calculate the fee in USD as a percentage of the size delta
        uint256 adlFeeUsd = _sizeDelta.percentage(_adlFeePercentage);
        // Units value from USD to collateral
        adlFee = adlFeeUsd.fromUsd(_collateralPrice, _collateralBaseUnit);
    }

    function _processFundingFees(
        IMarket market,
        Position.Data memory _position,
        Prices memory _prices,
        uint256 _sizeDelta
    ) private view returns (Position.Data memory, int256 fundingFee) {
        // Calculate and subtract the funding fee
        (int256 fundingFeeUsd, int256 nextFundingAccrued) = Position.getFundingFeeDelta(
            market, _position.ticker, _prices.indexPrice, _sizeDelta, _position.fundingParams.lastFundingAccrued
        );
        // Reset the last funding accrued
        _position.fundingParams.lastFundingAccrued = nextFundingAccrued;
        // Store Funding Fees in Collateral Tokens -> Will be Paid out / Settled as PNL with Decrease
        fundingFee += fundingFeeUsd < 0
            ? -fundingFeeUsd.fromUsdSigned(_prices.collateralPrice, _prices.collateralBaseUnit).toInt256()
            : fundingFeeUsd.fromUsdSigned(_prices.collateralPrice, _prices.collateralBaseUnit).toInt256();
        // Reset the funding owed
        _position.fundingParams.fundingOwed = 0;

        return (_position, fundingFee);
    }

    function _processBorrowFees(IMarket market, Position.Data memory _position, Prices memory _prices)
        private
        view
        returns (Position.Data memory, uint256 borrowFee)
    {
        // Calculate and subtract the Borrowing Fee
        borrowFee = Position.getTotalBorrowFees(market, _position, _prices);
        _position.borrowingParams.feesOwed = 0;
        // Update the position's borrowing parameters
        (_position.borrowingParams.lastLongCumulativeBorrowFee, _position.borrowingParams.lastShortCumulativeBorrowFee)
        = MarketUtils.getCumulativeBorrowFees(market, _position.ticker);

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
        // 1. Set Collateral and Size delta to max
        _params.request.input.collateralDelta =
            _collateralAmount.fromUsd(_prices.collateralPrice, _prices.collateralBaseUnit);

        _params.request.input.sizeDelta = _positionSize;
        // 2. Calculate the Fees Owed to the User
        _feeState.amountOwedToUser = _feeState.fundingFee > 0
            ? _feeState.fundingFee.fromUsdSigned(_prices.collateralPrice, _prices.collateralBaseUnit)
            : 0;
        if (_feeState.realizedPnl > 0) _feeState.amountOwedToUser += _feeState.realizedPnl.abs();
        // 3. Calculate the Fees to Accumulate
        _feeState.feesToAccumulate = _feeState.borrowFee + _feeState.positionFee;
        // 4. Calculate the Liquidation Fee

        _feeState.feeForExecutor = _params.request.input.collateralDelta.percentage(_liquidationFee);

        // 5. Set Affiliate Fees to 0
        _feeState.affiliateRebate = 0;
        // 6. Set the Liquidation Flag
        _feeState.isLiquidation = true;
        // 7. Set is Full Decrease
        _feeState.isFullDecrease = true;

        return (_params, _feeState);
    }

    function _initiateDecreasePosition(
        IMarket market,
        Position.Settlement memory _params,
        Position.Data memory _position,
        Prices memory _prices,
        FeeState memory _feeState,
        uint256 _minCollateralUsd,
        bool _isFullDecrease
    ) private view returns (Position.Data memory, uint256) {
        // Calculate After Fee Amount
        _feeState.afterFeeAmount = _calculateAmountAfterFees(
            _params.request.input.collateralDelta,
            _feeState.positionFee,
            _feeState.feeForExecutor,
            _feeState.affiliateRebate,
            _feeState.borrowFee,
            _feeState.fundingFee
        );

        // Decrease Case
        _position = _updatePosition(
            _position,
            _params.request.input.collateralDelta.toUsd(_prices.collateralPrice, _prices.collateralBaseUnit),
            _params.request.input.sizeDelta,
            _prices.impactedPrice,
            false
        );

        // Add / Subtract PNL
        _feeState.afterFeeAmount = _feeState.realizedPnl > 0
            ? _feeState.afterFeeAmount + _feeState.realizedPnl.abs()
            : _feeState.afterFeeAmount - _feeState.realizedPnl.abs();

        // Check if the Decrease puts the position below the min collateral threshold
        // Only check these if it's not a full decrease
        if (!_isFullDecrease) {
            // Get remaining collateral in USD
            if (_position.collateral < _minCollateralUsd) revert Execution_MinCollateralThreshold();
            // Check Leverage
            Position.checkLeverage(market, _position.ticker, _position.size, _position.collateral);
        }

        return (_position, _feeState.afterFeeAmount);
    }

    function _calculatePositionFees(
        ITradeStorage tradeStorage,
        IReferralStorage referralStorage,
        uint256 _sizeDelta,
        uint256 _collateralDelta,
        uint256 _collateralPrice,
        uint256 _collateralBaseUnit,
        address _user
    ) private view returns (FeeState memory feeState) {
        // Calculate Fee + Fee for executor
        (feeState.positionFee, feeState.feeForExecutor) =
            Position.calculateFee(tradeStorage, _sizeDelta, _collateralDelta, _collateralPrice, _collateralBaseUnit);

        // Calculate & Apply Fee Discount for Referral Code
        (feeState.positionFee, feeState.affiliateRebate, feeState.referrer) =
            Referral.applyFeeDiscount(referralStorage, _user, feeState.positionFee);

        // If Position Fee, or Fee for Executor is 0, revert
        if (feeState.positionFee == 0 || feeState.feeForExecutor == 0) revert Execution_ZeroFees();
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
        // Calculate the acceleration factor --> accelerate the effective price impact
        uint256 accelerationFactor = (_pnlToPoolRatio - TARGET_PNL_FACTOR).percentage(TARGET_PNL_FACTOR);
        // Calculate the effective pnl impact
        uint256 pnlImpact = _pnlBeingRealized * accelerationFactor / PRECISION;
        // Calculate the pnl to pool impact factor
        uint256 poolImpact = pnlImpact.percentage(_poolUsd);
        if (poolImpact > PRECISION) poolImpact = PRECISION;
        // Calculate the minimum profit price for the position (where profit = 5% of position) --> so average entry price + 5%
        uint256 minProfitPrice = _isLong
            ? _averageEntryPrice + (_averageEntryPrice.percentage(MIN_PROFIT_PERCENTAGE))
            : _averageEntryPrice - (_averageEntryPrice.percentage(MIN_PROFIT_PERCENTAGE));
        // Apply the pool impact to the scale of the price
        uint256 priceDelta = (_indexPrice.absDiff(minProfitPrice) * poolImpact) / PRECISION;
        // Apply the price delta to the index price
        if (_isLong) impactedPrice = _indexPrice - priceDelta;
        else impactedPrice = _indexPrice + priceDelta;
    }

    /// @dev - Attaches a Conditional Order to a Position --> Let's us ensure SL / TP orders only affect the position they're assigned to.
    function _attachConditionalOrder(ITradeStorage tradeStorage, Position.Request calldata _request, bytes32 _orderKey)
        private
    {
        bytes32 positionKey = Position.generateKey(_request);
        Position.Data memory position = tradeStorage.getPosition(positionKey);
        // If Request is a SL, tie to the Stop Loss Key for the Position
        if (_request.requestType == Position.RequestType.STOP_LOSS) {
            if (position.stopLossKey != bytes32(0)) revert Execution_StopLossAlreadySet();
            if (position.user == address(0)) revert Execution_PositionNotActive();
            position.stopLossKey = _orderKey;
            tradeStorage.updatePosition(position, positionKey);
        } else if (_request.requestType == Position.RequestType.TAKE_PROFIT) {
            // If Request is a TP, tie to the Take Profit Key for the Position
            if (position.takeProfitKey != bytes32(0)) revert Execution_TakeProfitAlreadySet();
            if (position.user == address(0)) revert Execution_PositionNotActive();
            position.takeProfitKey = _orderKey;
            tradeStorage.updatePosition(position, positionKey);
        }
    }

    /**
     * Extrapolated into an private function to prevent STD Errors
     */
    function _getPnlFactor(IMarket market, IVault vault, Prices memory _prices, string memory _ticker, bool _isLong)
        private
        view
        returns (int256 pnlFactor)
    {
        pnlFactor = MarketUtils.getPnlFactor(
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

    /**
     * if Trigger above and price >  trigger price -> valid
     * if Trigger below and price < trigger price -> valid
     * else revert
     */
    function _checkLimitPrice(uint256 _indexPrice, uint256 _limitPrice, bool _triggerAbove) private pure {
        bool limitPriceCondition = _triggerAbove ? _indexPrice >= _limitPrice : _indexPrice <= _limitPrice;
        if (!limitPriceCondition) revert Execution_LimitPriceNotMet(_limitPrice, _indexPrice);
    }

    // Internal to prevent STD Err
    function _getPoolUsd(IMarket market, IVault vault, Prices memory _prices, string memory _ticker, bool _isLong)
        private
        view
        returns (uint256 poolUsd)
    {
        return MarketUtils.getPoolBalanceUsd(
            market, vault, _ticker, _prices.collateralPrice, _prices.collateralBaseUnit, _isLong
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

        // Account for any Positive Funding
        if (_fundingFee < 0) totalFees += _fundingFee.abs();
        else afterFeeAmount += _fundingFee.abs();
        if (totalFees >= _collateralDelta) revert Execution_FeesExceedCollateralDelta();

        // Calculate the amount of collateral left after fees
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
            // If no collateral delta specified, calculate it for a proportional decrease
            collateralDelta = _position.collateral.percentage(_params.request.input.sizeDelta, _position.size).fromUsd(
                _prices.collateralPrice, _prices.collateralBaseUnit
            );
            sizeDelta = _params.request.input.sizeDelta;
        } else {
            collateralDelta = _params.request.input.collateralDelta;
            sizeDelta = _params.request.input.sizeDelta;
        }
    }

    function _getMaintenanceCollateral(IMarket market, Position.Data memory _position)
        private
        view
        returns (uint256 maintenanceCollateral)
    {
        // Expand to 18 decimals
        uint256 maintenancePercentage = MarketUtils.getMaintenanceMargin(market, _position.ticker).expandDecimals(2, 18);
        maintenanceCollateral = _position.collateral.percentage(maintenancePercentage);
    }
}
