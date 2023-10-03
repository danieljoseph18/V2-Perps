// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {IMarketStorage} from "../markets/interfaces/IMarketStorage.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {ITradeStorage} from "./interfaces/ITradeStorage.sol";
import {MarketStructs} from "../markets/MarketStructs.sol";
import {IPriceOracle} from "../oracle/interfaces/IPriceOracle.sol";

contract Executor {
    // contract for executing trades
    // will be called by the TradeManager
    // will execute trades on the market contract
    // will execute trades on the funding contract
    // will execute trades on the liquidator contract

    address public marketStorage;
    address public tradeStorage;
    address public priceOracle;

    constructor(address _marketStorage, address _tradeStorage, address _priceOracle) {
        marketStorage = _marketStorage;
        tradeStorage = _tradeStorage;
        priceOracle = _priceOracle;
    }

    ////////////////////
    // STATE UPDATERS //
    ////////////////////

    // when executing a trade, store it in MarketStorage
    // update the open interest in MarketStorage
    // if decrease, subtract size delta from open interest
    function _updateOpenInterest(bytes32 _marketKey,uint256 _collateralDelta, uint256 _sizeDelta, bool _isLong, bool _isDecrease) internal {
        bool shouldAdd = (_isLong && !_isDecrease) || (!_isLong && _isDecrease);
        IMarketStorage(marketStorage).updateOpenInterest(_marketKey, _collateralDelta, _sizeDelta, _isLong, shouldAdd);
    }

    // in every action that interacts with Market, call _updateFundingRate();
    function _updateFundingRate(bytes32 _marketKey) internal {
        address _market = IMarketStorage(marketStorage).getMarket(_marketKey).market;
        IMarket(_market).updateFundingRate();
    }

    //////////////////////////
    // EXECUTION FUNCTIONS //
    ////////////////////////

    // only permissioned roles can call
    // called on set intervals, e.g every 5 - 10 seconds => crucial to prevent a backlog from building up
    // if too much backlog builds up, may be too expensive to loop through entire request array
    function executeMarketOrders() external {
        // cache the order queue
        (bytes32[] memory orders, ) = ITradeStorage(tradeStorage).getMarketOrderKeys();
        uint256 len = orders.length;
        // loop through => get Position => fulfill position at signed block price
        for(uint256 i = 0; i < len; ++i) {
            bytes32 _key = orders[i];
            executeMarketOrder(_key);
        }
    }

    function executeMarketOrder(bytes32 _key) public {
        // get the position
        MarketStructs.PositionRequest memory _positionRequest = ITradeStorage(tradeStorage).marketOrderRequests(_key);

        // get the market and block to get the signed block price
        address _market = IMarketStorage(marketStorage).getMarketFromIndexToken(_positionRequest.indexToken, _positionRequest.collateralToken).market;
        uint256 _block = _positionRequest.requestBlock;
        uint256 _signedBlockPrice = IPriceOracle(priceOracle).getSignedPrice(_market, _block);

        // execute the trade
        MarketStructs.Position memory _position = ITradeStorage(tradeStorage).executeTrade(_positionRequest, _signedBlockPrice);
        // update open interest
        // always increase => should add is equal to isLong
        _updateOpenInterest(_position.market, _positionRequest.collateralDelta, _positionRequest.sizeDelta, _positionRequest.isLong, _positionRequest.isLong);
        // update funding rate
        _updateFundingRate(_position.market);
    }

    // no loop execution for limits => 1 by 1, track price on subgraph
    function executeLimitOrder(bytes32 _key) external {
        // get the position
        MarketStructs.PositionRequest memory _positionRequest = ITradeStorage(tradeStorage).limitOrderRequests(_key);
        // get the current price
        uint256 price = IPriceOracle(priceOracle).getPrice(_positionRequest.indexToken);
        // if current price >= acceptable price and isShort, execute
        // if current price <= acceptable price and isLong, execute
        if((_positionRequest.isLong && price <= _positionRequest.acceptablePrice) || (!_positionRequest.isLong && price >= _positionRequest.acceptablePrice)) {
            // execute the trade
            MarketStructs.Position memory _position = ITradeStorage(tradeStorage).executeTrade(_positionRequest, price);
            // update open interest
            // always increase => should add is equal to isLong
            _updateOpenInterest(_position.market, _positionRequest.collateralDelta, _positionRequest.sizeDelta, _positionRequest.isLong, _positionRequest.isLong);
            // update funding rate
            _updateFundingRate(_position.market);
        } else {
            // revert
        }

    }

    function executeDecreaseOrders() external {
        // cache the order queue
        (,bytes32[] memory orders) = ITradeStorage(tradeStorage).getMarketOrderKeys();
        uint256 len = orders.length;
        // loop through => get Position => fulfill position at signed block price
        for(uint256 i = 0; i < len; ++i) {
            bytes32 _key = orders[i];
            executeMarketDecrease(_key);
        }
    }

    function executeMarketDecrease(bytes32 _key) public {
        // get the request
        MarketStructs.DecreasePositionRequest memory _decreaseRequest = ITradeStorage(tradeStorage).marketDecreaseRequests(_key);
        // get the market and block to get the signed block price
        address _market = IMarketStorage(marketStorage).getMarketFromIndexToken(_decreaseRequest.indexToken, _decreaseRequest.collateralToken).market;
        uint256 _block = _decreaseRequest.requestBlock;
        uint256 _signedBlockPrice = IPriceOracle(priceOracle).getSignedPrice(_market, _block);
        // execute the trade
        MarketStructs.Position memory _position = ITradeStorage(tradeStorage).executeDecreaseRequest(_decreaseRequest, _signedBlockPrice);
        // always decrease, so should add is opposite of isLong
        _updateOpenInterest(_position.market, _decreaseRequest.collateralDelta, _decreaseRequest.sizeDelta, _decreaseRequest.isLong, !_decreaseRequest.isLong);
        _updateFundingRate(_position.market);
    }

    // used as a stop loss => how do we get trailing stop losses
    // limit decrease should be set as a percentage of the current price ?? how does a trailing stop loss work?
    function executeLimitDecrease(bytes32 _key) external {
        // get the request
        MarketStructs.DecreasePositionRequest memory _decreaseRequest = ITradeStorage(tradeStorage).limitDecreaseRequests(_key);
        // get the current price
        uint256 price = IPriceOracle(priceOracle).getPrice(_decreaseRequest.indexToken);
        // if current price >= acceptable price and isShort, execute
        // if current price <= acceptable price and isLong, execute
        if((_decreaseRequest.isLong && price <= _decreaseRequest.acceptablePrice) || (!_decreaseRequest.isLong && price >= _decreaseRequest.acceptablePrice)) {
            // execute the trade
            MarketStructs.Position memory _position = ITradeStorage(tradeStorage).executeDecreaseRequest(_decreaseRequest, price);
            // always decrease, so should add is opposite of isLong
            _updateOpenInterest(_position.market, _decreaseRequest.collateralDelta, _decreaseRequest.sizeDelta, _decreaseRequest.isLong, !_decreaseRequest.isLong);
            _updateFundingRate(_position.market);
        } else {
            // revert
        }
    }

}