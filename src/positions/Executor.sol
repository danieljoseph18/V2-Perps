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
        address market = IMarketStorage(marketStorage).getMarket(_marketKey).market;
        IMarket(market).updateFundingRate();
    }

    function _updateBorrowingRate(bytes32 _marketKey, bool _isLong) internal {
        address market = IMarketStorage(marketStorage).getMarket(_marketKey).market;
        IMarket(market).updateBorrowingRate(_isLong);
    }

    function _updateCumulativePricePerToken(bytes32 _marketKey, uint256 _pricePaid, bool _isIncrease, bool _isLong)
        internal
    {
        address market = IMarketStorage(marketStorage).getMarket(_marketKey).market;
        IMarket(market).updateCumulativePricePerToken(_pricePaid, _isIncrease, _isLong);
    }

    //////////////////////////
    // EXECUTION FUNCTIONS //
    ////////////////////////

    // only permissioned roles can call
    // called on set intervals, e.g every 5 - 10 seconds => crucial to prevent a backlog from building up
    // if too much backlog builds up, may be too expensive to loop through entire request array
    // can execute all limit orders, or all market orders
    function executeTradeOrders(bool _limits) external onlyKeeper {
        // cache the order queue
        (bytes32[] memory limitOrders, bytes32[] memory marketOrders) = tradeStorage.getOrderKeys();
        bytes32[] memory orders = _limits ? limitOrders : marketOrders;
        uint256 len = orders.length;
        // loop through => get Position => fulfill position at signed block price
        for (uint256 i = 0; i < len; ++i) {
            bytes32 _key = orders[i];
            _executeTradeOrder(_key, msg.sender, _limits);
        }
    }

    /// @dev Only Keeper
    function executeTradeOrder(bytes32 _key, bool _isLimit) public onlyKeeper {
        _executeTradeOrder(_key, msg.sender, _isLimit);
    }

    // make facilitate increase and decrease
    function _executeTradeOrder(bytes32 _key, address _executor, bool _isLimit) internal {
        // get the position
        MarketStructs.PositionRequest memory _positionRequest = tradeStorage.orders(_isLimit, _key);
        require(_positionRequest.user != address(0), "Executor: Invalid Request Key");
        // get the market and block to get the signed block price
        address _market = IMarketStorage(marketStorage).getMarketFromIndexToken(
            _positionRequest.indexToken, _positionRequest.collateralToken
        ).market;
        uint256 _block = _positionRequest.requestBlock;
        uint256 _signedBlockPrice = IPriceOracle(priceOracle).getSignedPrice(_market, _block);

        if (_isLimit) {
            require(
                (_positionRequest.isLong && _signedBlockPrice <= _positionRequest.acceptablePrice)
                    || (!_positionRequest.isLong && _signedBlockPrice >= _positionRequest.acceptablePrice),
                "Executor: Price Target Not Hit"
            );
        }
        // execute the trade
        MarketStructs.Position memory _position =
            tradeStorage.executeTrade(MarketStructs.ExecutionParams(_positionRequest, _signedBlockPrice, _executor));
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
        _updateCumulativePricePerToken(_position.market, _signedBlockPrice, true, _positionRequest.isLong);
    }

    // used as a stop loss => how do we get trailing stop losses
    // limit decrease should be set as a percentage of the current price ?? how does a trailing stop loss work?
}
