// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {ITradeStorage} from "./interfaces/ITradeStorage.sol";
import {ITradeEngine} from "./interfaces/ITradeEngine.sol";
import {Position} from "./Position.sol";
import {Execution} from "./Execution.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {IVault} from "../markets/interfaces/IVault.sol";
import {IPriceFeed} from "../oracle/interfaces/IPriceFeed.sol";
import {IPositionManager} from "../router/interfaces/IPositionManager.sol";
import {IReferralStorage} from "../referrals/interfaces/IReferralStorage.sol";
import {MarketUtils} from "../markets/MarketUtils.sol";
import {MathUtils} from "../libraries/MathUtils.sol";
import {SignedMath} from "../libraries/SignedMath.sol";
import {RoleValidation} from "../access/RoleValidation.sol";

/// @notice Contract responsible for handling all execution logic associated with trades
contract TradeEngine is ITradeEngine, RoleValidation {
    using MathUtils for uint256;
    using SignedMath for int256;

    ITradeStorage public tradeStorage;

    modifier onlyStorage() {
        _isStorage();
        _;
    }

    constructor(ITradeStorage _tradeStorage, address _roleStorage) RoleValidation(_roleStorage) {
        tradeStorage = _tradeStorage;
    }

    function executePositionRequest(
        IMarket market,
        IVault vault,
        IPriceFeed priceFeed,
        IPositionManager positionManager,
        IReferralStorage referralStorage,
        bytes32 _orderKey,
        bytes32 _requestKey,
        address _feeReceiver
    ) external onlyStorage returns (Execution.FeeState memory, Position.Request memory) {
        // Initiate the execution
        (Execution.Prices memory prices, Position.Request memory request) =
            Execution.initiate(tradeStorage, market, priceFeed, _orderKey, _requestKey, _feeReceiver);
        // Delete the Order from Storage
        tradeStorage.deleteOrder(_orderKey, request.input.isLimit);
        // Update the Market State for the Request
        _updateMarketState(
            market,
            prices,
            request.input.ticker,
            request.input.sizeDelta,
            request.input.isLong,
            request.input.isIncrease
        );
        // Execute Trade
        Execution.FeeState memory feeState;
        if (request.requestType == Position.RequestType.CREATE_POSITION) {
            feeState = _createNewPosition(
                market,
                vault,
                positionManager,
                referralStorage,
                Position.Settlement(request, _orderKey, _feeReceiver, false),
                prices
            );
        } else if (request.requestType == Position.RequestType.POSITION_INCREASE) {
            feeState = _increasePosition(
                market,
                vault,
                positionManager,
                referralStorage,
                Position.Settlement(request, _orderKey, _feeReceiver, false),
                prices
            );
        } else if (
            request.requestType == Position.RequestType.POSITION_DECREASE
                || request.requestType == Position.RequestType.TAKE_PROFIT
                || request.requestType == Position.RequestType.STOP_LOSS
        ) {
            feeState = _decreasePosition(
                market,
                vault,
                referralStorage,
                Position.Settlement(request, _orderKey, _feeReceiver, false),
                prices,
                tradeStorage.minCollateralUsd(),
                tradeStorage.liquidationFee()
            );
        } else {
            revert TradeEngine_InvalidRequestType();
        }

        return (feeState, request);
    }

    function executeAdl(
        IMarket market,
        IVault vault,
        IReferralStorage referralStorage,
        IPriceFeed priceFeed,
        bytes32 _positionKey,
        bytes32 _requestKey,
        address _feeReceiver
    ) external onlyStorage {
        // Check that the price update was requested by the ADLer, if not, require some time to pass before enabling them to execute
        uint48 requestTimestamp = priceFeed.getRequestTimestamp(_requestKey);
        Execution.validatePriceRequest(priceFeed, _feeReceiver, _requestKey);
        // Initiate the Adl order
        (Execution.Prices memory prices, Position.Settlement memory params, int256 startingPnlFactor) =
            Execution.initiateAdlOrder(market, tradeStorage, priceFeed, _positionKey, requestTimestamp, _feeReceiver);

        // Update the Market State
        _updateMarketState(
            market,
            prices,
            params.request.input.ticker,
            params.request.input.sizeDelta,
            params.request.input.isLong,
            false
        );

        // Execute the order
        _decreasePosition(
            market,
            vault,
            referralStorage,
            params,
            prices,
            tradeStorage.minCollateralUsd(),
            tradeStorage.liquidationFee()
        );

        // Validate the Adl
        Execution.validateAdl(
            market, prices, startingPnlFactor, params.request.input.ticker, params.request.input.isLong
        );

        emit AdlExecuted(address(market), _positionKey, params.request.input.sizeDelta, params.request.input.isLong);
    }

    function liquidatePosition(
        IMarket market,
        IVault vault,
        IReferralStorage referralStorage,
        IPriceFeed priceFeed,
        bytes32 _positionKey,
        bytes32 _requestKey,
        address _liquidator
    ) external onlyStorage {
        // Fetch the Position
        Position.Data memory position = tradeStorage.getPosition(_positionKey);
        // Check the Position Exists
        if (position.user == address(0)) revert TradeEngine_PositionDoesNotExist();
        // Check that the price update was requested by the liquidator, if not, require some time to pass before enabling them to execute
        uint48 requestTimestamp = priceFeed.getRequestTimestamp(_requestKey);
        Execution.validatePriceRequest(priceFeed, _liquidator, _requestKey);
        // Get the Prices
        Execution.Prices memory prices =
            Execution.getTokenPrices(priceFeed, position.ticker, requestTimestamp, position.isLong, false);
        // No price impact on Liquidations
        prices.impactedPrice = prices.indexPrice;
        // Update the Market State
        _updateMarketState(market, prices, position.ticker, position.size, position.isLong, false);
        // Construct Liquidation Order
        Position.Settlement memory params =
            Position.createLiquidationOrder(position, prices.collateralPrice, prices.collateralBaseUnit, _liquidator);

        // Execute the Liquidation
        _decreasePosition(
            market,
            vault,
            referralStorage,
            params,
            prices,
            tradeStorage.minCollateralUsd(),
            tradeStorage.liquidationFee()
        );
        // Fire Event
        emit LiquidatePosition(_positionKey, _liquidator, position.isLong);
    }

    /**
     * ========================= Core Function Implementations =========================
     */
    function _createNewPosition(
        IMarket market,
        IVault vault,
        IPositionManager positionManager,
        IReferralStorage referralStorage,
        Position.Settlement memory _params,
        Execution.Prices memory _prices
    ) private returns (Execution.FeeState memory feeState) {
        // Get the Position Key
        bytes32 positionKey = Position.generateKey(_params.request);
        // Perform Execution in the Library
        Position.Data memory position;
        (position, feeState) = Execution.createNewPosition(
            market, tradeStorage, referralStorage, _params, _prices, tradeStorage.minCollateralUsd(), positionKey
        );

        // Account for Fees in Storage
        _accumulateFees(market, vault, referralStorage, feeState, position.isLong);
        // Reserve Liquidity Equal to the Position Size
        _updateLiquidity(
            vault,
            _params.request.input.sizeDelta,
            feeState.afterFeeAmount,
            _prices.collateralPrice,
            _prices.collateralBaseUnit,
            position.user,
            _params.request.input.isLong,
            true,
            false
        );
        // Update Final Storage
        tradeStorage.createPosition(position, positionKey);
        // Handle Token Transfers
        positionManager.transferTokensForIncrease(
            market,
            _params.request.input.collateralToken,
            _params.request.input.collateralDelta,
            feeState.affiliateRebate,
            feeState.feeForExecutor,
            _params.feeReceiver
        );
        // Fire Event
        emit PositionCreated(positionKey, position.user, address(market), position.isLong);
    }

    function _increasePosition(
        IMarket market,
        IVault vault,
        IPositionManager positionManager,
        IReferralStorage referralStorage,
        Position.Settlement memory _params,
        Execution.Prices memory _prices
    ) private returns (Execution.FeeState memory feeState) {
        // Get the Position Key
        bytes32 positionKey = Position.generateKey(_params.request);
        // Perform Execution in the Library
        Position.Data memory position;
        (feeState, position) =
            Execution.increasePosition(market, tradeStorage, referralStorage, _params, _prices, positionKey);

        // Account for Fees in Storage
        _accumulateFees(market, vault, referralStorage, feeState, position.isLong);
        // Reserve Liquidity Equal to the Position Size
        _updateLiquidity(
            vault,
            _params.request.input.sizeDelta,
            feeState.afterFeeAmount,
            _prices.collateralPrice,
            _prices.collateralBaseUnit,
            position.user,
            _params.request.input.isLong,
            true,
            false
        );
        // Update Final Storage
        tradeStorage.updatePosition(position, positionKey);
        // Handle Token Transfers
        positionManager.transferTokensForIncrease(
            market,
            _params.request.input.collateralToken,
            _params.request.input.collateralDelta,
            feeState.affiliateRebate,
            feeState.feeForExecutor,
            _params.feeReceiver
        );
        // Fire event
        emit IncreasePosition(positionKey, _params.request.input.collateralDelta, _params.request.input.sizeDelta);
    }

    function _decreasePosition(
        IMarket market,
        IVault vault,
        IReferralStorage referralStorage,
        Position.Settlement memory _params,
        Execution.Prices memory _prices,
        uint256 _minCollateralUsd,
        uint256 _liquidationFee
    ) private returns (Execution.FeeState memory feeState) {
        // Get the Position Key
        bytes32 positionKey = Position.generateKey(_params.request);
        // Perform Execution in the Library
        Position.Data memory position;
        bool isCollateralEdit = _params.request.input.sizeDelta == 0;
        if (isCollateralEdit) {
            (position, feeState) = Execution.decreaseCollateral(
                market, tradeStorage, referralStorage, _params, _prices, _minCollateralUsd, positionKey
            );
        } else {
            (position, feeState) = Execution.decreasePosition(
                market, tradeStorage, referralStorage, _params, _prices, _minCollateralUsd, _liquidationFee, positionKey
            );
        }

        // Unreserve Liquidity for the position
        _updateLiquidity(
            vault,
            _params.request.input.sizeDelta,
            _params.request.input.collateralDelta,
            _prices.collateralPrice,
            _prices.collateralBaseUnit,
            position.user,
            _params.request.input.isLong,
            false,
            feeState.isFullDecrease
        );

        if (feeState.isLiquidation) {
            // Liquidate the Position
            feeState = _handleLiquidation(
                market, vault, referralStorage, position, feeState, _prices, positionKey, _params.request.user
            );
        } else if (isCollateralEdit) {
            _handleCollateralDecrease(
                market,
                vault,
                referralStorage,
                position,
                feeState,
                positionKey,
                _params.feeReceiver,
                _params.request.input.reverseWrap
            );
        } else {
            // Decrease the Position
            _handlePositionDecrease(
                market,
                vault,
                referralStorage,
                position,
                feeState,
                positionKey,
                _params.feeReceiver,
                _params.request.input.reverseWrap
            );
        }

        // Fire Event
        emit DecreasePosition(positionKey, _params.request.input.collateralDelta, _params.request.input.sizeDelta);
    }

    /**
     * To handle insolvency case for liquidations, we do the following:
     * - Pay fees in order of importance, each time checking if the remaining amount is sufficient.
     * - Once the remaining amount is used up, stop paying fees.
     * - If any is remaining after paying all fees, add to pool.
     */
    function _handleLiquidation(
        IMarket market,
        IVault vault,
        IReferralStorage referralStorage,
        Position.Data memory _position,
        Execution.FeeState memory _feeState,
        Execution.Prices memory _prices,
        bytes32 _positionKey,
        address _liquidator
    ) private returns (Execution.FeeState memory) {
        // Delete the position from storage
        tradeStorage.deletePosition(_positionKey, _position.isLong);
        // Delete associated orders
        _deleteAssociatedOrders(_position.stopLossKey, _position.takeProfitKey);

        // Adjust Fees to handle insolvent liquidation case
        _feeState = _adjustFeesForInsolvency(
            _feeState, _position.collateral.fromUsd(_prices.collateralPrice, _prices.collateralBaseUnit)
        );

        // Account for Fees in Storage
        _accumulateFees(market, vault, referralStorage, _feeState, _position.isLong);

        // Update the Pool Balance for any Remaining Collateral
        vault.updatePoolBalance(_feeState.afterFeeAmount, _position.isLong, true);

        // Pay the Liquidated User if owed anything
        if (_feeState.amountOwedToUser > 0) {
            // Decrease the pool amount by the amount being payed out to the user
            vault.updatePoolBalance(_feeState.amountOwedToUser, _position.isLong, false);
        }

        _transferTokensForDecrease(
            vault,
            referralStorage,
            _feeState,
            _feeState.amountOwedToUser,
            _liquidator,
            _position.user,
            _position.isLong,
            false // Leave unwrapped by default
        );

        return _feeState;
    }

    function _handleCollateralDecrease(
        IMarket market,
        IVault vault,
        IReferralStorage referralStorage,
        Position.Data memory _position,
        Execution.FeeState memory _feeState,
        bytes32 _positionKey,
        address _feeReceiver,
        bool _reverseWrap
    ) private {
        // Account for Fees in Storage
        _accumulateFees(market, vault, referralStorage, _feeState, _position.isLong);
        // Update Final Storage
        tradeStorage.updatePosition(_position, _positionKey);

        // Handle Token Transfers
        _transferTokensForDecrease(
            vault,
            referralStorage,
            _feeState,
            _feeState.afterFeeAmount,
            _feeReceiver,
            _position.user,
            _position.isLong,
            _reverseWrap
        );
    }

    function _handlePositionDecrease(
        IMarket market,
        IVault vault,
        IReferralStorage referralStorage,
        Position.Data memory _position,
        Execution.FeeState memory _feeState,
        bytes32 _positionKey,
        address _executor,
        bool _reverseWrap
    ) private {
        // Account for Fees in Storage
        _accumulateFees(market, vault, referralStorage, _feeState, _position.isLong);

        // Update Pool for Profit / Loss -> Loss = Decrease Pool, Profit = Increase Pool
        vault.updatePoolBalance(_feeState.realizedPnl.abs(), _position.isLong, _feeState.realizedPnl < 0);

        // Delete the Position if Full Decrease
        if (_position.size == 0 || _position.collateral == 0) {
            tradeStorage.deletePosition(_positionKey, _position.isLong);
            _deleteAssociatedOrders(_position.stopLossKey, _position.takeProfitKey);
        } else {
            // Update Final Storage if Partial Decrease
            tradeStorage.updatePosition(_position, _positionKey);
        }

        // Check Market has enough available liquidity for all transfers out.
        // In cases where the market is insolvent, there may not be enough in the pool to pay out a profitable position.
        MarketUtils.hasSufficientLiquidity(
            market, _feeState.afterFeeAmount + _feeState.affiliateRebate + _feeState.feeForExecutor, _position.isLong
        );

        // Handle Token Transfers
        _transferTokensForDecrease(
            vault,
            referralStorage,
            _feeState,
            _feeState.afterFeeAmount,
            _executor,
            _position.user,
            _position.isLong,
            _reverseWrap
        );
    }

    /**
     * ========================= Private Helper Functions =========================
     */

    /// @dev - Can fail on insolvency.
    function _transferTokensForDecrease(
        IVault vault,
        IReferralStorage referralStorage,
        Execution.FeeState memory _feeState,
        uint256 _amountOut,
        address _executor,
        address _user,
        bool _isLong,
        bool _reverseWrap
    ) private {
        // Transfer the Fee to the Executor
        if (_feeState.feeForExecutor > 0) {
            vault.transferOutTokens(_executor, _feeState.feeForExecutor, _isLong, false);
        }
        // Transfer Rebate to Referral Storage

        if (_feeState.affiliateRebate > 0) {
            vault.transferOutTokens(
                address(referralStorage),
                _feeState.affiliateRebate,
                _isLong,
                false // Leave unwrapped by default
            );
        }
        // Transfer Tokens to User

        if (_amountOut > 0) {
            vault.transferOutTokens(_user, _amountOut, _isLong, _reverseWrap);
        }
    }

    function _updateMarketState(
        IMarket market,
        Execution.Prices memory _prices,
        string memory _ticker,
        uint256 _sizeDelta,
        bool _isLong,
        bool _isIncrease
    ) private {
        // Update the Market State
        market.updateMarketState(
            _ticker,
            _sizeDelta,
            _prices.indexPrice,
            _prices.impactedPrice,
            _prices.collateralPrice,
            _prices.collateralBaseUnit,
            _isLong,
            _isIncrease
        );
        // If Price Impact is Negative, add to the impact Pool
        // If Price Impact is Positive, Subtract from the Impact Pool
        // Impact Pool Delta = -1 * Price Impact
        if (_prices.priceImpactUsd == 0) return;
        market.updateImpactPool(_ticker, -_prices.priceImpactUsd);
    }

    function _updateLiquidity(
        IVault vault,
        uint256 _sizeDeltaUsd,
        uint256 _collateralDelta,
        uint256 _collateralPrice,
        uint256 _collateralBaseUnit,
        address _user,
        bool _isLong,
        bool _isReserve,
        bool _isFullDecrease
    ) private {
        if (_sizeDeltaUsd > 0) {
            // Units Size Delta USD to Collateral Tokens
            uint256 reserveDelta = _sizeDeltaUsd.fromUsd(_collateralPrice, _collateralBaseUnit);
            // Reserve an Amount of Liquidity Equal to the Position Size
            vault.updateLiquidityReservation(reserveDelta, _isLong, _isReserve);
        }
        /**
         * Store collateral for the user. Let's us keep track of any collateral as it may
         * fluctuate in price.
         * When the user creates a position, a snapshot is taken of the collateral amount.
         * Excess gained / loss is accounted for and settled via the pool
         */
        vault.updateCollateralAmount(_collateralDelta, _user, _isLong, _isReserve, _isFullDecrease);
    }

    /**
     * For Increase:
     * - Borrow & Position Fee --> LPs
     * - Affiliate Rebate --> Referrer
     * - Fee For Executor --> Executor
     * - Funding Fee --> Pool
     */
    function _accumulateFees(
        IMarket market,
        IVault vault,
        IReferralStorage referralStorage,
        Execution.FeeState memory _feeState,
        bool _isLong
    ) private {
        // Account for Fees in Storage to LPs for Side (Position + Borrow)
        vault.accumulateFees(_feeState.borrowFee + _feeState.positionFee, _isLong);
        // Pay Affiliate Rebate to Referrer
        if (_feeState.affiliateRebate > 0) {
            referralStorage.accumulateAffiliateRewards(
                address(market), _feeState.referrer, _isLong, _feeState.affiliateRebate
            );
        }
        // If user's position has increased with positive funding, need to subtract from the pool
        // If user's position has decreased with negative funding, need to add to the pool
        vault.updatePoolBalance(_feeState.fundingFee.abs(), _isLong, _feeState.fundingFee < 0);
    }

    // Use remaining collateral as a decreasing incrementer -> pay fees until all used up, adjust fees as necessary
    function _adjustFeesForInsolvency(Execution.FeeState memory _feeState, uint256 _remainingCollateral)
        private
        pure
        returns (Execution.FeeState memory)
    {
        // Subtract Liq Fee --> Liq Fee is a % of the collateral, so can never be >
        // Paid first to always incentivize liquidations.
        _remainingCollateral -= _feeState.feeForExecutor;

        if (_feeState.borrowFee > _remainingCollateral) _feeState.borrowFee = _remainingCollateral;
        _remainingCollateral -= _feeState.borrowFee;

        if (_feeState.positionFee > _remainingCollateral) _feeState.positionFee = _remainingCollateral;
        _remainingCollateral -= _feeState.positionFee;

        if (_feeState.affiliateRebate > _remainingCollateral) _feeState.affiliateRebate = _remainingCollateral;
        _remainingCollateral -= _feeState.affiliateRebate;

        // Set the remaining collateral as the after fee amount
        _feeState.afterFeeAmount = _remainingCollateral;

        return _feeState;
    }

    function _deleteAssociatedOrders(bytes32 _stopLossKey, bytes32 _takeProfitKey) private {
        if (_stopLossKey != bytes32(0)) tradeStorage.deleteOrder(_stopLossKey, true);
        if (_takeProfitKey != bytes32(0)) tradeStorage.deleteOrder(_takeProfitKey, true);
    }

    function _isStorage() private view {
        if (msg.sender != address(tradeStorage)) revert RoleValidation_AccessDenied();
    }
}
