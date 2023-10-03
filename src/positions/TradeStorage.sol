// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {MarketStructs} from "../markets/MarketStructs.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {IMarketStorage} from "../markets/interfaces/IMarketStorage.sol";

contract TradeStorage {
    using MarketStructs for MarketStructs.Position;
    using MarketStructs for MarketStructs.PositionRequest;
    using MarketStructs for MarketStructs.DecreasePositionRequest;
    // positions need info like market address, entry price, entry time etc.
    // funding should be snapshotted on position open to calc funding fee
    // blocks should be used to settle trades at the price at that block
    // this prevents MEV by capitalizing on large price moves

    // stores all data for open trades and positions
    // needs to store all historic data for leaderboard and trade history
    // store requests for trades and liquidations
    // store open trades and liquidations
    // store closed trades and liquidations
    // all 3 stores separately for separate data extraction

    // need a queue structure for trade order requests
    // executors loop through the queue at set intervals and execute trade orders
    mapping(bytes32 => MarketStructs.PositionRequest) public marketOrderRequests;
    bytes32[] public marketOrderKeys;
    mapping(bytes32 => MarketStructs.PositionRequest) public limitOrderRequests;
    bytes32[] public limitOrderKeys;
    mapping(bytes32 => MarketStructs.PositionRequest) public swapOrderRequests;
    bytes32[] public swapOrderKeys;

    mapping(bytes32 => MarketStructs.DecreasePositionRequest) public marketDecreaseRequests;
    bytes32[] public marketDecreaseKeys;
    mapping(bytes32 => MarketStructs.DecreasePositionRequest) public limitDecreaseRequests;
    bytes32[] public limitDecreaseKeys;
    
    // Do we need a way to enumerate?
    mapping(bytes32 => MarketStructs.Position) public openPositions;

    address public marketStorage;

    constructor(address _marketStorage) {
        marketStorage = _marketStorage;
    }

    ///////////////////////
    // REQUEST FUNCTIONS //
    ///////////////////////

    // request index = array length before pushing
    // never allow calls directly from contract
    function createMarketOrderRequest(MarketStructs.PositionRequest memory _positionRequest) external {
        bytes32 _key = keccak256(abi.encodePacked(_positionRequest.indexToken, _positionRequest.user, _positionRequest.isLong));
        require(marketOrderRequests[_key].user == address(0), "Position already exists");
        marketOrderRequests[_key] = _positionRequest;
        marketOrderKeys.push(_key);
    }

    // Never allow calls directly from contract
    function createLimitOrderRequest(MarketStructs.PositionRequest memory _positionRequest) external {
        bytes32 _key = keccak256(abi.encodePacked(_positionRequest.indexToken, _positionRequest.user, _positionRequest.isLong));
        require(limitOrderRequests[_key].user == address(0), "Position already exists");
        limitOrderRequests[_key] = _positionRequest;
        limitOrderKeys.push(_key);
    }

    function createMarketDecreaseRequest(MarketStructs.DecreasePositionRequest memory _decreaseRequest) external {
        bytes32 _key = keccak256(abi.encodePacked(_decreaseRequest.indexToken, _decreaseRequest.user, _decreaseRequest.isLong));
        require(marketDecreaseRequests[_key].user == address(0), "Position already exists");
        marketDecreaseRequests[_key] = _decreaseRequest;
        marketDecreaseKeys.push(_key);
    }

    function createLimitDecreaseRequest(MarketStructs.DecreasePositionRequest memory _decreaseRequest) external {
        bytes32 _key = keccak256(abi.encodePacked(_decreaseRequest.indexToken, _decreaseRequest.user, _decreaseRequest.isLong));
        require(limitDecreaseRequests[_key].user == address(0), "Position already exists");
        limitDecreaseRequests[_key] = _decreaseRequest;
        limitDecreaseKeys.push(_key);
    }

    function cancelOrderRequest(bytes32 _key, bool _isLimit) external {
        if (_isLimit) {
            uint256 index = limitOrderRequests[_key].requestIndex;
            delete limitOrderRequests[_key];
            limitOrderKeys[index] = limitOrderKeys[limitOrderKeys.length - 1];
            limitOrderKeys.pop();
        } else {
            uint256 index = marketOrderRequests[_key].requestIndex;
            delete marketOrderRequests[_key];
            marketOrderKeys[index] = marketOrderKeys[marketOrderKeys.length - 1];
            marketOrderKeys.pop();
        }
    }

    // will work differently to others
    // user specifies what token he wants to swap
    // if not swap to USDC, it will route x => USDC => y
    function createSwapOrderRequest() external {}

    //////////////////////////
    // EXECUTION FUNCTIONS //
    ////////////////////////

    // only callable from executor contracts
    function executeTrade(MarketStructs.PositionRequest memory _positionRequest, uint256 _signedBlockPrice) external returns (MarketStructs.Position memory) {
        // execute the trade => create a position struct from a position request struct
        bytes32 market = keccak256(abi.encodePacked(_positionRequest.indexToken, _positionRequest.collateralToken));
        address marketAddress = IMarketStorage(marketStorage).getMarket(market).market;
        uint256 longFunding = IMarket(marketAddress).longCumulativeFundingRate();
        uint256 shortFunding = IMarket(marketAddress).shortCumulativeFundingRate();
        // make sure all Position and PositionRequest instantiations are in the correct order.
        MarketStructs.Position memory _position = MarketStructs.Position(market, _positionRequest.indexToken, _positionRequest.collateralToken, _positionRequest.user, _positionRequest.collateralDelta, _positionRequest.sizeDelta, _positionRequest.isLong, 0, 0, longFunding, shortFunding, block.timestamp, _signedBlockPrice);
        
        // remove the request from the array and the mapping
        bytes32 _requestKey = keccak256(abi.encodePacked(_positionRequest.indexToken, _positionRequest.user, _positionRequest.isLong));
        // if it's a market order, clear from market orders, else clear from limit orders
        if (_positionRequest.isMarketOrder) {
            delete marketOrderRequests[_requestKey];
            marketOrderKeys[_positionRequest.requestIndex] = marketOrderKeys[marketOrderKeys.length - 1];
            marketOrderKeys.pop();
        } else {
            delete limitOrderRequests[_requestKey];
            limitOrderKeys[_positionRequest.requestIndex] = limitOrderKeys[limitOrderKeys.length - 1];
            limitOrderKeys.pop();
        }

        // if the position exists, add on to it, else, create a new position
        if (openPositions[_requestKey].user != address(0)) {
            // add on to the position
            openPositions[_requestKey].collateralAmount += _positionRequest.collateralDelta;
            openPositions[_requestKey].positionSize += _positionRequest.sizeDelta;
            openPositions[_requestKey].averageEntryPrice = (openPositions[_requestKey].averageEntryPrice + _signedBlockPrice) / 2;
        } else {
            // create a new position
            openPositions[_requestKey] = _position;
        }
        // construct and return the position struct
        return _position;
        // fire event to be picked up by backend and stored in DB
    }

    function executeDecreaseRequest(MarketStructs.DecreasePositionRequest memory _decreaseRequest, uint256 _signedBlockPrice) external returns (MarketStructs.Position memory) {
        // Obtain the key for the position mapping based on the decrease request details
        bytes32 positionKey = keccak256(abi.encodePacked(_decreaseRequest.indexToken, _decreaseRequest.user, _decreaseRequest.isLong));

        // Obtain a reference to the position from the mapping using the position key
        MarketStructs.Position storage _position = openPositions[positionKey];

        // Check if the position exists and the decrease request is valid
        require(_position.user != address(0), "Position does not exist");
        require(_position.positionSize >= _decreaseRequest.sizeDelta, "Invalid sizeDelta");
        require(_position.collateralAmount >= _decreaseRequest.collateralDelta, "Invalid collateralDelta");

        // If it's a market order, remove the decrease request from the market orders,
        // else remove it from the limit orders
        if (_decreaseRequest.isMarketOrder) {
            delete marketDecreaseRequests[positionKey];
            marketDecreaseKeys[_decreaseRequest.requestIndex] = marketDecreaseKeys[marketDecreaseKeys.length - 1];
            marketDecreaseKeys.pop();
        } else {
            delete limitDecreaseRequests[positionKey];
            limitDecreaseKeys[_decreaseRequest.requestIndex] = limitDecreaseKeys[limitDecreaseKeys.length - 1];
            limitDecreaseKeys.pop();
        }

        // Update the position's size and collateral amount based on the decrease request
        _position.positionSize -= _decreaseRequest.sizeDelta;
        _position.collateralAmount -= _decreaseRequest.collateralDelta;
        _position.realisedPnl += int256(_decreaseRequest.sizeDelta * _signedBlockPrice);

        // transfer profit to user if profitable
        //  if (_position.realisedPnl > 0) /* transfer to user minus fees */;

        // If the position size becomes zero, remove the position from the open positions mapping
        if (_position.positionSize == 0) {
            delete openPositions[positionKey];
        }

        return _position;
    }

    //////////////////////
    // GETTER FUNCTIONS //
    //////////////////////

    function getMarketOrderKeys() external view returns (bytes32[] memory, bytes32[] memory) {
        return (marketOrderKeys, marketDecreaseKeys);
    }

    function getRequestQueueLengths() public view returns (uint256, uint256, uint256, uint256, uint256) {
        return (marketOrderKeys.length, limitOrderKeys.length, swapOrderKeys.length, marketDecreaseKeys.length, limitDecreaseKeys.length);
    }

}