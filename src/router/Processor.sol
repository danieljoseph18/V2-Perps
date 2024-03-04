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
import {Deposit} from "../liquidity/Deposit.sol";
import {Withdrawal} from "../liquidity/Withdrawal.sol";
import {IProcessor} from "./interfaces/IProcessor.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {mulDiv} from "@prb/math/Common.sol";
import {Roles} from "../access/roles.sol";
import {Test, console} from "forge-std/Test.sol";

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
        require(marketMaker.isMarket(msg.sender), "Processor: Invalid Market");
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
        require(_key != bytes32(0), "E: Invalid Key");
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
        require(_key != bytes32(0), "E: Invalid Key");
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
        (Order.ExecuteCache memory cache, Position.Request memory request) = Order.constructExecuteParams(
            tradeStorage, marketMaker, priceFeed, _orderKey, _feeReceiver, _isTradingEnabled
        );
        _updateImpactPool(cache.market, _indexToken, cache.priceImpactUsd);
        _updateMarketState(cache, _indexToken, request.input.sizeDelta, request.input.isLong, request.input.isIncrease);

        // Calculate Fee
        cache.fee = Fee.calculateForPosition(
            tradeStorage,
            request.input.sizeDelta,
            request.input.collateralDelta,
            cache.indexPrice,
            cache.indexBaseUnit,
            cache.collateralPrice,
            cache.collateralBaseUnit
        );
        // Calculate & Apply Fee Discount for Referral Code
        (cache.fee, cache.feeDiscount, cache.referrer) =
            Referral.applyFeeDiscount(referralStorage, request.user, cache.fee);

        // Execute Trade
        if (request.requestType == Position.RequestType.CREATE_POSITION) {
            tradeStorage.createNewPosition(Position.Execution(request, _orderKey, _feeReceiver, false), cache);
        } else if (request.requestType == Position.RequestType.POSITION_DECREASE) {
            tradeStorage.decreaseExistingPosition(Position.Execution(request, _orderKey, _feeReceiver, false), cache);
        } else if (request.requestType == Position.RequestType.POSITION_INCREASE) {
            tradeStorage.increaseExistingPosition(Position.Execution(request, _orderKey, _feeReceiver, false), cache);
        } else if (request.requestType == Position.RequestType.COLLATERAL_DECREASE) {
            tradeStorage.executeCollateralDecrease(Position.Execution(request, _orderKey, _feeReceiver, false), cache);
        } else if (request.requestType == Position.RequestType.COLLATERAL_INCREASE) {
            tradeStorage.executeCollateralIncrease(Position.Execution(request, _orderKey, _feeReceiver, false), cache);
        } else if (request.requestType == Position.RequestType.TAKE_PROFIT) {
            tradeStorage.decreaseExistingPosition(Position.Execution(request, _orderKey, _feeReceiver, false), cache);
        } else if (request.requestType == Position.RequestType.STOP_LOSS) {
            tradeStorage.decreaseExistingPosition(Position.Execution(request, _orderKey, _feeReceiver, false), cache);
        } else {
            revert OrderProcessor_InvalidRequestType();
        }

        if (request.input.isIncrease) {
            _transferTokensForIncrease(cache, request, cache.fee, cache.feeDiscount, request.input.isLong);
        }

        // Emit Trade Executed Event
        emit ExecutePosition(_orderKey, request, cache.fee, cache.feeDiscount);

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
        // need to construct ExecuteCache
        Order.ExecuteCache memory cache;
        // fetch position
        Position.Data memory position = tradeStorage.getPosition(_positionKey);
        cache.market = position.market;

        // fetch prices, base units, calculate sizeDeltaUsd, no fee / discount, no ref, no impact
        uint256 updateFee = priceFeed.getPrimaryUpdateFee(_priceData);
        priceFeed.signPriceData{value: updateFee}(position.indexToken, _priceData);

        if (position.isLong) {
            cache.indexPrice = Oracle.getMaxPrice(priceFeed, position.indexToken, block.number);
            (cache.longMarketTokenPrice, cache.shortMarketTokenPrice) = Oracle.getLastMarketTokenPrices(priceFeed, true);
            cache.collateralPrice = cache.longMarketTokenPrice;
        } else {
            cache.indexPrice = Oracle.getMinPrice(priceFeed, position.indexToken, block.number);
            (cache.longMarketTokenPrice, cache.shortMarketTokenPrice) =
                Oracle.getLastMarketTokenPrices(priceFeed, false);
            cache.collateralPrice = cache.shortMarketTokenPrice;
        }

        cache.indexBaseUnit = Oracle.getBaseUnit(priceFeed, position.indexToken);
        cache.impactedPrice = cache.indexPrice;
        cache.sizeDeltaUsd = _calculateValueUsd(position.positionSize, cache.indexPrice, cache.indexBaseUnit, false);
        cache.collateralBaseUnit =
            position.isLong ? Oracle.getLongBaseUnit(priceFeed) : Oracle.getShortBaseUnit(priceFeed);

        // call _updateMarketState
        _updateMarketState(cache, position.indexToken, position.positionSize, position.isLong, false);
        // liquidate the position
        try tradeStorage.liquidatePosition(cache, _positionKey, msg.sender) {}
        catch {
            revert("Processor: Liquidation Failed");
        }
    }

    // @audit - is this vulnerable?
    function cancelOrderRequest(bytes32 _key, bool _isLimit) external payable nonReentrant {
        // Fetch the Request
        Position.Request memory request = tradeStorage.getOrder(_key);
        // Check it exists
        require(request.user != address(0), "Router: Request Doesn't Exist");
        // Check if the caller's permissions
        if (!roleStorage.hasRole(Roles.KEEPER, msg.sender)) {
            // Check the caller is the position owner
            require(msg.sender == request.user, "Router: Not Position Owner");
            // Check sufficient time has passed
            require(block.number >= request.requestBlock + tradeStorage.minBlockDelay(), "Router: Insufficient Delay");
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
        require(market != IMarket(address(0)), "ADL: Invalid market");
        // get current price
        uint256 indexPrice = Oracle.getReferencePrice(priceFeed, _indexToken);
        uint256 indexBaseUnit = Oracle.getBaseUnit(priceFeed, _indexToken);
        uint256 collateralPrice;
        uint256 collateralBaseUnit;
        if (_isLong) {
            (collateralPrice,) = Oracle.getLastMarketTokenPrices(priceFeed, true);
            collateralBaseUnit = Oracle.getLongBaseUnit(priceFeed);
        } else {
            (, collateralPrice) = Oracle.getLastMarketTokenPrices(priceFeed, true);
            collateralBaseUnit = Oracle.getShortBaseUnit(priceFeed);
        }
        // fetch pnl to pool ratio
        int256 pnlFactor = MarketUtils.getPnlFactor(
            market, _indexToken, collateralPrice, collateralBaseUnit, indexPrice, indexBaseUnit, _isLong
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
        Order.ExecuteCache memory cache;
        IMarket.AdlConfig memory adl = market.getAdlConfig(_indexToken);
        // Check ADL is enabled for the market and for the side
        if (_isLong) {
            require(adl.flaggedLong, "ADL: Long side not flagged");
        } else {
            require(adl.flaggedShort, "ADL: Short side not flagged");
        }
        // Check the position in question is active
        Position.Data memory position = tradeStorage.getPosition(_positionKey);
        require(position.positionSize > 0, "ADL: Position not active");
        // cache the market
        cache.market = market;
        // fetch prices, base units, calculate sizeDeltaUsd, no fee / discount, no ref, no impact
        priceFeed.signPriceData{value: msg.value}(position.indexToken, _priceData);
        // Get current pricing and token data
        cache =
            Order.retrieveTokenPrices(priceFeed, cache, position.indexToken, block.number, position.isLong, false, true);
        // Get size delta usd
        cache.sizeDeltaUsd = -int256(mulDiv(_sizeDelta, cache.indexPrice, cache.indexBaseUnit));
        // Get starting PNL Factor
        int256 startingPnlFactor = MarketUtils.getPnlFactor(
            market,
            _indexToken,
            cache.collateralPrice,
            cache.collateralBaseUnit,
            cache.indexPrice,
            cache.indexBaseUnit,
            _isLong
        );
        // Construct an ADL Order
        Position.Execution memory request = Position.createAdlOrder(position, _sizeDelta);
        // Execute the order
        tradeStorage.decreaseExistingPosition(request, cache);
        // Get the new PNL to pool ratio
        int256 newPnlFactor = MarketUtils.getPnlFactor(
            market,
            _indexToken,
            cache.collateralPrice,
            cache.collateralBaseUnit,
            cache.indexPrice,
            cache.indexBaseUnit,
            _isLong
        );
        // PNL to pool has reduced
        require(newPnlFactor < startingPnlFactor, "ADL: PNL Factor not reduced");
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
        require(_price > 0, "Processor: Invalid Price");
        require(priceFeed.getPrice(_token, _block).price == 0, "Processor: Price Already Updated");
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
        Order.ExecuteCache memory _cache,
        Position.Request memory _request,
        uint256 _fee,
        uint256 _feeDiscount,
        bool _isLong
    ) internal {
        console.log("Fee: ", _fee);
        console.log("Fee Discount: ", _feeDiscount);
        // Increment market Fee Balance
        _cache.market.accumulateFees(_fee, _isLong);
        // Transfer Fee to market
        IERC20(_request.input.collateralToken).safeTransfer(address(_cache.market), _fee);
        // Transfer Fee Discount to Referral Storage
        uint256 feeRebate;
        if (_feeDiscount > 0) {
            feeRebate = _feeDiscount / 2; // 50% discount to user, 50% rebate to referrer
            // Increment Referral Storage Fee Balance
            referralStorage.accumulateAffiliateRewards(_cache.referrer, _isLong, feeRebate);
            // Transfer Fee Discount to Referral Storage
            IERC20(_request.input.collateralToken).safeTransfer(address(referralStorage), feeRebate);
        }

        // Transfer Collateral to market
        uint256 afterFeeAmount = _request.input.collateralDelta - (_fee + feeRebate);
        _cache.market.increasePoolBalance(afterFeeAmount, _isLong);
        IERC20(_request.input.collateralToken).safeTransfer(address(_cache.market), afterFeeAmount);
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
        Order.ExecuteCache memory _cache,
        address _indexToken,
        uint256 _sizeDelta,
        bool _isLong,
        bool _isIncrease
    ) internal {
        if (_sizeDelta != 0) {
            // Use Impacted Price for Entry
            int256 signedSizeDelta = _isIncrease ? _sizeDelta.toInt256() : -_sizeDelta.toInt256();
            _cache.market.updateAverageEntryPrice(_indexToken, _cache.impactedPrice, signedSizeDelta, _isLong);
            // Average Entry Price relies on OI, so it must be updated before this
            _cache.market.updateOpenInterest(_indexToken, _sizeDelta, _isLong, _isIncrease);
        }
        _cache.market.updateFundingRate(_indexToken, _cache.indexPrice, _cache.indexBaseUnit);
        _cache.market.updateBorrowingRate(
            _indexToken,
            _cache.indexPrice,
            _cache.indexBaseUnit,
            _cache.longMarketTokenPrice,
            Oracle.getLongBaseUnit(priceFeed),
            _cache.shortMarketTokenPrice,
            Oracle.getShortBaseUnit(priceFeed),
            _isLong
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
            require(_indexPrice > 0, "Processor: Invalid Index Price");
            // fee accounted for in gas costs
            priceFeed.setAssetPrice(_indexToken, _indexPrice, block.number);
        }
    }
}
