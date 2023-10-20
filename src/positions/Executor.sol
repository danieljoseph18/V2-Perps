// SPDX-License-Identifier: MIT
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
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @dev Needs Executor Role
contract Executor is RoleValidation {
    using SafeCast for uint256;

    error Executor_LimitNotHit();

    IMarketStorage public marketStorage;
    ITradeStorage public tradeStorage;
    ILiquidityVault public liquidityVault;
    address public priceOracle;

    error Executor_InvalidRequestKey();

    constructor(
        IMarketStorage _marketStorage,
        ITradeStorage _tradeStorage,
        address _priceOracle,
        ILiquidityVault _liquidityVault
    ) RoleValidation(roleStorage) {
        marketStorage = _marketStorage;
        tradeStorage = _tradeStorage;
        priceOracle = _priceOracle;
        liquidityVault = _liquidityVault;
    }

    //////////////////////////
    // EXECUTION FUNCTIONS //
    ////////////////////////

    // only permissioned roles can call
    // called on set intervals, e.g every 5 - 10 seconds => crucial to prevent a backlog from building up
    // if too much backlog builds up, may be too expensive to loop through entire request array
    function executeTradeOrders() external onlyKeeper {
        // cache the order queue
        (, bytes32[] memory marketOrders) = tradeStorage.getOrderKeys();
        uint256 len = marketOrders.length;
        // loop through => get Position => fulfill position at signed block price
        for (uint256 i = 0; i < len; ++i) {
            bytes32 _key = marketOrders[i];
            _executeTradeOrder(_key, msg.sender, false);
        }
    }

    /// @dev Only Keeper
    function executeTradeOrder(bytes32 _key, bool _isLimit) public onlyKeeper {
        _executeTradeOrder(_key, msg.sender, _isLimit);
    }

    // make facilitate increase and decrease
    /**
     * Note: Should handle transfer of the execution fee in this contract in the same transaction.
     *     If the position creation is succesful (i.e doesn't revert or returns true) then transfer the
     *     execution fee to the executor at the end of the function
     */
    function _executeTradeOrder(bytes32 _key, address _executor, bool _isLimit) internal {
        // get the position
        MarketStructs.PositionRequest memory _positionRequest = tradeStorage.orders(_isLimit, _key);
        if (_positionRequest.user == address(0)) revert Executor_InvalidRequestKey();
        // get the market and block to get the signed block price
        address market = IMarketStorage(marketStorage).getMarketFromIndexToken(
            _positionRequest.indexToken, _positionRequest.collateralToken
        ).market;
        uint256 _block = _positionRequest.requestBlock;
        uint256 _signedBlockPrice = IPriceOracle(priceOracle).getSignedPrice(market, _block);
        _positionRequest.priceImpact =
            ImpactCalculator.calculatePriceImpact(market, _positionRequest, _signedBlockPrice);

        if (_isLimit) {
            TradeHelper.checkLimitPrice(_signedBlockPrice, _positionRequest);
        }
        uint256 price = ImpactCalculator.applyPriceImpact(_signedBlockPrice, _positionRequest.priceImpact);
        int256 sizeDeltaUsd = _positionRequest.isIncrease
            ? (_positionRequest.sizeDelta * price).toInt256()
            : (_positionRequest.sizeDelta * price).toInt256() * -1;
        // execute the trade
        MarketStructs.Position memory _position =
            tradeStorage.executeTrade(MarketStructs.ExecutionParams(_positionRequest, price, _executor));
        // update open interest
        // always increase => should add is equal to isLong
        _updateOpenInterest(
            _position.market,
            _positionRequest.collateralDelta,
            _positionRequest.sizeDelta,
            _positionRequest.isLong,
            _positionRequest.isIncrease
        );
        _updateFundingRate(_positionRequest, price, _position.market);
        _updateBorrowingRate(_position.market, _positionRequest.isLong);
        _updateTotalWAEP(_position.market, price, sizeDeltaUsd, _positionRequest.isLong);
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
    function _updateFundingRate(
        MarketStructs.PositionRequest memory _positionRequest,
        uint256 _signedPrice,
        bytes32 _marketKey
    ) internal {
        address market = IMarketStorage(marketStorage).getMarket(_marketKey).market;
        uint256 tradeSizeUsd = TradeHelper.getTradeSizeUsd(_positionRequest.sizeDelta, _signedPrice);
        IMarket(market).updateFundingRate(tradeSizeUsd, _positionRequest.isLong);
    }

    function _updateBorrowingRate(bytes32 _marketKey, bool _isLong) internal {
        address market = IMarketStorage(marketStorage).getMarket(_marketKey).market;
        IMarket(market).updateBorrowingRate(_isLong);
    }

    function _updateTotalWAEP(bytes32 _marketKey, uint256 _pricePaid, int256 _sizeDeltaUsd, bool _isLong) internal {
        address market = IMarketStorage(marketStorage).getMarket(_marketKey).market;
        IMarket(market).updateTotalWAEP(_pricePaid, _sizeDeltaUsd, _isLong);
    }
}
