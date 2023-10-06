// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {IMarketStorage} from "../markets/interfaces/IMarketStorage.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {ITradeStorage} from "./interfaces/ITradeStorage.sol";
import {MarketStructs} from "../markets/MarketStructs.sol";
import {IPriceOracle} from "../oracle/interfaces/IPriceOracle.sol";
import {ILiquidityVault} from "../markets/interfaces/ILiquidityVault.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {RoleValidation} from "../access/RoleValidation.sol";

/// @dev Needs Executor Role
contract Executor is RoleValidation {
    error Executor_LimitNotHit();
    using SafeERC20 for IERC20;
    // contract for executing trades
    // will be called by the TradeManager
    // will execute trades on the market contract
    // will execute trades on the funding contract
    // will execute trades on the liquidator contract

    IMarketStorage public marketStorage;
    ITradeStorage public tradeStorage;
    address public priceOracle;
    ILiquidityVault public liquidityVault;

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

    ////////////////////
    // STATE UPDATERS //
    ////////////////////

    // when executing a trade, store it in MarketStorage
    // update the open interest in MarketStorage
    // if decrease, subtract size delta from open interest
    function _updateOpenInterest(
        bytes32 _marketKey,
        uint256 _collateralDelta,
        uint256 _sizeDelta,
        bool _isLong,
        bool _isDecrease
    ) internal {
        bool shouldAdd = (_isLong && !_isDecrease) || (!_isLong && _isDecrease);
        IMarketStorage(marketStorage).updateOpenInterest(_marketKey, _collateralDelta, _sizeDelta, _isLong, shouldAdd);
    }

    // in every action that interacts with Market, call _updateFundingRate();
    function _updateFundingRate(bytes32 _marketKey) internal {
        address _market = IMarketStorage(marketStorage).getMarket(_marketKey).market;
        IMarket(_market).updateFundingRate();
    }

    function _updateBorrowingRate(bytes32 _marketKey, bool _isLong) internal {
        address _market = IMarketStorage(marketStorage).getMarket(_marketKey).market;
        IMarket(_market).updateBorrowingRate(_isLong);
    }

    function _updateMarketAllocations() internal {
        ILiquidityVault(liquidityVault).updateMarketAllocations();
    }

    //////////////////////////
    // EXECUTION FUNCTIONS //
    ////////////////////////

    // only permissioned roles can call
    // called on set intervals, e.g every 5 - 10 seconds => crucial to prevent a backlog from building up
    // if too much backlog builds up, may be too expensive to loop through entire request array
    function executeMarketOrders() external {
        // cache the order queue
        (bytes32[] memory orders,) = tradeStorage.getMarketOrderKeys();
        uint256 len = orders.length;
        // loop through => get Position => fulfill position at signed block price
        for (uint256 i = 0; i < len; ++i) {
            bytes32 _key = orders[i];
            executeMarketOrder(_key);
        }
    }

    /// @dev Only Keeper
    function executeMarketOrder(bytes32 _key) public onlyKeeper {
        // get the position
        MarketStructs.PositionRequest memory _positionRequest = tradeStorage.marketOrderRequests(_key);
        require(_positionRequest.user != address(0), "Executor: Invalid Request Key");
        // get the market and block to get the signed block price
        address _market = IMarketStorage(marketStorage).getMarketFromIndexToken(
            _positionRequest.indexToken, _positionRequest.collateralToken
        ).market;
        uint256 _block = _positionRequest.requestBlock;
        uint256 _signedBlockPrice = IPriceOracle(priceOracle).getSignedPrice(_market, _block);

        // execute the trade
        MarketStructs.Position memory _position =
            tradeStorage.executeTrade(_positionRequest, _signedBlockPrice, msg.sender);
        // update open interest
        // always increase => should add is equal to isLong
        _updateOpenInterest(
            _position.market,
            _positionRequest.collateralDelta,
            _positionRequest.sizeDelta,
            _positionRequest.isLong,
            _positionRequest.isLong
        );
        // update funding rate
        _updateFundingRate(_position.market);
        _updateBorrowingRate(_position.market, _positionRequest.isLong);
        _updateMarketAllocations();
    }

    // no loop execution for limits => 1 by 1, track price on subgraph
    /// @dev Only Keeper
    function executeLimitOrder(bytes32 _key) external onlyKeeper {
        // get the position
        MarketStructs.PositionRequest memory _positionRequest = tradeStorage.limitOrderRequests(_key);
        require(_positionRequest.user != address(0), "Executor: Invalid Request Key");
        // get the current price
        uint256 price = IPriceOracle(priceOracle).getPrice(_positionRequest.indexToken);
        // if current price >= acceptable price and isShort, execute
        // if current price <= acceptable price and isLong, execute
        if (
            (_positionRequest.isLong && price <= _positionRequest.acceptablePrice)
                || (!_positionRequest.isLong && price >= _positionRequest.acceptablePrice)
        ) {
            // execute the trade
            MarketStructs.Position memory _position = tradeStorage.executeTrade(_positionRequest, price, msg.sender);
            // update open interest
            // always increase => should add is equal to isLong
            _updateOpenInterest(
                _position.market,
                _positionRequest.collateralDelta,
                _positionRequest.sizeDelta,
                _positionRequest.isLong,
                _positionRequest.isLong
            );
            // update funding rate
            _updateFundingRate(_position.market);
            _updateBorrowingRate(_position.market, _positionRequest.isLong);
            _updateMarketAllocations();
        } else {
            revert Executor_LimitNotHit();
        }
    }

    function executeDecreaseOrders() external {
        // cache the order queue
        (, bytes32[] memory orders) = tradeStorage.getMarketOrderKeys();
        uint256 len = orders.length;
        // loop through => get Position => fulfill position at signed block price
        for (uint256 i = 0; i < len; ++i) {
            bytes32 _key = orders[i];
            executeMarketDecrease(_key);
        }
    }

    /// @dev Only Keeper
    function executeMarketDecrease(bytes32 _key) public onlyKeeper {
        // get the request
        MarketStructs.DecreasePositionRequest memory _decreaseRequest = tradeStorage.marketDecreaseRequests(_key);
        require(_decreaseRequest.user != address(0), "Invalid decrease request");
        // get the market and block to get the signed block price
        address _market = IMarketStorage(marketStorage).getMarketFromIndexToken(
            _decreaseRequest.indexToken, _decreaseRequest.collateralToken
        ).market;
        uint256 _block = _decreaseRequest.requestBlock;
        uint256 _signedBlockPrice = IPriceOracle(priceOracle).getSignedPrice(_market, _block);
        bytes32 key =
            keccak256(abi.encodePacked(_decreaseRequest.indexToken, _decreaseRequest.user, _decreaseRequest.isLong));
        MarketStructs.Position memory _position = tradeStorage.openPositions(key);
        // execute the trade => do we pass in size delta too to prevent double calculation?
        uint256 leverage = _position.positionSize / _position.collateralAmount;
        uint256 sizeDelta = _decreaseRequest.collateralDelta * leverage;
        tradeStorage.executeDecreaseRequest(_decreaseRequest, _signedBlockPrice, msg.sender);
        // always decrease, so shouldAdd is opposite of isLong
        // are these input values correct to update contract state?
        _updateOpenInterest(
            _position.market,
            _decreaseRequest.collateralDelta,
            sizeDelta,
            _decreaseRequest.isLong,
            !_decreaseRequest.isLong
        );
        _updateFundingRate(_position.market);
        _updateBorrowingRate(_position.market, _decreaseRequest.isLong);
        _updateMarketAllocations();
    }

    // used as a stop loss => how do we get trailing stop losses
    // limit decrease should be set as a percentage of the current price ?? how does a trailing stop loss work?
    /// @dev Only Keeper
    function executeLimitDecrease(bytes32 _key) external onlyKeeper {
        // get the request
        MarketStructs.DecreasePositionRequest memory _decreaseRequest = tradeStorage.limitDecreaseRequests(_key);
        require(_decreaseRequest.user != address(0), "Invalid decrease request");
        // get the current price
        uint256 price = IPriceOracle(priceOracle).getPrice(_decreaseRequest.indexToken);
        // if current price >= acceptable price and isShort, execute
        // if current price <= acceptable price and isLong, execute
        if (
            (_decreaseRequest.isLong && price <= _decreaseRequest.acceptablePrice)
                || (!_decreaseRequest.isLong && price >= _decreaseRequest.acceptablePrice)
        ) {
            // execute the trade
            bytes32 key =
                keccak256(abi.encodePacked(_decreaseRequest.indexToken, _decreaseRequest.user, _decreaseRequest.isLong));
            MarketStructs.Position memory _position = tradeStorage.openPositions(key);
            // execute the trade => do we pass in size delta too to prevent double calculation?
            uint256 leverage = _position.positionSize / _position.collateralAmount;
            // size delta must remain proportional to the collateral when decreasing
            // i.e leverage must remain constant => thus it is calculated here and passed in, instead of by user
            uint256 sizeDelta = _decreaseRequest.collateralDelta * leverage;
            tradeStorage.executeDecreaseRequest(_decreaseRequest, price, msg.sender);
            // always decrease, so should add is opposite of isLong
            _updateOpenInterest(
                _position.market,
                _decreaseRequest.collateralDelta,
                sizeDelta,
                _decreaseRequest.isLong,
                !_decreaseRequest.isLong
            );
            _updateFundingRate(_position.market);
            _updateBorrowingRate(_position.market, _decreaseRequest.isLong);
            _updateMarketAllocations();
        } else {
            revert Executor_LimitNotHit();
        }
    }
}
