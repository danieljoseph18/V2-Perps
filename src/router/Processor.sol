// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IMarket, IVault} from "../markets/interfaces/IMarket.sol";
import {ITradeStorage} from "../positions/interfaces/ITradeStorage.sol";
import {IMarketMaker} from "../markets/interfaces/IMarketMaker.sol";
import {RoleValidation} from "../access/RoleValidation.sol";
import {ReentrancyGuard} from "@solmate/utils/ReentrancyGuard.sol";
import {Position} from "../positions/Position.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MarketUtils} from "../markets/MarketUtils.sol";
import {Fee} from "../libraries/Fee.sol";
import {Referral} from "../referrals/Referral.sol";
import {IReferralStorage} from "../referrals/interfaces/IReferralStorage.sol";
import {Execution} from "../positions/Execution.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IPriceFeed} from "../oracle/interfaces/IPriceFeed.sol";
import {Oracle} from "../oracle/Oracle.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Gas} from "../libraries/Gas.sol";
import {IProcessor} from "./interfaces/IProcessor.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {mulDiv} from "@prb/math/Common.sol";
import {Roles} from "../access/Roles.sol";
import {Invariant} from "../libraries/Invariant.sol";
import {Pricing} from "../libraries/Pricing.sol";

/// @dev Needs Processor Role
// All keeper interactions should come through this contract
contract Processor is IProcessor, RoleValidation, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using Address for address payable;
    using SignedMath for int256;

    ITradeStorage public tradeStorage;
    IMarketMaker public marketMaker;
    IReferralStorage public referralStorage;
    IPriceFeed public priceFeed;

    // Base Gas for a TX
    uint256 public baseGasLimit;
    // Upper Bounds to account for fluctuations
    uint256 public depositGasLimit;
    uint256 public withdrawalGasLimit;
    uint256 public positionGasLimit; // Accounts for Price Updates

    constructor(
        address _marketMaker,
        address _tradeStorage,
        address _referralStorage,
        address _priceFeed,
        address _roleStorage
    ) RoleValidation(_roleStorage) {
        marketMaker = IMarketMaker(_marketMaker);
        tradeStorage = ITradeStorage(_tradeStorage);
        referralStorage = IReferralStorage(_referralStorage);
        priceFeed = IPriceFeed(_priceFeed);
    }

    receive() external payable {}

    modifier onlyMarket() {
        if (!marketMaker.isMarket(msg.sender)) revert Processor_AccessDenied();
        _;
    }

    modifier signOraclePrices(Oracle.PriceUpdateData calldata _priceUpdateData) {
        uint256 updateFee = priceFeed.updateFee(_priceUpdateData.pythData);
        if (msg.value < updateFee) revert Processor_PriceUpdateFee();
        priceFeed.setPrimaryPrices{value: msg.value}(
            _priceUpdateData.assetIds, _priceUpdateData.pythData, _priceUpdateData.compactedPrices
        );
        _;
        priceFeed.clearPrimaryPrices();
    }

    function updateGasLimits(uint256 _base, uint256 _deposit, uint256 _withdrawal, uint256 _position)
        external
        onlyAdmin
    {
        baseGasLimit = _base;
        depositGasLimit = _deposit;
        withdrawalGasLimit = _withdrawal;
        positionGasLimit = _position;
        emit GasLimitsUpdated(_deposit, _withdrawal, _position);
    }

    function updatePriceFeed(IPriceFeed _priceFeed) external onlyConfigurator {
        priceFeed = _priceFeed;
    }

    // @audit - keeper needs to pass in cumulative net pnl
    // Must make sure this value is valid. Get by looping through all current active markets
    // and summing their PNLs
    // @audit - what happens if the prices of many markets are stale?
    function executeDeposit(IMarket market, bytes32 _key, Oracle.PriceUpdateData calldata _priceUpdateData)
        external
        payable
        nonReentrant
        onlyKeeper
        signOraclePrices(_priceUpdateData)
    {
        uint256 initialGas = gasleft();
        if (_key == bytes32(0)) revert Processor_InvalidKey();
        // Fetch the request
        IVault.ExecuteDeposit memory params;
        params.market = market;
        params.processor = this;
        params.priceFeed = priceFeed;
        params.deposit = market.getDepositRequest(_key);
        params.key = _key;
        params.isLongToken = params.deposit.tokenIn == market.LONG_TOKEN();
        params.cumulativePnl = Pricing.calculateCumulativeMarketPnl(market, priceFeed, params.isLongToken, true); // Maximize AUM for deposits
        try market.executeDeposit(params) {}
        catch {
            revert Processor_ExecuteDepositFailed();
        }
        // Send Execution Fee + Rebate
        Gas.payExecutionFee(
            this, params.deposit.executionFee, initialGas, payable(params.deposit.owner), payable(msg.sender)
        );
    }

    function cancelDeposit(IMarket market, bytes32 _depositKey) external nonReentrant {
        IVault.Deposit memory deposit = market.getDepositRequest(_depositKey);
        if (deposit.owner != msg.sender) revert Processor_InvalidDepositOwner();
        if (deposit.expirationTimestamp >= block.timestamp) revert Processor_DepositNotExpired();
        market.deleteDeposit(_depositKey);
        IERC20(deposit.tokenIn).safeTransfer(msg.sender, deposit.amountIn);
        emit DepositRequestCancelled(_depositKey, deposit.owner, deposit.tokenIn, deposit.amountIn);
    }

    // @audit - keeper needs to pass in cumulative net pnl
    // Must make sure this value is valid. Get by looping through all current active markets
    // and summing their PNLs
    // @audit - what happens if the prices of many markets are stale?
    function executeWithdrawal(IMarket market, bytes32 _key, Oracle.PriceUpdateData calldata _priceUpdateData)
        external
        payable
        nonReentrant
        onlyKeeper
        signOraclePrices(_priceUpdateData)
    {
        uint256 initialGas = gasleft();
        if (_key == bytes32(0)) revert Processor_InvalidKey();
        // Fetch the request
        IVault.ExecuteWithdrawal memory params;
        params.market = market;
        params.processor = this;
        params.priceFeed = priceFeed;
        params.withdrawal = market.getWithdrawalRequest(_key);
        params.key = _key;
        params.isLongToken = params.withdrawal.tokenOut == market.LONG_TOKEN();
        params.cumulativePnl = Pricing.calculateCumulativeMarketPnl(market, priceFeed, params.isLongToken, false); // Minimize AUM for withdrawals
        params.shouldUnwrap = params.withdrawal.shouldUnwrap;
        try market.executeWithdrawal(params) {}
        catch {
            revert Processor_ExecuteWithdrawalFailed();
        }
        // Send Execution Fee + Rebate
        Gas.payExecutionFee(
            this, params.withdrawal.executionFee, initialGas, payable(params.withdrawal.owner), payable(msg.sender)
        );
    }

    function cancelWithdrawal(IMarket market, bytes32 _withdrawalKey) external nonReentrant {
        IVault.Withdrawal memory withdrawal = market.getWithdrawalRequest(_withdrawalKey);
        if (withdrawal.owner != msg.sender) revert Processor_InvalidWithdrawalOwner();
        if (withdrawal.expirationTimestamp >= block.timestamp) revert Processor_WithdrawalNotExpired();
        market.deleteWithdrawal(_withdrawalKey);
        IERC20(market.LONG_TOKEN()).safeTransfer(msg.sender, withdrawal.marketTokenAmountIn);
        emit WithdrawalRequestCancelled(
            _withdrawalKey, withdrawal.owner, withdrawal.tokenOut, withdrawal.marketTokenAmountIn
        );
    }

    // Used to transfer intermediary tokens to the market from deposits
    function transferDepositTokens(address _market, address _token, uint256 _amount) external onlyMarket {
        IERC20(_token).safeTransfer(_market, _amount);
    }

    /// @dev Only Keeper
    // @audit - Need a step to validate the trade doesn't put the market over its
    // allocation (_validateAllocation)
    // @audit - don't think we're handling the stop loss / take profit case correctly
    function executePosition(bytes32 _orderKey, address _feeReceiver, Oracle.PriceUpdateData calldata _priceUpdateData)
        external
        payable
        nonReentrant
        onlyKeeper
        signOraclePrices(_priceUpdateData)
    {
        uint256 initialGas = gasleft();
        (Execution.State memory state, Position.Request memory request) =
            Execution.constructParams(tradeStorage, marketMaker, priceFeed, _orderKey, _feeReceiver);
        // Fetch the State of the Market Before the Position
        IMarket.MarketStorage memory marketBefore = state.market.getStorage(request.input.assetId);

        _updateImpactPool(state.market, request.input.assetId, state.priceImpactUsd);
        _updateMarketState(
            state, request.input.assetId, request.input.sizeDelta, request.input.isLong, request.input.isIncrease
        );

        // Calculate Fee
        state.fee = Fee.calculateForPosition(
            tradeStorage,
            request.input.sizeDelta,
            request.input.collateralDelta,
            state.collateralPrice,
            state.collateralBaseUnit
        );

        // Calculate & Apply Fee Discount for Referral Code
        (state.fee, state.affiliateRebate, state.referrer) =
            Referral.applyFeeDiscount(referralStorage, request.user, state.fee);

        // Execute Trade
        if (request.requestType == Position.RequestType.CREATE_POSITION) {
            tradeStorage.createNewPosition(Position.Settlement(request, _orderKey, _feeReceiver, false), state);
        } else if (request.requestType == Position.RequestType.POSITION_DECREASE) {
            tradeStorage.decreaseExistingPosition(Position.Settlement(request, _orderKey, _feeReceiver, false), state);
        } else if (request.requestType == Position.RequestType.POSITION_INCREASE) {
            tradeStorage.increaseExistingPosition(Position.Settlement(request, _orderKey, _feeReceiver, false), state);
        } else if (request.requestType == Position.RequestType.COLLATERAL_DECREASE) {
            tradeStorage.executeCollateralDecrease(Position.Settlement(request, _orderKey, _feeReceiver, false), state);
        } else if (request.requestType == Position.RequestType.COLLATERAL_INCREASE) {
            tradeStorage.executeCollateralIncrease(Position.Settlement(request, _orderKey, _feeReceiver, false), state);
        } else if (request.requestType == Position.RequestType.TAKE_PROFIT) {
            tradeStorage.decreaseExistingPosition(Position.Settlement(request, _orderKey, _feeReceiver, false), state);
        } else if (request.requestType == Position.RequestType.STOP_LOSS) {
            tradeStorage.decreaseExistingPosition(Position.Settlement(request, _orderKey, _feeReceiver, false), state);
        } else {
            revert Processor_InvalidRequestType();
        }

        // Fetch the State of the Market After the Position
        IMarket.MarketStorage memory marketAfter = state.market.getStorage(request.input.assetId);

        // Invariant Check
        Invariant.validateMarketDeltaPosition(marketBefore, marketAfter, request);

        // @audit - is affiliate rebate taken care of for decrease / other positions?
        if (request.input.isIncrease) {
            _transferTokensForIncrease(state.market, request.input.collateralToken, request.input.collateralDelta, state.affiliateRebate);
        }

        // Emit Trade Executed Event
        emit ExecutePosition(_orderKey, request, state.fee, state.affiliateRebate);

        // Send Execution Fee + Rebate
        // Execution Fee reduced to account for value sent to update Pyth prices
        Gas.payExecutionFee(this, request.input.executionFee, initialGas, payable(_feeReceiver), payable(msg.sender));
    }

    // need to store who flagged and liquidated
    // let the liquidator claim liquidation rewards from the tradestorage contract
    // Need to update prices for Index Token, Long Token, Short Token
    // @audit - after liquidation - health score should improve of the pool
    function liquidatePosition(bytes32 _positionKey, Oracle.PriceUpdateData calldata _priceUpdateData)
        external
        payable
        onlyLiquidationKeeper
        signOraclePrices(_priceUpdateData)
    {
        // Construct ExecutionState
        Execution.State memory state;
        // fetch position
        Position.Data memory position = tradeStorage.getPosition(_positionKey);
        state.market = position.market;

        if (position.isLong) {
            // Min Price -> rounds in favour of the protocol
            state.indexPrice = Oracle.getMinPrice(priceFeed, position.assetId);
            (state.longMarketTokenPrice, state.shortMarketTokenPrice) = Oracle.getMarketTokenPrices(priceFeed, false);
            state.collateralPrice = state.longMarketTokenPrice;
        } else {
            // Max Price -> rounds in favour of the protocol
            state.indexPrice = Oracle.getMaxPrice(priceFeed, position.assetId);
            (state.longMarketTokenPrice, state.shortMarketTokenPrice) = Oracle.getMarketTokenPrices(priceFeed, true);
            state.collateralPrice = state.shortMarketTokenPrice;
        }

        state.indexBaseUnit = Oracle.getBaseUnit(priceFeed, position.assetId);
        // No price impact on Liquidations
        state.impactedPrice = state.indexPrice;

        state.collateralBaseUnit =
            position.isLong ? Oracle.getLongBaseUnit(priceFeed) : Oracle.getShortBaseUnit(priceFeed);

        // Update the state of the market
        _updateMarketState(state, position.assetId, position.positionSize, position.isLong, false);
        // liquidate the position
        try tradeStorage.liquidatePosition(state, _positionKey, msg.sender) {}
        catch {
            revert Processor_LiquidationFailed();
        }
    }

    // @audit - is this vulnerable?
    function cancelOrderRequest(bytes32 _key, bool _isLimit) external payable nonReentrant {
        // Fetch the Request
        Position.Request memory request = tradeStorage.getOrder(_key);
        // Check it exists
        if (request.user == address(0)) revert Processor_RequestDoesNotExist();
        // Check if the caller's permissions
        if (!roleStorage.hasRole(Roles.KEEPER, msg.sender)) {
            // Check the caller is the position owner
            if (msg.sender != request.user) revert Processor_NotPositionOwner();
            // Check sufficient time has passed
            if (block.number < request.requestBlock + tradeStorage.minBlockDelay()) {
                revert Processor_InsufficientDelay();
            }
        }
        // Cancel the Request
        tradeStorage.cancelOrderRequest(_key, _isLimit);
        // Refund the Collateral
        IERC20(request.input.collateralToken).safeTransfer(msg.sender, request.input.collateralDelta);
        // Refund the Execution Fee
        uint256 refundAmount = Gas.getRefundForCancellation(request.input.executionFee);
        payable(msg.sender).sendValue(refundAmount);
    }

    function flagForAdl(
        IMarket market,
        bytes32 _assetId,
        bool _isLong,
        Oracle.PriceUpdateData calldata _priceUpdateData
    ) external payable onlyAdlKeeper signOraclePrices(_priceUpdateData) {
        if (market == IMarket(address(0))) revert Processor_InvalidMarket();
        Execution.State memory state;
        // get current price
        state.indexPrice = Oracle.getPrice(priceFeed, _assetId);
        state.collateralPrice;
        state.collateralBaseUnit;
        if (_isLong) {
            (state.collateralPrice,) = Oracle.getMarketTokenPrices(priceFeed, true);
            state.collateralBaseUnit = Oracle.getLongBaseUnit(priceFeed);
        } else {
            (, state.collateralPrice) = Oracle.getMarketTokenPrices(priceFeed, false);
            state.collateralBaseUnit = Oracle.getShortBaseUnit(priceFeed);
        }

        state.indexBaseUnit = Oracle.getBaseUnit(priceFeed, _assetId);
        state.market = market;

        // fetch pnl to pool ratio
        int256 pnlFactor = _getPnlFactor(state, _assetId, _isLong);
        // fetch max pnl to pool ratio
        uint256 maxPnlFactor = market.getMaxPnlFactor(_assetId);

        if (pnlFactor.abs() > maxPnlFactor && pnlFactor > 0) {
            market.updateAdlState(_assetId, true, _isLong);
        } else {
            revert Processor_PnlToPoolRatioNotExceeded(pnlFactor, maxPnlFactor);
        }
    }

    function executeAdl(
        IMarket market,
        bytes32 _assetId,
        uint256 _sizeDelta,
        bytes32 _positionKey,
        bool _isLong,
        Oracle.PriceUpdateData calldata _priceUpdateData
    ) external payable onlyAdlKeeper signOraclePrices(_priceUpdateData) {
        Execution.State memory state;
        IMarket.AdlConfig memory adl = market.getAdlConfig(_assetId);
        // Check ADL is enabled for the market and for the side
        if (_isLong) {
            if (!adl.flaggedLong) revert Processor_LongSideNotFlagged();
        } else {
            if (!adl.flaggedShort) revert Processor_ShortSideNotFlagged();
        }
        // Check the position in question is active
        Position.Data memory position = tradeStorage.getPosition(_positionKey);
        if (position.positionSize == 0) revert Processor_PositionNotActive();
        // state the market
        state.market = market;
        // Get current pricing and token data
        state = Execution.cacheTokenPrices(priceFeed, state, position.assetId, position.isLong, false);

        // Set the impacted price to the index price => 0 price impact on ADLs
        state.impactedPrice = state.indexPrice;
        state.priceImpactUsd = 0;
        // Get starting PNL Factor
        int256 startingPnlFactor = _getPnlFactor(state, _assetId, _isLong);
        // Construct an ADL Order
        Position.Settlement memory request = Position.createAdlOrder(position, _sizeDelta);
        // Execute the order
        tradeStorage.decreaseExistingPosition(request, state);
        // Get the new PNL to pool ratio
        int256 newPnlFactor = _getPnlFactor(state, _assetId, _isLong);
        // PNL to pool has reduced
        if (newPnlFactor >= startingPnlFactor) revert Processor_PNLFactorNotReduced();
        // Check if the new PNL to pool ratio is greater than
        // the min PNL factor after ADL (~20%)
        // If not, unflag for ADL
        if (newPnlFactor.abs() <= adl.targetPnlFactor) {
            market.updateAdlState(_assetId, false, _isLong);
        }
        emit AdlExecuted(market, _positionKey, _sizeDelta, _isLong);
    }

    // @audit - is this vulnerable?
    function sendExecutionFee(address payable _to, uint256 _amount) external onlyProcessor {
        _to.sendValue(_amount);
    }
    // @audit - discount needs to be halved
    // 50% goes to the referrer, 50% goes to the user

    function _transferTokensForIncrease(
        IMarket market,
        address _collateralToken,
        uint256 _collateralDelta,
        uint256 _affiliateRebate
    ) internal {
        // Transfer Fee Discount to Referral Storage
        uint256 tokensPlusFee = _collateralDelta;
        if (_affiliateRebate > 0) {
            // Transfer Fee Discount to Referral Storage
            tokensPlusFee -= _affiliateRebate;
            IERC20(_collateralToken).safeTransfer(address(referralStorage), _affiliateRebate);
        }
        // Send Tokens + Fee to the Market (Will be Accounted for Separately)
        // Subtract Affiliate Rebate -> will go to Referral Storage
        IERC20(_collateralToken).safeTransfer(address(market), tokensPlusFee);
    }

    // @audit - Feels iffy -> need to determine which updates to do before tradestorage call and which are for after
    function _updateMarketState(
        Execution.State memory _state,
        bytes32 _assetId,
        uint256 _sizeDelta,
        bool _isLong,
        bool _isIncrease
    ) internal {
        if (_sizeDelta != 0) {
            // Use Impacted Price for Entry
            int256 signedSizeDelta = _isIncrease ? _sizeDelta.toInt256() : -_sizeDelta.toInt256();
            _state.market.updateAverageEntryPrice(_assetId, _state.impactedPrice, signedSizeDelta, _isLong);
            // Average Entry Price relies on OI, so it must be updated before this
            _state.market.updateOpenInterest(_assetId, _sizeDelta, _isLong, _isIncrease);
        }
        // @audit should this be before or after the OI / AEP update?
        uint256 collateralPrice = _isLong ? _state.longMarketTokenPrice : _state.shortMarketTokenPrice;
        uint256 collateralBaseUnit = _isLong ? Oracle.getLongBaseUnit(priceFeed) : Oracle.getShortBaseUnit(priceFeed);
        _state.market.updateFundingRate(_assetId, _state.indexPrice);
        _state.market.updateBorrowingRate(
            _assetId, _state.indexPrice, _state.indexBaseUnit, collateralPrice, collateralBaseUnit, _isLong
        );
    }

    function _updateImpactPool(IMarket market, bytes32 _assetId, int256 _priceImpactUsd) internal {
        // If Price Impact is Negative, add to the impact Pool
        // If Price Impact is Positive, Subtract from the Impact Pool
        // Impact Pool Delta = -1 * Price Impact
        if (_priceImpactUsd == 0) return;
        market.updateImpactPool(_assetId, -_priceImpactUsd);
    }

    /**
     * Extrapolated into an internal function to prevent STD Errors
     */
    function _getPnlFactor(Execution.State memory _state, bytes32 _assetId, bool _isLong)
        internal
        view
        returns (int256 pnlFactor)
    {
        pnlFactor = MarketUtils.getPnlFactor(
            _state.market,
            _assetId,
            _state.indexPrice,
            _state.indexBaseUnit,
            _state.collateralPrice,
            _state.collateralBaseUnit,
            _isLong
        );
    }
}
