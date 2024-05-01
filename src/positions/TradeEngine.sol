// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {ITradeStorage} from "./interfaces/ITradeStorage.sol";
import {Position} from "./Position.sol";
import {Execution} from "./Execution.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {IVault} from "../markets/interfaces/IVault.sol";
import {IPriceFeed} from "../oracle/interfaces/IPriceFeed.sol";
import {IPositionManager} from "../router/interfaces/IPositionManager.sol";
import {IReferralStorage} from "../referrals/interfaces/IReferralStorage.sol";
import {MarketUtils} from "../markets/MarketUtils.sol";
import {MathUtils} from "../libraries/MathUtils.sol";
import {Units} from "../libraries/Units.sol";
import {Casting} from "../libraries/Casting.sol";

/// @notice Library responsible for handling all execution logic associated with trades
/// @dev Functions are external to avoid bytecode size issues.
library TradeEngine {
    using MathUtils for uint256;
    using MathUtils for int256;
    using Units for uint256;
    using Casting for int256;

    event AdlExecuted(address indexed market, bytes32 indexed positionKey, uint256 sizeDelta, bool isLong);
    event LiquidatePosition(bytes32 indexed positionKey, address indexed liquidator, bool isLong);
    event CollateralEdited(bytes32 indexed positionKey, uint256 collateralDelta, bool isIncrease);
    event PositionCreated(bytes32 indexed positionKey, address indexed owner, address indexed market, bool isLong);
    event IncreasePosition(bytes32 indexed positionKey, uint256 collateralDelta, uint256 sizeDelta);
    event DecreasePosition(bytes32 indexed positionKey, uint256 collateralDelta, uint256 sizeDelta);

    error TradeEngine_InvalidRequestType();
    error TradeEngine_PositionDoesNotExist();
    error TradeEngine_InvalidCaller();

    modifier onlyTradeStorage(IMarket market) {
        if (market.tradeStorage() != address(this)) revert TradeEngine_InvalidCaller();
        _;
    }

    // @audit - roles
    function executePositionRequest(
        IMarket market,
        IPriceFeed priceFeed,
        IPositionManager positionManager,
        IReferralStorage referralStorage,
        Position.Settlement memory _params
    ) external onlyTradeStorage(market) returns (Execution.FeeState memory, Position.Request memory) {
        ITradeStorage tradeStorage = ITradeStorage(address(this));
        IVault vault = market.VAULT();
        // Initiate the execution
        Execution.Prices memory prices;
        (prices, _params.request) = Execution.initiate(
            tradeStorage, market, vault, priceFeed, _params.orderKey, _params.limitRequestKey, _params.feeReceiver
        );
        // Delete the Order from Storage
        tradeStorage.deleteOrder(_params.orderKey, _params.request.input.isLimit);
        // Update the Market State for the Request
        _updateMarketState(
            market,
            prices,
            _params.request.input.ticker,
            _params.request.input.sizeDelta,
            _params.request.input.isLong,
            _params.request.input.isIncrease
        );
        // Execute Trade
        Execution.FeeState memory feeState;
        if (_params.request.requestType == Position.RequestType.CREATE_POSITION) {
            feeState =
                _createNewPosition(tradeStorage, market, vault, positionManager, referralStorage, _params, prices);
        } else if (_params.request.requestType == Position.RequestType.POSITION_INCREASE) {
            feeState = _increasePosition(tradeStorage, market, vault, positionManager, referralStorage, _params, prices);
        } else {
            // Decrease, SL, TP
            feeState = _decreasePosition(
                tradeStorage,
                market,
                vault,
                referralStorage,
                _params,
                prices,
                tradeStorage.minCollateralUsd(),
                tradeStorage.liquidationFee()
            );
        }

        return (feeState, _params.request);
    }

    function executeAdl(
        IMarket market,
        IPriceFeed priceFeed,
        IReferralStorage referralStorage,
        bytes32 _positionKey,
        bytes32 _requestKey,
        address _feeReceiver
    ) external onlyTradeStorage(market) {
        ITradeStorage tradeStorage = ITradeStorage(address(this));
        IVault vault = market.VAULT();

        // Initiate the Adl order
        (Execution.Prices memory prices, Position.Settlement memory params, int256 startingPnlFactor) =
            _initiateAdl(tradeStorage, market, vault, priceFeed, _positionKey, _requestKey, _feeReceiver);

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
            tradeStorage,
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
            market, vault, prices, startingPnlFactor, params.request.input.ticker, params.request.input.isLong
        );

        emit AdlExecuted(address(market), _positionKey, params.request.input.sizeDelta, params.request.input.isLong);
    }

    function liquidatePosition(
        IMarket market,
        IPriceFeed priceFeed,
        IReferralStorage referralStorage,
        bytes32 _positionKey,
        bytes32 _requestKey,
        address _liquidator
    ) external onlyTradeStorage(market) {
        ITradeStorage tradeStorage = ITradeStorage(address(this));
        IVault vault = market.VAULT();
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
            tradeStorage,
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
        ITradeStorage tradeStorage,
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
        _accumulateFees(vault, referralStorage, feeState, position.isLong);
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
            vault,
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
        ITradeStorage tradeStorage,
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
        _accumulateFees(vault, referralStorage, feeState, position.isLong);
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
            vault,
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
        ITradeStorage tradeStorage,
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
                tradeStorage, vault, referralStorage, position, feeState, _prices, positionKey, _params.request.user
            );
        } else if (isCollateralEdit) {
            _handleCollateralDecrease(
                tradeStorage,
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
                tradeStorage,
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
        ITradeStorage tradeStorage,
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
        _deleteAssociatedOrders(tradeStorage, _position.stopLossKey, _position.takeProfitKey);

        // Adjust Fees to handle insolvent liquidation case
        _feeState = _adjustFeesForInsolvency(
            _feeState, _position.collateral.fromUsd(_prices.collateralPrice, _prices.collateralBaseUnit)
        );

        // Account for Fees in Storage
        _accumulateFees(vault, referralStorage, _feeState, _position.isLong);

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
        ITradeStorage tradeStorage,
        IVault vault,
        IReferralStorage referralStorage,
        Position.Data memory _position,
        Execution.FeeState memory _feeState,
        bytes32 _positionKey,
        address _feeReceiver,
        bool _reverseWrap
    ) private {
        // Account for Fees in Storage
        _accumulateFees(vault, referralStorage, _feeState, _position.isLong);
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
        ITradeStorage tradeStorage,
        IVault vault,
        IReferralStorage referralStorage,
        Position.Data memory _position,
        Execution.FeeState memory _feeState,
        bytes32 _positionKey,
        address _executor,
        bool _reverseWrap
    ) private {
        // Account for Fees in Storage
        _accumulateFees(vault, referralStorage, _feeState, _position.isLong);

        // Update Pool for Profit / Loss -> Loss = Decrease Pool, Profit = Increase Pool
        vault.updatePoolBalance(_feeState.realizedPnl.abs(), _position.isLong, _feeState.realizedPnl < 0);

        // Delete the Position if Full Decrease
        if (_position.size == 0 || _position.collateral == 0) {
            tradeStorage.deletePosition(_positionKey, _position.isLong);
            _deleteAssociatedOrders(tradeStorage, _position.stopLossKey, _position.takeProfitKey);
        } else {
            // Update Final Storage if Partial Decrease
            tradeStorage.updatePosition(_position, _positionKey);
        }

        // Check Market has enough available liquidity for all transfers out.
        // In cases where the market is insolvent, there may not be enough in the pool to pay out a profitable position.
        MarketUtils.hasSufficientLiquidity(
            vault, _feeState.afterFeeAmount + _feeState.affiliateRebate + _feeState.feeForExecutor, _position.isLong
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
    function _initiateAdl(
        ITradeStorage tradeStorage,
        IMarket market,
        IVault vault,
        IPriceFeed priceFeed,
        bytes32 _positionKey,
        bytes32 _requestKey,
        address _feeReceiver
    )
        private
        view
        returns (Execution.Prices memory prices, Position.Settlement memory params, int256 startingPnlFactor)
    {
        // Fetch the Position
        Position.Data memory position = tradeStorage.getPosition(_positionKey);
        // Check the Position Exists
        if (position.user == address(0)) revert TradeEngine_PositionDoesNotExist();
        // Check that the price update was requested by the ADLer, if not, require some time to pass before enabling them to execute
        uint48 requestTimestamp = priceFeed.getRequestTimestamp(_requestKey);
        Execution.validatePriceRequest(priceFeed, _feeReceiver, _requestKey);
        // Initiate the Adl order
        (prices, params, startingPnlFactor) =
            Execution.initiateAdlOrder(market, vault, priceFeed, position, requestTimestamp, _feeReceiver);
    }

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
        IVault vault,
        IReferralStorage referralStorage,
        Execution.FeeState memory _feeState,
        bool _isLong
    ) private {
        // Account for Fees in Storage to LPs for Side (Position + Borrow)
        vault.accumulateFees(_feeState.borrowFee + _feeState.positionFee, _isLong);
        // Pay Affiliate Rebate to Referrer
        if (_feeState.affiliateRebate > 0) {
            referralStorage.accumulateAffiliateRewards(_feeState.referrer, _isLong, _feeState.affiliateRebate);
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

    function _deleteAssociatedOrders(ITradeStorage tradeStorage, bytes32 _stopLossKey, bytes32 _takeProfitKey)
        private
    {
        if (_stopLossKey != bytes32(0)) tradeStorage.deleteOrder(_stopLossKey, true);
        if (_takeProfitKey != bytes32(0)) tradeStorage.deleteOrder(_takeProfitKey, true);
    }
}
