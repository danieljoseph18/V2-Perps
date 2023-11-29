// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {IMarketStorage} from "../markets/interfaces/IMarketStorage.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {ITradeStorage} from "./interfaces/ITradeStorage.sol";
import {MarketStructs} from "../markets/MarketStructs.sol";
import {IPriceOracle} from "../oracle/interfaces/IPriceOracle.sol";
import {ILiquidityVault} from "../markets/interfaces/ILiquidityVault.sol";
import {RoleValidation} from "../access/RoleValidation.sol";
import {TradeHelper} from "./TradeHelper.sol";
import {ImpactCalculator} from "./ImpactCalculator.sol";

/// @dev Needs Executor Role
contract Executor is RoleValidation {
    error Executor_LimitNotHit();

    IMarketStorage public marketStorage;
    ITradeStorage public tradeStorage;
    ILiquidityVault public liquidityVault;
    IPriceOracle public priceOracle;

    error Executor_InvalidRequestKey();
    error Executor_CantDecreaseNonExistingPosition();

    constructor(
        address _marketStorage,
        address _tradeStorage,
        address _priceOracle,
        address _liquidityVault,
        address _roleStorage
    ) RoleValidation(_roleStorage) {
        marketStorage = IMarketStorage(_marketStorage);
        tradeStorage = ITradeStorage(_tradeStorage);
        priceOracle = IPriceOracle(_priceOracle);
        liquidityVault = ILiquidityVault(_liquidityVault);
    }

    function executeTradeOrders() external onlyKeeper {
        (, bytes32[] memory marketOrders) = tradeStorage.getOrderKeys();
        uint256 len = marketOrders.length;
        for (uint256 i = 0; i < len; ++i) {
            bytes32 _key = marketOrders[i];
            try this.executeTradeOrder(_key, false) {} catch {}
        }
    }

    /// @dev Only Keeper
    function executeTradeOrder(bytes32 _key, bool _isLimit) public onlyKeeper {
        _executeTradeOrder(_key, msg.sender, _isLimit);
    }

    /// @dev needs work
    function _executeTradeOrder(bytes32 _key, address _executor, bool _isLimit) internal {
        // get the position
        MarketStructs.PositionRequest memory _positionRequest = tradeStorage.orders(_isLimit, _key);
        if (_positionRequest.user == address(0)) revert Executor_InvalidRequestKey();
        // get the market and block to get the signed block price
        address market = marketStorage.getMarketFromIndexToken(_positionRequest.indexToken).market;
        uint256 _block = _positionRequest.requestBlock;
        uint256 _signedBlockPrice = priceOracle.getSignedPrice(market, _block);
        if (_signedBlockPrice == 0) {
            //cancel order and return
            tradeStorage.cancelOrderRequest(_key, _isLimit);
            return;
        }
        if (_isLimit) {
            TradeHelper.checkLimitPrice(_signedBlockPrice, _positionRequest);
        }

        _positionRequest.priceImpact =
            ImpactCalculator.calculatePriceImpact(market, _positionRequest, _signedBlockPrice);

        uint256 price = ImpactCalculator.applyPriceImpact(_signedBlockPrice, _positionRequest.priceImpact);
        // check impacted price is acceptable within slippage
        // #################################################
        int256 sizeDeltaUsd = _positionRequest.isIncrease
            ? int256(_positionRequest.sizeDelta * price)
            : int256(_positionRequest.sizeDelta * price) * -1;
        // if decrease, check position exists and sizeDeltaUsd is less than the position's size
        if (!_positionRequest.isIncrease) {
            if (tradeStorage.openPositions(_key).positionSize < _positionRequest.sizeDelta) {
                revert Executor_CantDecreaseNonExistingPosition();
            }
        }
        // execute the trade
        MarketStructs.Position memory _position =
            tradeStorage.executeTrade(MarketStructs.ExecutionParams(_positionRequest, price, _executor));

        _updateOpenInterest(
            _position.market,
            _positionRequest.collateralDelta,
            _positionRequest.sizeDelta,
            _positionRequest.isLong,
            _positionRequest.isIncrease
        );
        _updateFundingRate(market, sizeDeltaUsd, _positionRequest.isLong);
        _updateBorrowingRate(market, _positionRequest.isLong);
        _updateTotalWAEP(market, price, sizeDeltaUsd, _positionRequest.isLong);
    }

    // when executing a trade, store it in MarketStorage
    // update the open interest in MarketStorage
    // if decrease, subtract size delta from open interest
    // Note Only updates the open interest values in storage
    function _updateOpenInterest(
        bytes32 _marketKey,
        uint256 _collateralDelta,
        uint256 _sizeDelta,
        bool _isLong,
        bool _isIncrease
    ) internal {
        IMarketStorage(marketStorage).updateOpenInterest(_marketKey, _collateralDelta, _sizeDelta, _isLong, _isIncrease);
    }

    // in every action that interacts with Market, call _updateFundingRate();
    function _updateFundingRate(address _market, int256 _sizeDeltaUsd, bool _isLong) internal {
        IMarket(_market).updateFundingRate(_sizeDeltaUsd, _isLong);
    }

    function _updateBorrowingRate(address _market, bool _isLong) internal {
        IMarket(_market).updateBorrowingRate(_isLong);
    }

    function _updateTotalWAEP(address _market, uint256 _pricePaid, int256 _sizeDeltaUsd, bool _isLong) internal {
        IMarket(_market).updateTotalWAEP(_pricePaid, _sizeDeltaUsd, _isLong);
    }
}
