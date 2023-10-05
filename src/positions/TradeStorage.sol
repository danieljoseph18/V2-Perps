// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {MarketStructs} from "../markets/MarketStructs.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {IMarketStorage} from "../markets/interfaces/IMarketStorage.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ILiquidityVault} from "../markets/interfaces/ILiquidityVault.sol";

contract TradeStorage {
    using SafeERC20 for IERC20;
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

    mapping(address _user => uint256 _rewards) public accumulatedRewards;

    IMarketStorage public marketStorage;
    uint256 public liquidationFeeUsd;

    ILiquidityVault public liquidityVault;

    uint256 public constant MIN_LEVERAGE = 1;
    uint256 public constant MAX_LEVERAGE = 50;
    uint256 public constant MAX_LIQUIDATION_FEE = 100; // 100 USD max

    constructor(IMarketStorage _marketStorage, ILiquidityVault _liquidityVault) {
        marketStorage = _marketStorage;
        liquidityVault = _liquidityVault;
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
    // DEFINITELY NEED A LOT MORE SECURITY CHECKS
    function executeTrade(MarketStructs.PositionRequest memory _positionRequest, uint256 _signedBlockPrice) external returns (MarketStructs.Position memory) {
        
        uint8 requestType = uint8(_positionRequest.requestType);
        bytes32 key = keccak256(abi.encodePacked(_positionRequest.indexToken, _positionRequest.user, _positionRequest.isLong));

        // if type = 0 => collateral edit => only for collateral increase
        if (requestType == 0) {
            // check the position exists
            require(openPositions[key].user != address(0), "Position does not exist");
            // delete the request
            _deletePositionRequest(key, _positionRequest.requestIndex, true, !_positionRequest.isMarketOrder);
            // if limit => ensure the limit has been met before deleting
            if (!_positionRequest.isMarketOrder) {
                // require current price >= limit price for shorts, <= limit price for longs
                require(_positionRequest.isLong ? _signedBlockPrice <= _positionRequest.acceptablePrice : _signedBlockPrice >= _positionRequest.acceptablePrice, "Limit price not met");
            }
            // get the positions current collateral and size
            uint256 currentCollateral = openPositions[key].collateralAmount;
            uint256 currentSize = openPositions[key].positionSize;
            // validate the added collateral won't push position below min leverage
            require(currentSize / (currentCollateral + _positionRequest.collateralDelta) >= MIN_LEVERAGE, "Collateral can't exceed size");
            // edit the positions collateral and average entry price
            openPositions[key].collateralAmount += _positionRequest.collateralDelta;
            openPositions[key].averagePricePerToken += (openPositions[key].averagePricePerToken + _signedBlockPrice) / 2;
        } else if (requestType == 1) {
            // check the position exists
            require(openPositions[key].user != address(0), "Position does not exist");
            // delete the request
            _deletePositionRequest(key, _positionRequest.requestIndex, true, !_positionRequest.isMarketOrder);
            // if limit => ensure the limit has been met before deleting
            if (!_positionRequest.isMarketOrder) {
                // require current price >= limit price for shorts, <= limit price for longs
                require(_positionRequest.isLong ? _signedBlockPrice <= _positionRequest.acceptablePrice : _signedBlockPrice >= _positionRequest.acceptablePrice, "Limit price not met");
            }
            // get the positions current collateral and size
            uint256 currentCollateral = openPositions[key].collateralAmount;
            uint256 currentSize = openPositions[key].positionSize;
            // validate added size won't push position above max leverage
            require((currentSize + _positionRequest.sizeDelta) / currentCollateral <= MAX_LEVERAGE, "Size exceeds max leverage");
            // edit the positions size and average entry price
            openPositions[key].positionSize += _positionRequest.sizeDelta;
            openPositions[key].averagePricePerToken = (openPositions[key].averagePricePerToken + _signedBlockPrice) / 2;
        } else { // regular increase, or new position request
            // check the request is valid
            if (!_positionRequest.isMarketOrder) {
                // require current price >= limit price for shorts, <= limit price for longs
                require(_positionRequest.isLong ? _signedBlockPrice <= _positionRequest.acceptablePrice : _signedBlockPrice >= _positionRequest.acceptablePrice, "Limit price not met");
            }
            // if position exists, edit existing position
            _deletePositionRequest(key, _positionRequest.requestIndex, true, !_positionRequest.isMarketOrder);
            if (openPositions[key].user != address(0)) {
                // if exists, leverage must remain constant
                // calculate the size delta from the collateral delta
                // size / current collateral = leverage, +1 collateral = (+1 x leverage) size
                uint256 leverage = openPositions[key].positionSize / openPositions[key].collateralAmount;
                uint256 sizeDelta = _positionRequest.collateralDelta * leverage;

                // add on to the position
                openPositions[key].collateralAmount += _positionRequest.collateralDelta;
                openPositions[key].positionSize += sizeDelta;
                openPositions[key].averagePricePerToken = (openPositions[key].averagePricePerToken + _signedBlockPrice) / 2;
            } else {
                // create a new position
                // calculate all input variables
                bytes32 market = keccak256(abi.encodePacked(_positionRequest.indexToken, _positionRequest.collateralToken));
                address marketAddress = IMarketStorage(marketStorage).getMarket(market).market;
                uint256 longFunding = IMarket(marketAddress).longCumulativeFundingRate();
                uint256 shortFunding = IMarket(marketAddress).shortCumulativeFundingRate();
                uint256 borrowFee = IMarket(marketAddress).cumulativeBorrowFee();

                // make sure all Position and PositionRequest instantiations are in the correct order.
                MarketStructs.Position memory _position = MarketStructs.Position(market, _positionRequest.indexToken, _positionRequest.collateralToken, _positionRequest.user, _positionRequest.collateralDelta, _positionRequest.sizeDelta, _positionRequest.isLong, 0, 0, longFunding, shortFunding, borrowFee, block.timestamp, _signedBlockPrice);
                openPositions[key] = _position;
                return _position; // return the new position
            }
        }

        // fire event to be picked up by backend and stored in DB

        // return the edited position
        return openPositions[key];
    }

    // SHOULD NEVER BE CALLABLE EXCEPT FROM EXECUTOR CONTRACT
    // DEFINITELY NEED A LOT MORE SECURITY CHECKS
    function executeDecreaseRequest(MarketStructs.DecreasePositionRequest memory _decreaseRequest, uint256 _signedBlockPrice) external {
        
        uint8 requestType = uint8(_decreaseRequest.requestType);
        // Obtain the key for the position mapping based on the decrease request details
        bytes32 key = keccak256(abi.encodePacked(_decreaseRequest.indexToken, _decreaseRequest.user, _decreaseRequest.isLong));

        // position must exist for all types
        require(openPositions[key].user != address(0), "Position does not exist"); 
        // NEED OTHER CHECKS => E.G CANT DECREASE COLLATERAL BELOW UNREALIZED PNL
        if(requestType == 0) { // decrease collateral only
            _deletePositionRequest(key, _decreaseRequest.requestIndex, false, _decreaseRequest.isMarketOrder);
            // get the position's current collateral
            uint256 currentCollateral = openPositions[key].collateralAmount;
            // get the position's current size
            uint256 currentSize = openPositions[key].positionSize;
            // check that decreasing the collateral won't put position above max leverage
            require(currentSize / (currentCollateral - _decreaseRequest.collateralDelta) <= MAX_LEVERAGE, "Collateral exceeds max leverage");
            // subtract the collateral
            openPositions[key].collateralAmount -= _decreaseRequest.collateralDelta;
            // transfer the collateral
        } else if (requestType == 1) { // decrease size only
            _deletePositionRequest(key, _decreaseRequest.requestIndex, false, _decreaseRequest.isMarketOrder);
            // get the position's current size
            uint256 currentSize = openPositions[key].positionSize;
            // check that decreasing the size won't put position below the min leverage
            require(currentSize - _decreaseRequest.sizeDelta / openPositions[key].collateralAmount >= MIN_LEVERAGE, "Size below min leverage");
            // subtract the size
            openPositions[key].positionSize -= _decreaseRequest.sizeDelta;
            // calculate and transfer any profit
        } else { // decrease or close position
            _deletePositionRequest(key, _decreaseRequest.requestIndex, false, _decreaseRequest.isMarketOrder);
            // is it a full close or partial?
            // if full close, delete the position, transfer all of the collateral +- PNL
            // if partial close, calculate size delta from the collateral delta and decrease the position
            MarketStructs.Position storage _position = openPositions[key];
            uint256 leverage = _position.positionSize / _position.collateralAmount;
            uint256 sizeDelta = _decreaseRequest.collateralDelta * leverage;

            // only realise a percentage equivalent to the percentage of the position being closed
            int256 valueDelta = int256(sizeDelta * _position.averagePricePerToken) - int256(sizeDelta * _signedBlockPrice);
            // if long, > 0 is profit, < 0 is loss
            // if short, > 0 is loss, < 0 is profit
            int256 pnl;
            // if profit, add to realised pnl
            if (valueDelta >= 0) {
                _position.isLong ? pnl += valueDelta : pnl -= valueDelta;
            } else { // subtract from realised pnl
                _position.isLong ? pnl -= valueDelta : pnl += valueDelta;
            }

            _position.realisedPnl += pnl;

            _position.collateralAmount -= _decreaseRequest.collateralDelta;
            _position.positionSize -= sizeDelta;

            // validate the decrease => if removing collat, lev must remain below threshold
            // add the size and collat deltas together
            // transfer that amount
            _transferOutTokens(_decreaseRequest.collateralToken , _decreaseRequest.user, _decreaseRequest.collateralDelta, pnl);

            if (_position.positionSize == 0) {
                delete openPositions[key];
            }

        }

    }
    
    // only callable from liquidator contract
    function liquidatePosition(bytes32 _positionKey, address _liquidator) external {
        // check that the position exists
        require(openPositions[_positionKey].user != address(0), "Position does not exist");
        // get the position fees
        (uint256 borrowFee, int256 fundingFees, ) = getPositionFees(openPositions[_positionKey]);
        uint256 feesOwed = borrowFee;
        fundingFees >= 0 ? feesOwed += uint256(fundingFees) : feesOwed -= uint256(-fundingFees);
        // delete the position from storage
        delete openPositions[_positionKey];
        // transfer the liquidation fee to the liquidator
        accumulatedRewards[_liquidator] += liquidationFeeUsd;
        // transfer the remaining collateral to the liquidity vault
        // LIQUDITY VAULT NEEDS FUNCTION TO CALL CLAIM REWARDS
        accumulatedRewards[address(liquidityVault)] += feesOwed;
    }

    // deletes a position request from storage
    function _deletePositionRequest(bytes32 _key, uint256 _requestIndex, bool _isIncrease, bool _isLimit) internal {
        if (_isIncrease) {
            if (!_isLimit) { // if market increase
                delete marketOrderRequests[_key];
                marketOrderKeys[_requestIndex] = marketOrderKeys[marketOrderKeys.length - 1];
                marketOrderKeys.pop();
            } else { // if limit increase
                delete limitOrderRequests[_key];
                limitOrderKeys[_requestIndex] = limitOrderKeys[limitOrderKeys.length - 1];
                limitOrderKeys.pop();
            }
        } else {
            if (!_isLimit) { // if market decrease
                delete marketDecreaseRequests[_key];
                marketDecreaseKeys[_requestIndex] = marketDecreaseKeys[marketDecreaseKeys.length - 1];
                marketDecreaseKeys.pop();
            } else { // if limit decrease
                delete limitDecreaseRequests[_key];
                limitDecreaseKeys[_requestIndex] = limitDecreaseKeys[limitDecreaseKeys.length - 1];
                limitDecreaseKeys.pop();
            }
        }
    }

    /////////////////////
    // TOKEN TRANSFERS //
    ////////////////////

    // contract must be validated to transfer funds from TradeStorage
    // perhaps need to adopt a plugin transfer method like GMX V1
    function _transferOutTokens(address _token, address _to, uint256 _collateralDelta, int256 _pnl) internal {
        // profit = size now - initial size => initial size is not their
        uint256 amount = _collateralDelta;
        _pnl >= 0 ? amount += uint256(_pnl) : amount -= uint256(-_pnl);
        // NEED TO ALSO GET PNL FROM LIQUIDITY VAULT TO COVER THIS
        IERC20(_token).safeTransferFrom(address(this), _to, amount);
    }

    //////////////////////
    // SETTER FUNCTIONS //
    //////////////////////

    // only priviliged roles can call
    function setLiquidationFee(uint256 _newFee) external {
        liquidationFeeUsd = _newFee;
    }

    //////////////////////
    // GETTER FUNCTIONS //
    //////////////////////

    function getPositionFees(MarketStructs.Position memory _position) public view returns (uint256, int256, uint256) {
        address market = marketStorage.getMarket(_position.market).market;
        uint256 borrowFee = IMarket(market).getBorrowingFees(_position);
        int256 fundingFee = IMarket(market).getFundingFees(_position);
        return (borrowFee, fundingFee, liquidationFeeUsd);
    }

    function getMarketOrderKeys() external view returns (bytes32[] memory, bytes32[] memory) {
        return (marketOrderKeys, marketDecreaseKeys);
    }

    function getRequestQueueLengths() public view returns (uint256, uint256, uint256, uint256, uint256) {
        return (marketOrderKeys.length, limitOrderKeys.length, swapOrderKeys.length, marketDecreaseKeys.length, limitDecreaseKeys.length);
    }

}