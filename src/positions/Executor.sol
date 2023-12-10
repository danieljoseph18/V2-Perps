// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {IMarketStorage} from "../markets/interfaces/IMarketStorage.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {ITradeStorage} from "./interfaces/ITradeStorage.sol";
import {MarketStructs} from "../markets/MarketStructs.sol";
import {IPriceOracle} from "../oracle/interfaces/IPriceOracle.sol";
import {IDataOracle} from "../oracle/interfaces/IDataOracle.sol";
import {ILiquidityVault} from "../markets/interfaces/ILiquidityVault.sol";
import {RoleValidation} from "../access/RoleValidation.sol";
import {TradeHelper} from "./TradeHelper.sol";
import {ImpactCalculator} from "./ImpactCalculator.sol";
import {MarketHelper} from "../markets/MarketHelper.sol";
import {ReentrancyGuard} from "@solmate/utils/ReentrancyGuard.sol";

/// @dev Needs Executor Role
contract Executor is RoleValidation, ReentrancyGuard {
    error Executor_LimitNotHit();

    IMarketStorage public marketStorage;
    ITradeStorage public tradeStorage;
    ILiquidityVault public liquidityVault;
    IPriceOracle public priceOracle;
    IDataOracle public dataOracle;

    error Executor_InvalidRequestKey();
    error Executor_InvalidDecrease();

    constructor(
        address _marketStorage,
        address _tradeStorage,
        address _priceOracle,
        address _liquidityVault,
        address _dataOracle,
        address _roleStorage
    ) RoleValidation(_roleStorage) {
        marketStorage = IMarketStorage(_marketStorage);
        tradeStorage = ITradeStorage(_tradeStorage);
        priceOracle = IPriceOracle(_priceOracle);
        liquidityVault = ILiquidityVault(_liquidityVault);
        dataOracle = IDataOracle(_dataOracle);
    }

    function executeTradeOrders(address _feeReceiver) external onlyKeeper {
        bytes32[] memory marketOrders = tradeStorage.getPendingMarketOrders();
        uint256 len = marketOrders.length;
        for (uint256 i = 0; i < len; ++i) {
            bytes32 _key = marketOrders[i];
            try this.executeTradeOrder(_key, _feeReceiver, false) {}
            catch {
                try tradeStorage.cancelOrderRequest(_feeReceiver, _key, false) returns (bool _wasCancelled) {
                    if (!_wasCancelled) break;
                } catch {}
            }
        }
        tradeStorage.updateOrderStartIndex();
    }

    /// @dev Only Keeper
    function executeTradeOrder(bytes32 _key, address _feeReceiver, bool _isLimit)
        public
        nonReentrant
        onlyKeeperOrContract
    {
        _executeTradeOrder(_key, _feeReceiver, _isLimit);
    }

    function _executeTradeOrder(bytes32 _key, address _feeReceiver, bool _isLimit) internal returns (bool) {
        MarketStructs.PositionRequest memory positionRequest = tradeStorage.orders(_isLimit, _key);
        if (positionRequest.user == address(0)) {
            return true;
        }

        address market = _getMarketFromIndexToken(positionRequest.indexToken);
        uint256 signedBlockPrice = priceOracle.getSignedPrice(market, positionRequest.requestBlock);
        if (signedBlockPrice == 0) {
            tradeStorage.cancelOrderRequest(_feeReceiver, _key, _isLimit);
            return false;
        }

        if (_isLimit && !_isValidLimitOrder(signedBlockPrice, positionRequest)) {
            tradeStorage.cancelOrderRequest(_feeReceiver, _key, _isLimit);
            return false;
        }

        uint256 price = ImpactCalculator.executePriceImpact(
            _getMarketFromIndexToken(positionRequest.indexToken),
            address(marketStorage),
            address(dataOracle),
            address(priceOracle),
            positionRequest,
            signedBlockPrice
        );

        int256 sizeDeltaUsd = _calculateSizeDeltaUsd(positionRequest, signedBlockPrice);

        if (!_isValidPositionRequest(positionRequest, _key)) {
            revert Executor_InvalidDecrease();
        }

        tradeStorage.executeTrade(MarketStructs.ExecutionParams(positionRequest, price, _feeReceiver));
        _updateMarketState(market, positionRequest, price, sizeDeltaUsd);

        return true;
    }

    // Additional helper functions used in _executeTradeOrder
    function _getMarketFromIndexToken(address indexToken) internal view returns (address) {
        return MarketHelper.getMarketFromIndexToken(address(marketStorage), indexToken).market;
    }

    function _isValidLimitOrder(uint256 signedBlockPrice, MarketStructs.PositionRequest memory positionRequest)
        internal
        pure
        returns (bool)
    {
        try TradeHelper.checkLimitPrice(signedBlockPrice, positionRequest) {
            return true;
        } catch {
            return false;
        }
    }

    function _calculateSizeDeltaUsd(MarketStructs.PositionRequest memory positionRequest, uint256 signedBlockPrice)
        internal
        view
        returns (int256)
    {
        uint256 sizeDeltaUsd = TradeHelper.getTradeSizeUsd(
            address(dataOracle), positionRequest.indexToken, positionRequest.sizeDelta, signedBlockPrice
        );
        return positionRequest.isIncrease ? int256(sizeDeltaUsd) : -int256(sizeDeltaUsd);
    }

    function _isValidPositionRequest(MarketStructs.PositionRequest memory positionRequest, bytes32 key)
        internal
        view
        returns (bool)
    {
        if (!positionRequest.isIncrease) {
            return tradeStorage.openPositions(key).positionSize >= positionRequest.sizeDelta;
        }
        return true;
    }

    function _updateMarketState(
        address market,
        MarketStructs.PositionRequest memory positionRequest,
        uint256 price,
        int256 sizeDeltaUsd
    ) internal {
        bytes32 marketKey = IMarket(market).getMarketKey();
        IMarketStorage(marketStorage).updateOpenInterest(
            marketKey,
            positionRequest.collateralDelta,
            positionRequest.sizeDelta,
            positionRequest.isLong,
            positionRequest.isIncrease
        );
        IMarket(market).updateFundingRate();
        IMarket(market).updateBorrowingRate(positionRequest.isLong);
        if (sizeDeltaUsd > 0) {
            IMarket(market).updateTotalWAEP(price, sizeDeltaUsd, positionRequest.isLong);
        }
    }
}
