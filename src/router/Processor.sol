//  ,----,------------------------------,------.
//   | ## |                              |    - |
//   | ## |                              |    - |
//   |    |------------------------------|    - |
//   |    ||............................||      |
//   |    ||,-                        -.||      |
//   |    ||___                      ___||    ##|
//   |    ||---`--------------------'---||      |
//   `--mb'|_|______________________==__|`------'

//    ____  ____  ___ _   _ _____ _____ ____
//   |  _ \|  _ \|_ _| \ | |_   _|___ /|  _ \
//   | |_) | |_) || ||  \| | | |   |_ \| |_) |
//   |  __/|  _ < | || |\  | | |  ___) |  _ <
//   |_|   |_| \_\___|_| \_| |_| |____/|_| \_\

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {IMarket} from "../markets/interfaces/IMarket.sol";
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
import {Order} from "../positions/Order.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IPriceFeed} from "../oracle/interfaces/IPriceFeed.sol";
import {Oracle} from "../oracle/Oracle.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Gas} from "../libraries/Gas.sol";
import {Deposit} from "../markets/Deposit.sol";
import {Withdrawal} from "../markets/Withdrawal.sol";
import {IProcessor} from "./interfaces/IProcessor.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {mulDiv} from "@prb/math/Common.sol";
import {Roles} from "../access/roles.sol";

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
    function executeDeposit(IMarket market, bytes32 _key, int256 _cumulativeMarketPnl)
        external
        nonReentrant
        onlyKeeper
    {
        uint256 initialGas = gasleft();
        if (_key == bytes32(0)) revert Processor_InvalidKey();
        // Fetch the request
        Deposit.ExecuteParams memory params;
        params.market = market;
        params.processor = this;
        params.priceFeed = priceFeed;
        params.data = market.getDepositRequest(_key);
        params.key = _key;
        params.cumulativePnl = _cumulativeMarketPnl;
        params.isLongToken = params.data.input.tokenIn == market.LONG_TOKEN();
        try market.executeDeposit(params) {}
        catch {
            revert("Processor: Execute Deposit Failed");
        }
        // Send Execution Fee + Rebate
        Gas.payExecutionFee(
            this, params.data.input.executionFee, initialGas, payable(params.data.input.owner), payable(msg.sender)
        );
    }

    // @audit - keeper needs to pass in cumulative net pnl
    // Must make sure this value is valid. Get by looping through all current active markets
    // and summing their PNLs
    // @audit - what happens if the prices of many markets are stale?
    function executeWithdrawal(IMarket market, bytes32 _key, int256 _cumulativeMarketPnl)
        external
        nonReentrant
        onlyKeeper
    {
        uint256 initialGas = gasleft();
        if (_key == bytes32(0)) revert Processor_InvalidKey();
        // Fetch the request
        Withdrawal.ExecuteParams memory params;
        params.market = market;
        params.processor = this;
        params.priceFeed = priceFeed;
        params.data = market.getWithdrawalRequest(_key);
        params.key = _key;
        params.cumulativePnl = _cumulativeMarketPnl;
        params.isLongToken = params.data.input.tokenOut == market.LONG_TOKEN();
        params.shouldUnwrap = params.data.input.shouldUnwrap;
        try market.executeWithdrawal(params) {}
        catch {
            revert("Processor: Execute Withdrawal Failed");
        }
        // Send Execution Fee + Rebate
        Gas.payExecutionFee(
            this, params.data.input.executionFee, initialGas, payable(params.data.input.owner), payable(msg.sender)
        );
    }

    // Used to transfer intermediary tokens to the market from deposits
    function transferDepositTokens(address _market, address _token, uint256 _amount) external onlyMarket {
        IERC20(_token).safeTransfer(_market, _amount);
    }

    /// @dev Only Keeper
    // @audit - Need a step to validate the trade doesn't put the market over its
    // allocation (_validateAllocation)
    /// @param _isTradingEnabled: Flag for disabling trading of asset types outside of trading hours
    // @audit - should we charge for a decrease? Or only increase positions
    function executePosition(
        bytes32 _orderKey,
        address _feeReceiver,
        Oracle.TradingEnabled memory _isTradingEnabled,
        bytes[] memory _priceUpdateData,
        address _indexToken,
        uint256 _indexPrice
    ) external nonReentrant onlyKeeperOrSelf {
        uint256 initialGas = gasleft();
        uint256 priceUpdateFee = _signLatestPrices(_indexToken, _priceUpdateData, _indexPrice);
        (Order.ExecutionState memory state, Position.Request memory request) = Order.constructExecuteParams(
            tradeStorage, marketMaker, priceFeed, _orderKey, _feeReceiver, _isTradingEnabled
        );
        _updateImpactPool(state.market, _indexToken, state.priceImpactUsd);
        _updateMarketState(state, _indexToken, request.input.sizeDelta, request.input.isLong, request.input.isIncrease);

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
            tradeStorage.createNewPosition(Position.Execution(request, _orderKey, _feeReceiver, false), state);
        } else if (request.requestType == Position.RequestType.POSITION_DECREASE) {
            tradeStorage.decreaseExistingPosition(Position.Execution(request, _orderKey, _feeReceiver, false), state);
        } else if (request.requestType == Position.RequestType.POSITION_INCREASE) {
            tradeStorage.increaseExistingPosition(Position.Execution(request, _orderKey, _feeReceiver, false), state);
        } else if (request.requestType == Position.RequestType.COLLATERAL_DECREASE) {
            tradeStorage.executeCollateralDecrease(Position.Execution(request, _orderKey, _feeReceiver, false), state);
        } else if (request.requestType == Position.RequestType.COLLATERAL_INCREASE) {
            tradeStorage.executeCollateralIncrease(Position.Execution(request, _orderKey, _feeReceiver, false), state);
        } else if (request.requestType == Position.RequestType.TAKE_PROFIT) {
            tradeStorage.decreaseExistingPosition(Position.Execution(request, _orderKey, _feeReceiver, false), state);
        } else if (request.requestType == Position.RequestType.STOP_LOSS) {
            tradeStorage.decreaseExistingPosition(Position.Execution(request, _orderKey, _feeReceiver, false), state);
        } else {
            revert Processor_InvalidRequestType();
        }

        if (request.input.isIncrease) {
            _transferTokensForIncrease(state, request, state.fee, state.affiliateRebate, request.input.isLong);
        }

        // Emit Trade Executed Event
        emit ExecutePosition(_orderKey, request, state.fee, state.affiliateRebate);

        // Send Execution Fee + Rebate
        // Execution Fee reduced to account for value sent to update Pyth prices
        Gas.payExecutionFee(
            this, (request.input.executionFee - priceUpdateFee), initialGas, payable(_feeReceiver), payable(msg.sender)
        );
    }

    // need to store who flagged and liquidated
    // let the liquidator claim liquidation rewards from the tradestorage contract
    // Need to update prices for Index Token, Long Token, Short Token
    function liquidatePosition(bytes32 _positionKey, bytes[] memory _priceData)
        external
        payable
        onlyLiquidationKeeper
    {
        // need to construct ExecutionState
        Order.ExecutionState memory state;
        // fetch position
        Position.Data memory position = tradeStorage.getPosition(_positionKey);
        state.market = position.market;

        // fetch prices, base units, calculate sizeDeltaUsd, no fee / discount, no ref, no impact
        uint256 updateFee = priceFeed.getPrimaryUpdateFee(_priceData);
        priceFeed.signPriceData{value: updateFee}(position.indexToken, _priceData);

        if (position.isLong) {
            state.indexPrice = Oracle.getMaxPrice(priceFeed, position.indexToken, block.number);
            (state.longMarketTokenPrice, state.shortMarketTokenPrice) = Oracle.getLastMarketTokenPrices(priceFeed, true);
            state.collateralPrice = state.longMarketTokenPrice;
        } else {
            state.indexPrice = Oracle.getMinPrice(priceFeed, position.indexToken, block.number);
            (state.longMarketTokenPrice, state.shortMarketTokenPrice) =
                Oracle.getLastMarketTokenPrices(priceFeed, false);
            state.collateralPrice = state.shortMarketTokenPrice;
        }

        state.indexBaseUnit = Oracle.getBaseUnit(priceFeed, position.indexToken);
        state.impactedPrice = state.indexPrice;

        state.collateralBaseUnit =
            position.isLong ? Oracle.getLongBaseUnit(priceFeed) : Oracle.getShortBaseUnit(priceFeed);

        // call _updateMarketState
        _updateMarketState(state, position.indexToken, position.positionSize, position.isLong, false);
        // liquidate the position
        try tradeStorage.liquidatePosition(state, _positionKey, msg.sender) {}
        catch {
            revert("Processor: Liquidation Failed");
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

    function flagForAdl(IMarket market, address _indexToken, bool _isLong) external onlyAdlKeeper {
        if (market == IMarket(address(0))) revert Processor_InvalidMarket();
        // get current price
        uint256 indexPrice = Oracle.getReferencePrice(priceFeed, _indexToken);
        uint256 collateralPrice;
        uint256 collateralBaseUnit;
        if (_isLong) {
            (collateralPrice,) = Oracle.getLastMarketTokenPrices(priceFeed, true);
            collateralBaseUnit = Oracle.getLongBaseUnit(priceFeed);
        } else {
            (, collateralPrice) = Oracle.getLastMarketTokenPrices(priceFeed, false);
            collateralBaseUnit = Oracle.getShortBaseUnit(priceFeed);
        }

        // fetch pnl to pool ratio
        uint256 indexBaseUnit = Oracle.getBaseUnit(priceFeed, _indexToken);

        int256 pnlFactor = MarketUtils.getPnlFactor(
            market, _indexToken, indexPrice, indexBaseUnit, collateralPrice, collateralBaseUnit, _isLong
        );
        // fetch max pnl to pool ratio
        uint256 maxPnlFactor = market.getMaxPnlFactor(_indexToken);

        if (pnlFactor.abs() > maxPnlFactor && pnlFactor > 0) {
            market.updateAdlState(_indexToken, true, _isLong);
        } else {
            revert("ADL: PTP ratio not exceeded");
        }
    }

    function executeAdl(
        IMarket market,
        address _indexToken,
        uint256 _sizeDelta,
        bytes32 _positionKey,
        bool _isLong,
        bytes[] memory _priceData
    ) external payable onlyAdlKeeper {
        Order.ExecutionState memory state;
        IMarket.AdlConfig memory adl = market.getAdlConfig(_indexToken);
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
        // fetch prices, base units, calculate sizeDeltaUsd, no fee / discount, no ref, no impact
        priceFeed.signPriceData{value: msg.value}(position.indexToken, _priceData);
        // Get current pricing and token data
        state =
            Order.retrieveTokenPrices(priceFeed, state, position.indexToken, block.number, position.isLong, false, true);

        // Set the impacted price to the index price => 0 price impact on ADLs
        state.impactedPrice = state.indexPrice;
        state.priceImpactUsd = 0;
        // Get starting PNL Factor
        int256 startingPnlFactor = MarketUtils.getPnlFactor(
            market,
            _indexToken,
            state.indexPrice,
            state.indexBaseUnit,
            state.collateralPrice,
            state.collateralBaseUnit,
            _isLong
        );
        // Construct an ADL Order
        Position.Execution memory request = Position.createAdlOrder(position, _sizeDelta);
        // Execute the order
        tradeStorage.decreaseExistingPosition(request, state);
        // Get the new PNL to pool ratio
        int256 newPnlFactor = MarketUtils.getPnlFactor(
            market,
            _indexToken,
            state.indexPrice,
            state.indexBaseUnit,
            state.collateralPrice,
            state.collateralBaseUnit,
            _isLong
        );
        // PNL to pool has reduced
        if (newPnlFactor >= startingPnlFactor) revert Processor_PNLFactorNotReduced();
        // Check if the new PNL to pool ratio is greater than
        // the min PNL factor after ADL (~20%)
        // If not, unflag for ADL
        if (newPnlFactor.abs() <= adl.targetPnlFactor) {
            market.updateAdlState(_indexToken, false, _isLong);
        }
        emit AdlExecuted(market, _positionKey, _sizeDelta, _isLong);
    }

    // For when Router requests a secondary price update
    // User prepays the execution fee
    // This function updates the price on-chain and releases the execution fee
    // to the keeper
    // Excess fees are returned to the user
    // Only needed if price hasn't already been updated in the same block
    // @audit - review logic
    function executePriceUpdate(address _token, uint256 _price, uint256 _block) external onlyKeeper {
        uint256 initialGas = gasleft();
        if (_price == 0) revert Processor_InvalidPrice();
        if (priceFeed.getPrice(_token, _block).price != 0) revert Processor_PriceAlreadyUpdated();
        priceFeed.setAssetPrice(_token, _price, _block);
        Gas.refundPriceUpdateGas(this, initialGas, payable(msg.sender));
    }

    // @audit - is this vulnerable?
    function sendExecutionFee(address payable _to, uint256 _amount) external onlyRouterOrProcessor {
        _to.sendValue(_amount);
    }
    // @audit - discount needs to be halved
    // 50% goes to the referrer, 50% goes to the user

    function _transferTokensForIncrease(
        Order.ExecutionState memory _state,
        Position.Request memory _request,
        uint256 _fee,
        uint256 _affiliateRebate,
        bool _isLong
    ) internal {
        // Transfer Fee Discount to Referral Storage
        if (_affiliateRebate > 0) {
            // If units need to be converted (not a collateral edit) convert them
            uint256 rebate;
            if (
                _request.requestType != Position.RequestType.COLLATERAL_INCREASE
                    || _request.requestType != Position.RequestType.COLLATERAL_DECREASE
            ) {
                rebate =
                    Position.convertUsdToCollateral(_affiliateRebate, _state.collateralPrice, _state.collateralBaseUnit);
            } else {
                rebate = _affiliateRebate;
            }
            // Increment Referral Storage Fee Balance
            referralStorage.accumulateAffiliateRewards(_state.referrer, _isLong, rebate);
            // Transfer Fee Discount to Referral Storage
            IERC20(_request.input.collateralToken).safeTransfer(address(referralStorage), rebate);
        }

        // Transfer Collateral to market
        uint256 afterFeeAmount = _request.input.collateralDelta - _affiliateRebate - _fee;
        _state.market.increasePoolBalance(afterFeeAmount, _isLong);
        _state.market.accumulateFees(_fee, _isLong);
        IERC20(_request.input.collateralToken).safeTransfer(address(_state.market), afterFeeAmount + _fee);
    }

    function _calculateValueUsd(uint256 _tokenAmount, uint256 _tokenPrice, uint256 _tokenBaseUnit, bool _isIncrease)
        internal
        pure
        returns (int256 valueUsd)
    {
        // Flip sign if decreasing position
        uint256 absValueUsd = Position.getTradeValueUsd(_tokenAmount, _tokenPrice, _tokenBaseUnit);
        if (_isIncrease) {
            valueUsd = absValueUsd.toInt256();
        } else {
            valueUsd = -1 * absValueUsd.toInt256();
        }
    }

    function _updateMarketState(
        Order.ExecutionState memory _state,
        address _indexToken,
        uint256 _sizeDelta,
        bool _isLong,
        bool _isIncrease
    ) internal {
        if (_sizeDelta != 0) {
            // Use Impacted Price for Entry
            int256 signedSizeDelta = _isIncrease ? _sizeDelta.toInt256() : -_sizeDelta.toInt256();
            _state.market.updateAverageEntryPrice(_indexToken, _state.impactedPrice, signedSizeDelta, _isLong);
            // Average Entry Price relies on OI, so it must be updated before this
            _state.market.updateOpenInterest(_indexToken, _sizeDelta, _isLong, _isIncrease);
        }
        // @audit should this be before or after the OI / AEP update?
        uint256 collateralPrice = _isLong ? _state.longMarketTokenPrice : _state.shortMarketTokenPrice;
        uint256 collateralBaseUnit = _isLong ? Oracle.getLongBaseUnit(priceFeed) : Oracle.getShortBaseUnit(priceFeed);
        _state.market.updateFundingRate(_indexToken, _state.indexPrice);
        _state.market.updateBorrowingRate(
            _indexToken, _state.indexPrice, _state.indexBaseUnit, collateralPrice, collateralBaseUnit, _isLong
        );
    }

    function _updateImpactPool(IMarket market, address _indexToken, int256 _priceImpactUsd) internal {
        // If Price Impact is Negative, add to the impact Pool
        // If Price Impact is Positive, Subtract from the Impact Pool
        // Impact Pool Delta = -1 * Price Impact
        if (_priceImpactUsd == 0) return;
        market.updateImpactPool(_indexToken, -_priceImpactUsd);
    }

    // Pyth Price Update Data will always at least contain the 2 market tokens
    // Index Token can have a Pyth Price, or a Secondary Price
    // If the Price Provider isn't pyth, use _indexPrice and store it in storage
    function _signLatestPrices(address _indexToken, bytes[] memory _priceUpdateData, uint256 _indexPrice)
        internal
        returns (uint256 updateFee)
    {
        Oracle.Asset memory asset = priceFeed.getAsset(_indexToken);
        updateFee = priceFeed.getPrimaryUpdateFee(_priceUpdateData);
        // Update fee paid to Pyth: needs to be accounted for
        priceFeed.signPriceData{value: updateFee}(_indexToken, _priceUpdateData);
        if (asset.priceProvider != Oracle.PriceProvider.PYTH) {
            if (_indexPrice == 0) revert Processor_InvalidPrice();
            // fee accounted for in gas costs
            priceFeed.setAssetPrice(_indexToken, _indexPrice, block.number);
        }
    }
}
