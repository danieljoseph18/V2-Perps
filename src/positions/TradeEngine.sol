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

    function executePositionRequest(
        IMarket market,
        IPriceFeed priceFeed,
        IPositionManager positionManager,
        IReferralStorage referralStorage,
        Position.Settlement memory _params
    ) external onlyTradeStorage(market) returns (Execution.FeeState memory, Position.Request memory) {
        ITradeStorage tradeStorage = ITradeStorage(address(this));
        IVault vault = market.VAULT();

        Execution.Prices memory prices;
        (prices, _params.request) = Execution.initiate(
            tradeStorage, market, vault, priceFeed, _params.orderKey, _params.limitRequestKey, _params.feeReceiver
        );

        tradeStorage.deleteOrder(_params.orderKey, _params.request.input.isLimit);

        _updateMarketState(
            market,
            prices,
            _params.request.input.ticker,
            _params.request.input.sizeDelta,
            _params.request.input.isLong,
            _params.request.input.isIncrease
        );

        Execution.FeeState memory feeState;
        if (_params.request.requestType == Position.RequestType.CREATE_POSITION) {
            feeState =
                _createNewPosition(tradeStorage, market, vault, positionManager, referralStorage, _params, prices);
        } else if (_params.request.requestType == Position.RequestType.POSITION_INCREASE) {
            feeState = _increasePosition(tradeStorage, market, vault, positionManager, referralStorage, _params, prices);
        } else {
            // Decrease, SL & TP
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

        (Execution.Prices memory prices, Position.Settlement memory params, int256 startingPnlFactor) =
            _initiateAdl(tradeStorage, market, vault, priceFeed, _positionKey, _requestKey, _feeReceiver);

        _updateMarketState(
            market,
            prices,
            params.request.input.ticker,
            params.request.input.sizeDelta,
            params.request.input.isLong,
            false
        );

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

        Position.Data memory position = tradeStorage.getPosition(_positionKey);

        if (position.user == address(0)) revert TradeEngine_PositionDoesNotExist();

        uint48 requestTimestamp = priceFeed.getRequestTimestamp(_requestKey);
        Execution.validatePriceRequest(priceFeed, _liquidator, _requestKey);

        Execution.Prices memory prices =
            Execution.getTokenPrices(priceFeed, position.ticker, requestTimestamp, position.isLong, false);

        // No price impact on Liquidations
        prices.impactedPrice = prices.indexPrice;

        _updateMarketState(market, prices, position.ticker, position.size, position.isLong, false);

        Position.Settlement memory params =
            Position.createLiquidationOrder(position, prices.collateralPrice, prices.collateralBaseUnit, _liquidator);

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

        emit LiquidatePosition(_positionKey, _liquidator, position.isLong);
    }

    /**
     * =========================================== Core Function Implementations ===========================================
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
        bytes32 positionKey = Position.generateKey(_params.request);

        Position.Data memory position;
        (position, feeState) = Execution.createNewPosition(
            market, tradeStorage, referralStorage, _params, _prices, tradeStorage.minCollateralUsd(), positionKey
        );

        _accumulateFees(vault, referralStorage, feeState, position.isLong);

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

        tradeStorage.createPosition(position, positionKey);

        positionManager.transferTokensForIncrease(
            market,
            vault,
            _params.request.input.collateralToken,
            _params.request.input.collateralDelta,
            feeState.affiliateRebate,
            feeState.feeForExecutor,
            _params.feeReceiver
        );

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
        bytes32 positionKey = Position.generateKey(_params.request);

        Position.Data memory position;
        (feeState, position) =
            Execution.increasePosition(market, tradeStorage, referralStorage, _params, _prices, positionKey);

        _accumulateFees(vault, referralStorage, feeState, position.isLong);

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

        tradeStorage.updatePosition(position, positionKey);

        positionManager.transferTokensForIncrease(
            market,
            vault,
            _params.request.input.collateralToken,
            _params.request.input.collateralDelta,
            feeState.affiliateRebate,
            feeState.feeForExecutor,
            _params.feeReceiver
        );

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
        bytes32 positionKey = Position.generateKey(_params.request);

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

        emit DecreasePosition(positionKey, _params.request.input.collateralDelta, _params.request.input.sizeDelta);
    }

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
        tradeStorage.deletePosition(_positionKey, _position.isLong);

        _deleteAssociatedOrders(tradeStorage, _position.stopLossKey, _position.takeProfitKey);

        _feeState = _adjustFeesForInsolvency(
            _feeState, _position.collateral.fromUsd(_prices.collateralPrice, _prices.collateralBaseUnit)
        );

        _accumulateFees(vault, referralStorage, _feeState, _position.isLong);

        vault.updatePoolBalance(_feeState.afterFeeAmount, _position.isLong, true);

        // Pay the Liquidated User if owed anything
        if (_feeState.amountOwedToUser > 0) {
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
        _accumulateFees(vault, referralStorage, _feeState, _position.isLong);

        tradeStorage.updatePosition(_position, _positionKey);

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
        _accumulateFees(vault, referralStorage, _feeState, _position.isLong);

        vault.updatePoolBalance(_feeState.realizedPnl.abs(), _position.isLong, _feeState.realizedPnl < 0);

        if (_position.size == 0 || _position.collateral == 0) {
            tradeStorage.deletePosition(_positionKey, _position.isLong);
            _deleteAssociatedOrders(tradeStorage, _position.stopLossKey, _position.takeProfitKey);
        } else {
            tradeStorage.updatePosition(_position, _positionKey);
        }

        // Check Market has enough available liquidity for all transfers out.
        // In cases where the market is insolvent, there may not be enough in the pool to pay out a profitable position.
        MarketUtils.hasSufficientLiquidity(
            vault, _feeState.afterFeeAmount + _feeState.affiliateRebate + _feeState.feeForExecutor, _position.isLong
        );

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
     * =========================================== Private Helper Functions ===========================================
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
        Position.Data memory position = tradeStorage.getPosition(_positionKey);

        if (position.user == address(0)) revert TradeEngine_PositionDoesNotExist();

        uint48 requestTimestamp = priceFeed.getRequestTimestamp(_requestKey);
        Execution.validatePriceRequest(priceFeed, _feeReceiver, _requestKey);

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
        if (_feeState.feeForExecutor > 0) {
            vault.transferOutTokens(_executor, _feeState.feeForExecutor, _isLong, false);
        }

        if (_feeState.affiliateRebate > 0) {
            vault.transferOutTokens(
                address(referralStorage),
                _feeState.affiliateRebate,
                _isLong,
                false // Leave unwrapped by default
            );
        }

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
            uint256 reserveDelta = _sizeDeltaUsd.fromUsd(_collateralPrice, _collateralBaseUnit);
            // Reserve an Amount of Liquidity Equal to the Position Size
            vault.updateLiquidityReservation(reserveDelta, _isLong, _isReserve);
        }

        vault.updateCollateralAmount(_collateralDelta, _user, _isLong, _isReserve, _isFullDecrease);
    }

    function _accumulateFees(
        IVault vault,
        IReferralStorage referralStorage,
        Execution.FeeState memory _feeState,
        bool _isLong
    ) private {
        vault.accumulateFees(_feeState.borrowFee + _feeState.positionFee, _isLong);

        if (_feeState.affiliateRebate > 0) {
            referralStorage.accumulateAffiliateRewards(_feeState.referrer, _isLong, _feeState.affiliateRebate);
        }

        vault.updatePoolBalance(_feeState.fundingFee.abs(), _isLong, _feeState.fundingFee < 0);
    }

    /**
     * To handle insolvency case for liquidations, we do the following:
     * - Pay fees in order of importance, each time checking if the remaining amount is sufficient.
     * - Once the remaining amount is used up, stop paying fees.
     * - If any is remaining after paying all fees, add to pool.
     */
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
