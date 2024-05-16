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
import {MarketId} from "../types/MarketId.sol";
import {OwnableRoles} from "../auth/OwnableRoles.sol";
import {ReentrancyGuard} from "../utils/ReentrancyGuard.sol";
import {console2} from "forge-std/Test.sol";

/// @notice Library responsible for handling all execution logic associated with trades
/// @dev Functions are external to avoid bytecode size issues.
contract TradeEngine is OwnableRoles, ReentrancyGuard {
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
    error TradeEngine_AlreadyInitialized();

    ITradeStorage tradeStorage;
    IMarket market;
    IPriceFeed priceFeed;
    IReferralStorage referralStorage;
    IPositionManager positionManager;

    bool initialized;
    // Percentage with 18 decimal places
    uint64 public liquidationFee;
    uint256 public minCollateralUsd;
    // Stored as percentages with 18 D.P (e.g 0.05e18 = 5%)
    uint64 public adlFee;
    uint64 public tradingFee;
    uint64 public feeForExecution;

    constructor(address _tradeStorage, address _market) {
        _initializeOwner(msg.sender);
        tradeStorage = ITradeStorage(_tradeStorage);
        market = IMarket(_market);
    }

    function initialize(
        address _priceFeed,
        address _referralStorage,
        address _positionManager,
        uint256 _minCollateralUsd,
        uint64 _liquidationFee,
        uint64 _adlFee,
        uint64 _tradingFee,
        uint64 _feeForExecution
    ) external onlyOwner {
        if (initialized) revert TradeEngine_AlreadyInitialized();
        priceFeed = IPriceFeed(_priceFeed);
        referralStorage = IReferralStorage(_referralStorage);
        positionManager = IPositionManager(_positionManager);
        minCollateralUsd = _minCollateralUsd;
        liquidationFee = _liquidationFee;
        adlFee = _adlFee;
        tradingFee = _tradingFee;
        feeForExecution = _feeForExecution;
        initialized = true;
    }

    function updateFees(
        uint256 _minCollateralUsd,
        uint64 _liquidationFee,
        uint64 _adlFee,
        uint64 _tradingFee,
        uint64 _feeForExecution
    ) external onlyOwner {
        minCollateralUsd = _minCollateralUsd;
        liquidationFee = _liquidationFee;
        adlFee = _adlFee;
        tradingFee = _tradingFee;
        feeForExecution = _feeForExecution;
    }

    function executePositionRequest(MarketId _id, Position.Settlement memory _params)
        external
        onlyRoles(_ROLE_4)
        nonReentrant
        returns (Execution.FeeState memory, Position.Request memory)
    {
        IVault vault = market.getVault(_id);

        Execution.Prices memory prices;
        (prices, _params.request) = Execution.initiate(
            _id, market, vault, priceFeed, _params.orderKey, _params.limitRequestKey, _params.feeReceiver
        );

        tradeStorage.deleteOrder(_id, _params.orderKey, _params.request.input.isLimit);

        _updateMarketState(
            _id,
            prices,
            _params.request.input.ticker,
            _params.request.input.sizeDelta,
            _params.request.input.isLong,
            _params.request.input.isIncrease
        );

        Execution.FeeState memory feeState;
        if (_params.request.requestType == Position.RequestType.CREATE_POSITION) {
            feeState = _createNewPosition(_id, vault, _params, prices);
        } else if (_params.request.requestType == Position.RequestType.POSITION_INCREASE) {
            feeState = _increasePosition(_id, vault, _params, prices);
        } else {
            // Decrease, SL & TP
            feeState = _decreasePosition(_id, vault, _params, prices);
        }

        return (feeState, _params.request);
    }

    function executeAdl(MarketId _id, bytes32 _positionKey, bytes32 _requestKey, address _feeReceiver)
        external
        onlyRoles(_ROLE_4)
        nonReentrant
    {
        IVault vault = market.getVault(_id);

        (Execution.Prices memory prices, Position.Settlement memory params, int256 startingPnlFactor) =
            _initiateAdl(_id, vault, _positionKey, _requestKey, _feeReceiver);

        _updateMarketState(
            _id, prices, params.request.input.ticker, params.request.input.sizeDelta, params.request.input.isLong, false
        );

        _decreasePosition(_id, vault, params, prices);

        Execution.validateAdl(
            _id, market, vault, prices, startingPnlFactor, params.request.input.ticker, params.request.input.isLong
        );

        emit AdlExecuted(address(market), _positionKey, params.request.input.sizeDelta, params.request.input.isLong);
    }

    function liquidatePosition(MarketId _id, bytes32 _positionKey, bytes32 _requestKey, address _liquidator)
        external
        onlyRoles(_ROLE_4)
        nonReentrant
    {
        IVault vault = market.getVault(_id);

        Position.Data memory position = tradeStorage.getPosition(_id, _positionKey);

        if (position.user == address(0)) revert TradeEngine_PositionDoesNotExist();

        uint48 requestTimestamp = priceFeed.getRequestTimestamp(_requestKey);
        Execution.validatePriceRequest(priceFeed, _liquidator, _requestKey);

        Execution.Prices memory prices =
            Execution.getTokenPrices(priceFeed, position.ticker, requestTimestamp, position.isLong, false);

        // No price impact on Liquidations
        prices.impactedPrice = prices.indexPrice;

        _updateMarketState(_id, prices, position.ticker, position.size, position.isLong, false);

        Position.Settlement memory params =
            Position.createLiquidationOrder(position, prices.collateralPrice, prices.collateralBaseUnit, _liquidator);

        _decreasePosition(_id, vault, params, prices);

        emit LiquidatePosition(_positionKey, _liquidator, position.isLong);
    }

    /**
     * =========================================== Core Function Implementations ===========================================
     */
    function _createNewPosition(
        MarketId _id,
        IVault vault,
        Position.Settlement memory _params,
        Execution.Prices memory _prices
    ) private returns (Execution.FeeState memory feeState) {
        bytes32 positionKey = Position.generateKey(_params.request);

        Position.Data memory position;
        (position, feeState) = Execution.createNewPosition(
            _id, market, tradeStorage, referralStorage, _params, _prices, minCollateralUsd, positionKey
        );

        _accumulateFees(_id, vault, feeState, position.isLong);

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

        tradeStorage.createPosition(_id, position, positionKey);

        positionManager.transferTokensForIncrease(
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
        MarketId _id,
        IVault vault,
        Position.Settlement memory _params,
        Execution.Prices memory _prices
    ) private returns (Execution.FeeState memory feeState) {
        bytes32 positionKey = Position.generateKey(_params.request);

        Position.Data memory position;
        (feeState, position) =
            Execution.increasePosition(_id, market, tradeStorage, referralStorage, _params, _prices, positionKey);

        _accumulateFees(_id, vault, feeState, position.isLong);

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

        tradeStorage.updatePosition(_id, position, positionKey);

        positionManager.transferTokensForIncrease(
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
        MarketId _id,
        IVault vault,
        Position.Settlement memory _params,
        Execution.Prices memory _prices
    ) private returns (Execution.FeeState memory feeState) {
        bytes32 positionKey = Position.generateKey(_params.request);

        Position.Data memory position;

        bool isCollateralEdit = _params.request.input.sizeDelta == 0;

        if (isCollateralEdit) {
            (position, feeState) = Execution.decreaseCollateral(
                _id, market, tradeStorage, referralStorage, _params, _prices, minCollateralUsd, positionKey
            );
        } else {
            (position, feeState) = Execution.decreasePosition(
                _id,
                market,
                tradeStorage,
                referralStorage,
                _params,
                _prices,
                minCollateralUsd,
                _params.isAdl ? adlFee : liquidationFee,
                positionKey
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
            feeState = _handleLiquidation(_id, vault, position, feeState, _prices, positionKey, _params.request.user);
        } else if (isCollateralEdit) {
            _handleCollateralDecrease(
                _id, vault, position, feeState, positionKey, _params.feeReceiver, _params.request.input.reverseWrap
            );
        } else {
            _handlePositionDecrease(
                _id, vault, position, feeState, positionKey, _params.feeReceiver, _params.request.input.reverseWrap
            );
        }

        emit DecreasePosition(positionKey, _params.request.input.collateralDelta, _params.request.input.sizeDelta);
    }

    function _handleLiquidation(
        MarketId _id,
        IVault vault,
        Position.Data memory _position,
        Execution.FeeState memory _feeState,
        Execution.Prices memory _prices,
        bytes32 _positionKey,
        address _liquidator
    ) private returns (Execution.FeeState memory) {
        tradeStorage.deletePosition(_id, _positionKey, _position.isLong);

        _deleteAssociatedOrders(_id, _position.stopLossKey, _position.takeProfitKey);

        _feeState = _adjustFeesForInsolvency(
            _feeState, _position.collateral.fromUsd(_prices.collateralPrice, _prices.collateralBaseUnit)
        );

        _accumulateFees(_id, vault, _feeState, _position.isLong);

        vault.updatePoolBalance(_feeState.afterFeeAmount, _position.isLong, true);

        // Pay the Liquidated User if owed anything
        if (_feeState.amountOwedToUser > 0) {
            vault.updatePoolBalance(_feeState.amountOwedToUser, _position.isLong, false);
        }

        _transferTokensForDecrease(
            vault,
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
        MarketId _id,
        IVault vault,
        Position.Data memory _position,
        Execution.FeeState memory _feeState,
        bytes32 _positionKey,
        address _feeReceiver,
        bool _reverseWrap
    ) private {
        _accumulateFees(_id, vault, _feeState, _position.isLong);

        tradeStorage.updatePosition(_id, _position, _positionKey);

        _transferTokensForDecrease(
            vault, _feeState, _feeState.afterFeeAmount, _feeReceiver, _position.user, _position.isLong, _reverseWrap
        );
    }

    function _handlePositionDecrease(
        MarketId _id,
        IVault vault,
        Position.Data memory _position,
        Execution.FeeState memory _feeState,
        bytes32 _positionKey,
        address _executor,
        bool _reverseWrap
    ) private {
        _accumulateFees(_id, vault, _feeState, _position.isLong);

        console2.log("Realized Pnl: ", _feeState.realizedPnl);

        vault.updatePoolBalance(_feeState.realizedPnl.abs(), _position.isLong, _feeState.realizedPnl < 0);

        if (_position.size == 0 || _position.collateral == 0) {
            tradeStorage.deletePosition(_id, _positionKey, _position.isLong);
            _deleteAssociatedOrders(_id, _position.stopLossKey, _position.takeProfitKey);
        } else {
            tradeStorage.updatePosition(_id, _position, _positionKey);
        }

        // Check Market has enough available liquidity for all transfers out.
        // In cases where the market is insolvent, there may not be enough in the pool to pay out a profitable position.
        MarketUtils.hasSufficientLiquidity(
            vault, _feeState.afterFeeAmount + _feeState.affiliateRebate + _feeState.feeForExecutor, _position.isLong
        );

        _transferTokensForDecrease(
            vault, _feeState, _feeState.afterFeeAmount, _executor, _position.user, _position.isLong, _reverseWrap
        );
    }

    /**
     * =========================================== Private Helper Functions ===========================================
     */
    function _initiateAdl(MarketId _id, IVault vault, bytes32 _positionKey, bytes32 _requestKey, address _feeReceiver)
        private
        view
        returns (Execution.Prices memory prices, Position.Settlement memory params, int256 startingPnlFactor)
    {
        Position.Data memory position = tradeStorage.getPosition(_id, _positionKey);

        if (position.user == address(0)) revert TradeEngine_PositionDoesNotExist();

        uint48 requestTimestamp = priceFeed.getRequestTimestamp(_requestKey);
        Execution.validatePriceRequest(priceFeed, _feeReceiver, _requestKey);

        (prices, params, startingPnlFactor) =
            Execution.initiateAdlOrder(_id, market, vault, priceFeed, position, requestTimestamp, _feeReceiver);
    }

    /// @dev - Can fail on insolvency.
    function _transferTokensForDecrease(
        IVault vault,
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
        MarketId _id,
        Execution.Prices memory _prices,
        string memory _ticker,
        uint256 _sizeDelta,
        bool _isLong,
        bool _isIncrease
    ) private {
        market.updateMarketState(_id, _ticker, _sizeDelta, _prices, _isLong, _isIncrease);

        // If Price Impact is Negative, add to the impact Pool
        // If Price Impact is Positive, Subtract from the Impact Pool
        // Impact Pool Delta = -1 * Price Impact
        if (_prices.priceImpactUsd == 0) return;

        market.updateImpactPool(_id, _ticker, -_prices.priceImpactUsd);
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

    function _accumulateFees(MarketId _id, IVault vault, Execution.FeeState memory _feeState, bool _isLong) private {
        vault.accumulateFees(_feeState.borrowFee + _feeState.positionFee, _isLong);

        if (_feeState.affiliateRebate > 0) {
            referralStorage.accumulateAffiliateRewards(_id, _feeState.referrer, _isLong, _feeState.affiliateRebate);
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

    function _deleteAssociatedOrders(MarketId _id, bytes32 _stopLossKey, bytes32 _takeProfitKey) private {
        if (_stopLossKey != bytes32(0)) tradeStorage.deleteOrder(_id, _stopLossKey, true);
        if (_takeProfitKey != bytes32(0)) tradeStorage.deleteOrder(_id, _takeProfitKey, true);
    }
}
