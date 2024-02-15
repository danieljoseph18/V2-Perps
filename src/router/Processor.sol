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
import {ILiquidityVault} from "../liquidity/interfaces/ILiquidityVault.sol";
import {IMarketMaker} from "../markets/interfaces/IMarketMaker.sol";
import {RoleValidation} from "../access/RoleValidation.sol";
import {PriceImpact} from "../libraries/PriceImpact.sol";
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

/// @dev Needs Processor Role
// All keeper interactions should come through this contract
contract Processor is IProcessor, RoleValidation, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using Address for address payable;

    ITradeStorage public tradeStorage;
    ILiquidityVault public liquidityVault;
    IMarketMaker public marketMaker;
    IReferralStorage public referralStorage;
    IPriceFeed public priceFeed;

    // Base Gas for a TX
    uint256 public baseGasLimit;
    // Upper Bounds to account for fluctuations
    uint256 public depositGasLimit;
    uint256 public withdrawalGasLimit;
    uint256 public positionGasLimit;

    error OrderProcessor_InvalidRequestType();

    event ExecuteTradeOrder(bytes32 indexed _orderKey, Position.Request _request, uint256 _fee, uint256 _feeDiscount);
    event GasLimitsUpdated(
        uint256 indexed depositGasLimit, uint256 indexed withdrawalGasLimit, uint256 indexed positionGasLimit
    );

    constructor(
        address _marketMaker,
        address _tradeStorage,
        address _liquidityVault,
        address _referralStorage,
        address _priceFeed,
        address _roleStorage
    ) RoleValidation(_roleStorage) {
        marketMaker = IMarketMaker(_marketMaker);
        tradeStorage = ITradeStorage(_tradeStorage);
        liquidityVault = ILiquidityVault(_liquidityVault);
        referralStorage = IReferralStorage(_referralStorage);
        priceFeed = IPriceFeed(_priceFeed);
    }

    function updateGasLimits(uint256 _deposit, uint256 _withdrawal, uint256 _position) external onlyAdmin {
        depositGasLimit = _deposit;
        withdrawalGasLimit = _withdrawal;
        positionGasLimit = _position;
        emit GasLimitsUpdated(_deposit, _withdrawal, _position);
    }

    /////////////////////////
    // MARKET INTERACTIONS //
    /////////////////////////

    // @audit - keeper needs to pass in cumulative net pnl
    // Must make sure this value is valid. Get by looping through all current active markets
    // and summing their PNLs
    function executeDeposit(bytes32 _key, int256 _cumulativePnl) external nonReentrant onlyKeeper {
        uint256 initialGas = gasleft();
        require(_key != bytes32(0), "E: Invalid Key");
        // Fetch the request
        Deposit.ExecuteParams memory params;
        params.data = liquidityVault.getDepositRequest(_key);
        params.key = _key;
        params.cumulativePnl = _cumulativePnl;
        try liquidityVault.executeDeposit(params) {}
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
    function executeWithdrawal(bytes32 _key, int256 _cumulativePnl) external nonReentrant onlyKeeper {
        uint256 initialGas = gasleft();
        require(_key != bytes32(0), "E: Invalid Key");
        // Fetch the request
        Withdrawal.ExecuteParams memory params;
        params.data = liquidityVault.getWithdrawalRequest(_key);
        params.key = _key;
        params.cumulativePnl = _cumulativePnl;
        try liquidityVault.executeWithdrawal(params) {}
        catch {
            revert("Processor: Execute Withdrawal Failed");
        }
        // Send Execution Fee + Rebate
        Gas.payExecutionFee(
            this, params.data.input.executionFee, initialGas, payable(params.data.input.owner), payable(msg.sender)
        );
    }

    // Used to transfer intermediary tokens to the vault from deposits
    function transferDepositTokens(address _token, uint256 _amount) external onlyVault {
        IERC20(_token).safeTransfer(address(liquidityVault), _amount);
    }

    /////////////
    // TRADING //
    /////////////

    function executeTradeOrders(address _feeReceiver, Oracle.TradingEnabled memory _isTradingEnabled)
        external
        onlyKeeper
    {
        bytes32[] memory marketOrders = tradeStorage.getOrderKeys(false);
        uint32 len = uint32(marketOrders.length);
        for (uint256 i = 0; i < len;) {
            bytes32 _key = marketOrders[i];
            try this.executeTradeOrder(_key, _feeReceiver, false, _isTradingEnabled) {}
            catch {
                try tradeStorage.cancelOrderRequest(_key, false) {} catch {}
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Only Keeper
    // @audit - Need a step to validate the trade doesn't put the market over its
    // allocation (_validateAllocation)
    /// @param _isTradingEnabled: Flag for disabling trading of asset types outside of trading hours
    function executeTradeOrder(
        bytes32 _orderKey,
        address _feeReceiver,
        bool _isLimitOrder,
        Oracle.TradingEnabled memory _isTradingEnabled
    ) external nonReentrant onlyKeeperOrSelf {
        uint256 initialGas = gasleft();
        Order.ExecuteCache memory cache;
        // Fetch and validate request from key
        Position.Request memory request = tradeStorage.getOrder(_orderKey);
        require(request.user != address(0), "E: Request Key");
        require(_feeReceiver != address(0), "E: Fee Receiver");
        // Get the asset and validate trading is enabled
        Oracle.validateTradingHours(priceFeed, request.input.indexToken, _isTradingEnabled);
        // Fetch and validate price
        cache.indexPrice = request.input.isLong
            ? Oracle.getMaxPrice(priceFeed, request.input.indexToken, request.requestBlock)
            : Oracle.getMinPrice(priceFeed, request.input.indexToken, request.requestBlock);
        require(cache.indexPrice != 0, "E: Invalid Price");
        if (_isLimitOrder) Position.checkLimitPrice(cache.indexPrice, request.input);

        // Execute Price Impact
        cache.market = IMarket(marketMaker.tokenToMarkets(request.input.indexToken));
        cache.indexBaseUnit = Oracle.getBaseUnit(priceFeed, request.input.indexToken);
        cache.impactedPrice = PriceImpact.execute(cache.market, request, cache.indexPrice, cache.indexBaseUnit);

        (cache.longMarketTokenPrice, cache.shortMarketTokenPrice) = request.input.isLong
            ? Oracle.getMarketTokenPrices(priceFeed, request.requestBlock, true)
            : Oracle.getMarketTokenPrices(priceFeed, request.requestBlock, false);

        // Update Market State
        cache.sizeDeltaUsd = _calculateSizeDeltaUsd(
            request.input.sizeDelta, cache.indexPrice, cache.indexBaseUnit, request.input.isIncrease
        );
        _updateMarketState(
            cache.market,
            request.input.sizeDelta,
            cache.impactedPrice,
            cache.indexPrice,
            cache.longMarketTokenPrice,
            cache.shortMarketTokenPrice,
            cache.sizeDeltaUsd,
            request.input.isLong,
            request.input.isIncrease
        );

        cache.collateralPrice = request.input.isLong ? cache.longMarketTokenPrice : cache.shortMarketTokenPrice;

        // Calculate Fee
        cache.fee = Fee.calculateForPosition(
            tradeStorage, request.input.sizeDelta, cache.indexPrice, cache.indexBaseUnit, cache.collateralPrice
        );
        // Calculate Fee Discount for Referral Code
        (cache.feeDiscount, cache.referrer) = Referral.calculateFeeDiscount(referralStorage, request.user, cache.fee);

        // Execute Trade
        if (request.requestType == Position.RequestType.CREATE_POSITION) {
            tradeStorage.createNewPosition(
                Position.Execution(request, cache.impactedPrice, cache.collateralPrice, _feeReceiver, false), cache
            );
        } else if (request.requestType == Position.RequestType.POSITION_DECREASE) {
            tradeStorage.decreaseExistingPosition(
                Position.Execution(request, cache.impactedPrice, cache.collateralPrice, _feeReceiver, false), cache
            );
        } else if (request.requestType == Position.RequestType.POSITION_INCREASE) {
            tradeStorage.increaseExistingPosition(
                Position.Execution(request, cache.impactedPrice, cache.collateralPrice, _feeReceiver, false), cache
            );
        } else if (request.requestType == Position.RequestType.COLLATERAL_DECREASE) {
            tradeStorage.executeCollateralDecrease(
                Position.Execution(request, cache.impactedPrice, cache.collateralPrice, _feeReceiver, false), cache
            );
        } else if (request.requestType == Position.RequestType.COLLATERAL_INCREASE) {
            tradeStorage.executeCollateralIncrease(
                Position.Execution(request, cache.impactedPrice, cache.collateralPrice, _feeReceiver, false), cache
            );
        } else if (request.requestType == Position.RequestType.TAKE_PROFIT) {
            tradeStorage.decreaseExistingPosition(
                Position.Execution(request, cache.impactedPrice, cache.collateralPrice, _feeReceiver, false), cache
            );
        } else if (request.requestType == Position.RequestType.STOP_LOSS) {
            tradeStorage.decreaseExistingPosition(
                Position.Execution(request, cache.impactedPrice, cache.collateralPrice, _feeReceiver, false), cache
            );
        } else {
            revert OrderProcessor_InvalidRequestType();
        }

        /* Handle Token Transfers */
        _handleTokenTransfers(cache, request, cache.fee, cache.feeDiscount, request.input.isLong);

        // Emit Trade Executed Event
        emit ExecuteTradeOrder(_orderKey, request, cache.fee, cache.feeDiscount);

        // Send Execution Fee + Rebate
        Gas.payExecutionFee(this, request.input.executionFee, initialGas, payable(_feeReceiver), payable(msg.sender));
    }

    // need to store who flagged and liquidated
    // let the liquidator claim liquidation rewards from the tradestorage contract
    // Need to update prices for Index Token, Long Token, Short Token
    function liquidatePosition(bytes32 _positionKey, bytes[] memory _priceData, uint256 _priceUpdateFee)
        external
        payable
        onlyKeeper
    {
        // need to construct ExecuteCache
        Order.ExecuteCache memory cache;
        // fetch position
        Position.Data memory position = tradeStorage.getPosition(_positionKey);
        cache.market = position.market;

        // fetch prices, base units, calculate sizeDeltaUsd, no fee / discount, no ref, no impact
        priceFeed.signPriceData{value: _priceUpdateFee}(position.indexToken, _priceData);

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
        cache.sizeDeltaUsd = _calculateSizeDeltaUsd(position.positionSize, cache.indexPrice, cache.indexBaseUnit, false);

        // call _updateMarketState
        _updateMarketState(
            cache.market,
            position.positionSize,
            cache.impactedPrice,
            cache.indexPrice,
            cache.longMarketTokenPrice,
            cache.shortMarketTokenPrice,
            cache.sizeDeltaUsd,
            position.isLong,
            false
        );
        // liquidate the position
        try tradeStorage.liquidatePosition(cache, _positionKey, msg.sender) {}
        catch {
            revert("Processor: Liquidation Failed");
        }
    }

    // @audit - is this vulnerable?
    function sendExecutionFee(address payable _to, uint256 _amount) external onlyProcessor {
        _to.sendValue(_amount);
    }

    ///////////////////////////////
    // INTERNAL HELPER FUNCTIONS //
    ///////////////////////////////

    // @audit - Streamline / Improve
    function _handleTokenTransfers(
        Order.ExecuteCache memory _cache,
        Position.Request memory _request,
        uint256 _fee,
        uint256 _feeDiscount,
        bool _isLong
    ) internal {
        // Increment Liquidity Vault Fee Balance
        liquidityVault.accumulateFees(_fee, _isLong);
        // Transfer Fee to Liquidity Vault
        IERC20(_request.input.collateralToken).safeTransfer(address(liquidityVault), _fee);
        // Transfer Fee Discount to Referral Storage
        if (_feeDiscount > 0) {
            // Increment Referral Storage Fee Balance
            referralStorage.accumulateAffiliateRewards(_cache.referrer, _isLong, _feeDiscount);
            // Transfer Fee Discount to Referral Storage
            IERC20(_request.input.collateralToken).safeTransfer(address(referralStorage), _feeDiscount);
        }
        // Update Liquidity Vault Balance to Store the Collateral transferred in
        // @here

        // Transfer Collateral to LiquidityVault
        IERC20(_request.input.collateralToken).safeTransfer(address(liquidityVault), _request.input.collateralDelta);
    }

    function _calculateSizeDeltaUsd(
        uint256 _sizeDelta,
        uint256 _signedIndexPrice,
        uint256 _indexBaseUnit,
        bool _isIncrease
    ) internal pure returns (int256 sizeDeltaUsd) {
        // Flip sign if decreasing position
        uint256 valueUsd = Position.getTradeValueUsd(_sizeDelta, _signedIndexPrice, _indexBaseUnit);
        if (_isIncrease) {
            sizeDeltaUsd = valueUsd.toInt256();
        } else {
            sizeDeltaUsd = -1 * valueUsd.toInt256();
        }
    }

    function _updateMarketState(
        IMarket market,
        uint256 _sizeDelta,
        uint256 _impactedIndexPrice,
        uint256 _signedIndexPrice,
        uint256 _longTokenPrice,
        uint256 _shortTokenPrice,
        int256 _sizeDeltaUsd,
        bool _isLong,
        bool _isIncrease
    ) internal {
        market.updateOpenInterest(_sizeDelta, _isLong, _isIncrease);
        market.updateFundingRate();
        market.updateBorrowingRate(_signedIndexPrice, _longTokenPrice, _shortTokenPrice, _isLong);
        if (_sizeDeltaUsd != 0) {
            market.updateTotalWAEP(_impactedIndexPrice, _sizeDeltaUsd, _isLong);
        }
    }
}
