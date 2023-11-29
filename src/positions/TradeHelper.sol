// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {MarketStructs} from "../markets/MarketStructs.sol";
import {ITradeStorage} from "./interfaces/ITradeStorage.sol";
import {IMarketStorage} from "../markets/interfaces/IMarketStorage.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {FundingCalculator} from "./FundingCalculator.sol";
import {BorrowingCalculator} from "./BorrowingCalculator.sol";
import {PricingCalculator} from "./PricingCalculator.sol";

// Helper functions for trade related logic
library TradeHelper {
    uint256 public constant MIN_LEVERAGE = 1e18; // 1x
    uint256 public constant MAX_LEVERAGE = 5000; // 50x
    uint256 public constant MAX_LIQUIDATION_FEE = 100e30; // 100 USD
    uint256 public constant MAX_TRADING_FEE = 0.01e18; // 1%

    error TradeHelper_LimitPriceNotMet();
    error TradeHelper_PositionAlreadyExists();
    error TradeHelper_InvalidLeverage();
    error TradeHelper_PositionNotLiquidatable();
    error TradeHelper_InvalidCollateralReduction();

    // Validate whether a request should execute or not
    function validateRequest(address _tradeStorage, bytes32 _key, bool _isLimit) external view returns (bool) {
        MarketStructs.PositionRequest memory request = ITradeStorage(_tradeStorage).orders(_isLimit, _key);
        if (request.user != address(0)) revert TradeHelper_PositionAlreadyExists();
        return true;
    }

    function generateKey(MarketStructs.PositionRequest memory _positionRequest) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(_positionRequest.indexToken, _positionRequest.user, _positionRequest.isLong));
    }

    function checkLimitPrice(uint256 _price, MarketStructs.PositionRequest memory _positionRequest) external pure {
        if (_positionRequest.isLong) {
            if (_price > _positionRequest.acceptablePrice) revert TradeHelper_LimitPriceNotMet();
        } else {
            if (_price < _positionRequest.acceptablePrice) revert TradeHelper_LimitPriceNotMet();
        }
    }

    // 1x = 100
    function checkLeverage(uint256 _size, uint256 _collateral) external pure {
        uint256 leverage = (_size * 100) / _collateral;
        if (leverage < MIN_LEVERAGE || leverage > MAX_LEVERAGE) {
            revert TradeHelper_InvalidLeverage();
        }
    }

    function calculateLeverage(uint256 _size, uint256 _collateral) external pure returns (uint256) {
        return (_size * 100) / _collateral;
    }

    function generateNewPosition(
        address _market,
        address _tradeStorage,
        MarketStructs.PositionRequest memory _positionRequest,
        uint256 _price
    ) external view returns (MarketStructs.Position memory) {
        // create a new position
        // calculate all input variables
        (uint256 longFunding, uint256 shortFunding, uint256 longBorrowFee, uint256 shortBorrowFee) =
            IMarket(_market).getMarketParameters();
        // make sure all Position and PositionRequest instantiations are in the correct order.
        return MarketStructs.Position({
            index: ITradeStorage(_tradeStorage).getNextPositionIndex(
                keccak256(abi.encodePacked(_positionRequest.indexToken)), _positionRequest.isLong
                ),
            market: keccak256(abi.encodePacked(_positionRequest.indexToken)),
            indexToken: _positionRequest.indexToken,
            user: _positionRequest.user,
            collateralAmount: _positionRequest.collateralDelta,
            positionSize: _positionRequest.sizeDelta,
            isLong: _positionRequest.isLong,
            realisedPnl: 0,
            borrowParams: MarketStructs.BorrowParams(0, block.timestamp, longBorrowFee, shortBorrowFee),
            fundingParams: MarketStructs.FundingParams(0, 0, block.timestamp, longFunding, shortFunding),
            pnlParams: MarketStructs.PnLParams(
                _price,
                _positionRequest.sizeDelta * _price,
                (_positionRequest.sizeDelta * 100) / _positionRequest.collateralDelta
                ),
            entryTimestamp: block.timestamp
        });
    }

    function calculateTradingFee(address _tradeStorage, uint256 _sizeDelta) external view returns (uint256) {
        uint256 tradingFee = ITradeStorage(_tradeStorage).tradingFee();
        uint256 divisor = 1e18 / tradingFee;
        return _sizeDelta / divisor; //e.g 1e18 / 0.01e18 = 100 => x / 100 = fee
    }

    function getTradeSizeUsd(uint256 _sizeDelta, uint256 _signedPrice) external pure returns (uint256) {
        return _sizeDelta * _signedPrice;
    }

    // Value Provided USD > Liquidation Fee + Fees + Losses USD
    function checkIsLiquidatable(
        MarketStructs.Position memory _position,
        uint256 _collateralPriceUsd,
        address _tradeStorage,
        address _marketStorage
    ) public view returns (bool) {
        address market = getMarket(_marketStorage, _position.indexToken);
        // get the total value provided in USD
        uint256 collateralValueUsd = _position.collateralAmount * _collateralPriceUsd;
        // get the liquidation fee in USD
        uint256 liquidationFeeUsd = ITradeStorage(_tradeStorage).liquidationFeeUsd();
        // get the total fees owed (funding + borrowing) in USD => funding should be net
        // If fees earned > fees owed, should just be 0 => Let's extrapolate this out to FUnding Calculator
        uint256 totalFeesOwedUsd = getTotalFeesOwedUsd(_position, _collateralPriceUsd, _marketStorage);
        // get the total losses in USD
        int256 pnl = PricingCalculator.calculatePnL(market, _position);
        int256 reminance = int256(collateralValueUsd) - int256(liquidationFeeUsd) - int256(totalFeesOwedUsd) + pnl;
        // check if value provided > liquidation fee + fees + losses
        if (reminance <= 0) {
            return true;
        } else {
            return false;
        }
    }

    function checkMinCollateral(
        MarketStructs.PositionRequest memory _positionRequest,
        uint256 _collateralPriceUsd,
        address _tradeStorage
    ) external view returns (bool) {
        uint256 minCollateralUsd = ITradeStorage(_tradeStorage).minCollateralUsd();
        uint256 requestCollateralUsd = _positionRequest.collateralDelta * _collateralPriceUsd;
        if (requestCollateralUsd < minCollateralUsd) {
            return false;
        } else {
            return true;
        }
    }

    function checkCollateralReduction(
        MarketStructs.Position memory _position,
        uint256 _collateralDelta,
        uint256 _collateralPriceUsd,
        address _marketStorage
    ) external view returns (bool) {
        if (_position.collateralAmount <= _collateralDelta) return false;
        _position.collateralAmount -= _collateralDelta;
        bool isValid = !checkIsLiquidatable(_position, _collateralPriceUsd, _marketStorage, _marketStorage);
        return isValid;
    }

    function getTotalFeesOwedUsd(MarketStructs.Position memory _position, uint256 _price, address _market)
        public
        view
        returns (uint256)
    {
        uint256 valueUsd = _position.positionSize * _price;
        uint256 borrowingFees = BorrowingCalculator.getBorrowingFees(_market, _position);
        uint256 borrowingDivisor = 1e18 / borrowingFees;

        uint256 borrowingFeesUsd = valueUsd / borrowingDivisor;

        uint256 fundingFeeOwed = FundingCalculator.getTotalPositionFeeOwed(_market, _position);
        uint256 fundingValueUsd = fundingFeeOwed * _price;

        return borrowingFeesUsd + fundingValueUsd;
    }

    function getMarket(address _marketStorage, address _indexToken) public view returns (address) {
        bytes32 market = keccak256(abi.encodePacked(_indexToken));
        return IMarketStorage(_marketStorage).getMarket(market).market;
    }

    function getMarketKey(address _indexToken) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(_indexToken));
    }
}
