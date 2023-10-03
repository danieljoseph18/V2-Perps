// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {MarketStructs} from "../markets/MarketStructs.sol";
import {ITradeStorage} from "./interfaces/ITradeStorage.sol";

contract RequestRouter {
    using MarketStructs for MarketStructs.PositionRequest;
    // contract for creating requests for trades
    // limit orders, market orders, all will have 2 step process
    // swap orders included
    // orders will be stored in storage
    // orders will be executed by the Executor, which will put them on TradeManager

    address public tradeStorage;

    constructor(address _tradeStorage) {
        tradeStorage = _tradeStorage;
    }

    /* 
    struct PositionRequest {
        uint256 requestIndex;
        address indexToken;
        address user;
        address stablecoin;
        uint256 collateralAmount;
        uint256 indexAmount;
        uint256 positionSize;
        uint256 requestBlock;
        bool isLong;
    }
    */

    // if _isLimit, it's a limit order, else it's a market order
    // every time a request is created, call to the price oracle and sign the block price
    // update the mapping with the price at the block of the request
    /// @dev front-end can pass default values for block and index
    function createTradeRequest(MarketStructs.PositionRequest memory _positionRequest, bool _isLimit) external {
        ITradeStorage target = ITradeStorage(tradeStorage);
        (uint256 marketLen, uint256 limitLen, , ,) = target.getRequestQueueLengths();
        uint256 index = _isLimit ? limitLen : marketLen;
        _positionRequest.requestIndex = index;
        _positionRequest.requestBlock = block.number;
        // validate the request meets all safety parameters
        // open the request on the trade storage contract
        _isLimit ? target.createLimitOrderRequest(_positionRequest) : target.createMarketOrderRequest(_positionRequest);

    }


    function createDecreaseRequest(MarketStructs.DecreasePositionRequest memory _decreaseRequest, bool _isLimit) external {
        // validate the request meets all safety parameters
        // open the request on the trade storage contract
        ITradeStorage target = ITradeStorage(tradeStorage);
        (,, , uint256 marketLen,uint256 limitLen) = target.getRequestQueueLengths();
        uint256 index = _isLimit ? limitLen : marketLen;
        _decreaseRequest.requestIndex = index;
        _decreaseRequest.requestBlock = block.number;
        // validate the request meets all safety parameters
        // open the request on the trade storage contract
        _isLimit ? target.createLimitDecreaseRequest(_decreaseRequest) : target.createMarketDecreaseRequest(_decreaseRequest);
    }

    function createCloseRequest(MarketStructs.PositionRequest memory _positionRequest) external {
        // validate the request meets all safety parameters
        // open the request on the trade storage contract
    }


    function cancelOrderRequest(bytes32 _key, bool _isLimit) external {
        // perform safety checks => it exists, it's their position etc.
        ITradeStorage(tradeStorage).cancelOrderRequest(_key, _isLimit);
    }

}