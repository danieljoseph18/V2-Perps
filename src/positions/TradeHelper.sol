// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {MarketStructs} from "../markets/MarketStructs.sol";
import {ITradeStorage} from "./interfaces/ITradeStorage.sol";
import {IMarketStorage} from "../markets/interfaces/IMarketStorage.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {UD60x18, ud, unwrap} from "@prb/math/UD60x18.sol";
import {FundingCalculator} from "./FundingCalculator.sol";

// Helper functions for trade related logic
library TradeHelper {
    uint256 public constant MIN_LEVERAGE = 1e18; // 1x
    uint256 public constant MAX_LEVERAGE = 50e18; // 50x
    uint256 public constant MAX_LIQUIDATION_FEE = 100e18; // 100 USD

    // Validate whether a request should execute or not
    function validateRequest(address _tradeStorage, bytes32 _key, bool _isLimit) external view returns (bool) {
        MarketStructs.PositionRequest memory request = ITradeStorage(_tradeStorage).orders(_isLimit, _key);
        if (_isLimit) {
            require(request.user == address(0), "Position already exists");
        } else {
            require(request.user == address(0), "Position already exists");
        }
        return true;
    }

    function generateKey(MarketStructs.PositionRequest memory _positionRequest) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(_positionRequest.indexToken, _positionRequest.user, _positionRequest.isLong));
    }

    function checkLimitPrice(uint256 _price, MarketStructs.PositionRequest memory _positionRequest) external pure {
        require(
            _positionRequest.isLong
                ? _price <= _positionRequest.acceptablePrice
                : _price >= _positionRequest.acceptablePrice,
            "Limit price not met"
        );
    }

    function checkLeverage(uint256 _size, uint256 _collateral) external pure {
        require(
            ud(_size).div(ud(_collateral)) >= ud(MIN_LEVERAGE) && ud(_size).div(ud(_collateral)) <= ud(MAX_LEVERAGE),
            "TradeHelper: Invalid Leverage"
        );
    }

    function calculateLeverage(uint256 _size, uint256 _collateral) external pure returns (uint256) {
        return unwrap(ud(_size).div(ud(_collateral)));
    }

    function calculateNewAveragePricePerToken(uint256 _prevAveragePricePerToken, uint256 _newPrice)
        external
        pure
        returns (uint256)
    {
        return unwrap(ud(_prevAveragePricePerToken).avg(ud(_newPrice)));
    }

    function generateNewPosition(
        address _tradeStorage,
        MarketStructs.PositionRequest memory _positionRequest,
        uint256 _price,
        address _marketStorage
    ) external view returns (MarketStructs.Position memory) {
        // create a new position
        // calculate all input variables
        address marketAddress = getMarket(_marketStorage, _positionRequest.indexToken, _positionRequest.collateralToken);
        bytes32 marketKey = getMarketKey(_positionRequest.indexToken, _positionRequest.collateralToken);
        (uint256 longFunding, uint256 shortFunding, uint256 longBorrowFee, uint256 shortBorrowFee) =
            IMarket(marketAddress).getMarketParameters();
        uint256 nextIndex = ITradeStorage(_tradeStorage).getNextPositionIndex(marketKey, _positionRequest.isLong);
        // make sure all Position and PositionRequest instantiations are in the correct order.
        return MarketStructs.Position({
            index: nextIndex,
            market: marketKey,
            indexToken: _positionRequest.indexToken,
            collateralToken: _positionRequest.collateralToken,
            user: _positionRequest.user,
            collateralAmount: _positionRequest.collateralDelta,
            positionSize: _positionRequest.sizeDelta,
            isLong: _positionRequest.isLong,
            realisedPnl: 0,
            borrowParams: MarketStructs.BorrowParams(longBorrowFee, shortBorrowFee),
            fundingParams: MarketStructs.FundingParams(0, 0, 0, 0, 0, block.timestamp, longFunding, shortFunding),
            averagePricePerToken: _price,
            entryTimestamp: block.timestamp
        });
    }

    function calculateTradingFee(address _tradeStorage, uint256 _sizeDelta) external view returns (uint256) {
        uint256 tradingFee = ITradeStorage(_tradeStorage).tradingFee();
        return unwrap(ud(_sizeDelta).mul(ud(tradingFee))); //e.g 0.01e18 * 100e18 / 1e18 = 1e18 = 1 Token fee
    }

    function getMarket(address _marketStorage, address _indexToken, address _collateralToken)
        public
        view
        returns (address)
    {
        bytes32 market = keccak256(abi.encodePacked(_indexToken, _collateralToken));
        return IMarketStorage(_marketStorage).getMarket(market).market;
    }

    function getMarketKey(address _indexToken, address _collateralToken) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(_indexToken, _collateralToken));
    }
}
