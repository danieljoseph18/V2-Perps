//  ,----,------------------------------,------.
//   | ## |                              |    - |
//   | ## |                              |    - |
//   |    |------------------------------|    - |
//   |    ||............................||      |
//   |    ||,-                        -.||      |
//   |    ||___                      ___||    ##|
//   |    ||---`--------------------'---||      |
//   `--mb'|_|______________________==__|`------'

//    ____  ____  ___ _   _ _____ _____ ____
//   |  _ \|  _ \|_ _| \ | |_   _|___ /|  _ \
//   | |_) | |_) || ||  \| | | |   |_ \| |_) |
//   |  __/|  _ < | || |\  | | |  ___) |  _ <
//   |_|   |_| \_\___|_| \_| |_| |____/|_| \_\

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {ITradeStorage} from "./interfaces/ITradeStorage.sol";
import {IMarketMaker} from "../markets/interfaces/IMarketMaker.sol";
import {Funding} from "../libraries/Funding.sol";
import {Borrowing} from "../libraries/Borrowing.sol";
import {Pricing} from "../libraries/Pricing.sol";
import {IDataOracle} from "../oracle/interfaces/IDataOracle.sol";
import {IPriceOracle} from "../oracle/interfaces/IPriceOracle.sol";
import {PositionRequest} from "../structs/PositionRequest.sol";
import {Position} from "../structs/Position.sol";

// Helper functions for trade related logic
library TradeHelper {
    uint256 public constant MIN_LEVERAGE = 100; // 1x
    uint256 public constant MAX_LEVERAGE = 5000; // 50x
    uint256 public constant LEVERAGE_PRECISION = 100;
    uint256 public constant PRECISION = 1e18;

    function generateKey(PositionRequest.Data memory _request) external pure returns (bytes32 positionKey) {
        positionKey = keccak256(abi.encode(_request.indexToken, _request.user, _request.isLong));
    }

    function checkLimitPrice(uint256 _price, PositionRequest.Data memory _request) external pure {
        if (_request.isLong) {
            require(_price <= _request.orderPrice, "TH: Limit Price");
        } else {
            require(_price >= _request.orderPrice, "TH: Limit Price");
        }
    }

    // 1x = 100
    function checkLeverage(uint256 _collateralPrice, uint256 _sizeUsd, uint256 _collateral) external pure {
        uint256 collateralUsd = (_collateral * _collateralPrice) / PRECISION;
        require(collateralUsd <= _sizeUsd, "TH: cUSD > sUSD");
        uint256 leverage = (_sizeUsd * LEVERAGE_PRECISION) / collateralUsd;
        require(leverage >= MIN_LEVERAGE && leverage <= MAX_LEVERAGE, "TH: Leverage");
    }

    function createRequest(
        PositionRequest.Input calldata _trade,
        address _user,
        uint256 _collateralAmount,
        PositionRequest.Type _requestType
    ) external view returns (PositionRequest.Data memory request) {
        request = PositionRequest.Data({
            indexToken: _trade.indexToken,
            user: _user,
            collateralDelta: _collateralAmount,
            sizeDelta: _trade.sizeDelta,
            requestBlock: block.number,
            orderPrice: _trade.orderPrice,
            maxSlippage: _trade.maxSlippage,
            isLimit: _trade.isLimit,
            isLong: _trade.isLong,
            isIncrease: _trade.isIncrease,
            requestType: _requestType
        });
    }

    function generateNewPosition(
        address _marketMaker,
        address _dataOracle,
        PositionRequest.Data memory _request,
        uint256 _price
    ) external view returns (Position.Data memory position) {
        // Get Entry Funding & Borrowing Values
        bytes32 marketKey = keccak256(abi.encode(_request.indexToken));
        (uint256 longFunding, uint256 shortFunding, uint256 longBorrowFee, uint256 shortBorrowFee) =
            IMarketMaker(_marketMaker).getMarketParameters(marketKey);
        // get Trade Value in USD
        uint256 sizeUsd = getTradeValueUsd(_dataOracle, _request.indexToken, _request.sizeDelta, _price);
        position = Position.Data({
            marketKey: marketKey,
            indexToken: _request.indexToken,
            user: _request.user,
            collateralAmount: _request.collateralDelta,
            positionSize: _request.sizeDelta,
            isLong: _request.isLong,
            realisedPnl: 0,
            borrowing: Position.Borrowing(0, block.timestamp, longBorrowFee, shortBorrowFee),
            funding: Position.Funding(0, 0, block.timestamp, longFunding, shortFunding),
            pnl: Position.PnL(_price, sizeUsd)
        });
    }

    /// @dev Need to adjust for decimals
    function getTradeValueUsd(address _dataOracle, address _indexToken, uint256 _sizeDelta, uint256 _signedPrice)
        public
        view
        returns (uint256 tradeValueUsd)
    {
        uint256 baseUnit = IDataOracle(_dataOracle).getBaseUnits(_indexToken);
        tradeValueUsd = (_sizeDelta * _signedPrice) / baseUnit;
    }

    // Calculates the liquidation fee in Collateral Tokens
    function calculateLiquidationFee(address _priceOracle, uint256 _liquidationFeeUsd)
        external
        pure
        returns (uint256 liquidationFeeUSDE)
    {
        liquidationFeeUSDE = (_liquidationFeeUsd * PRECISION) / (IPriceOracle(_priceOracle).getCollateralPrice());
    }

    function convertIndexAmountToCollateral(
        address _priceOracle,
        uint256 _indexAmount,
        uint256 _indexPrice,
        uint256 _baseUnit
    ) external pure returns (uint256 collateralAmount) {
        uint256 indexUsd = (_indexAmount * _indexPrice) / _baseUnit;
        collateralAmount = (indexUsd * PRECISION) / IPriceOracle(_priceOracle).getCollateralPrice();
    }

    function getTotalFeesOwedUsd(address _dataOracle, Position.Data memory _position, uint256 _price, address _market)
        external
        view
        returns (uint256 totalFeesOwedUsd)
    {
        uint256 baseUnits = IDataOracle(_dataOracle).getBaseUnits(_position.indexToken);

        uint256 borrowingFeeOwed = Borrowing.getTotalPositionFeesOwed(_market, _position);
        uint256 borrowingFeeUsd = (borrowingFeeOwed * _price) / baseUnits;

        (, uint256 fundingFeeOwed) = Funding.getTotalPositionFees(_market, _position);
        uint256 fundingValueUsd = (fundingFeeOwed * _price) / baseUnits;

        totalFeesOwedUsd = borrowingFeeUsd + fundingValueUsd;
    }

    function getMarketKey(address _indexToken) external pure returns (bytes32 marketKey) {
        marketKey = keccak256(abi.encode(_indexToken));
    }
}
