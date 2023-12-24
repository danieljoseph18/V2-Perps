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
pragma solidity 0.8.22;

import {MarketStructs} from "../markets/MarketStructs.sol";
import {ITradeStorage} from "./interfaces/ITradeStorage.sol";
import {IMarketStorage} from "../markets/interfaces/IMarketStorage.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {FundingCalculator} from "./FundingCalculator.sol";
import {BorrowingCalculator} from "./BorrowingCalculator.sol";
import {PricingCalculator} from "./PricingCalculator.sol";
import {IDataOracle} from "../oracle/interfaces/IDataOracle.sol";
import {IPriceOracle} from "../oracle/interfaces/IPriceOracle.sol";

// Helper functions for trade related logic
library TradeHelper {
    uint256 public constant MIN_LEVERAGE = 100; // 1x
    uint256 public constant MAX_LEVERAGE = 5000; // 50x
    uint256 public constant LEVERAGE_PRECISION = 100;
    uint256 public constant MAX_LIQUIDATION_FEE = 100e18; // 100 USD
    uint256 public constant MAX_TRADING_FEE = 0.01e18; // 1%
    uint256 public constant PRECISION = 1e18;

    error TradeHelper_LimitPriceNotMet();
    error TradeHelper_RequestAlreadyExists();
    error TradeHelper_InvalidLeverage();
    error TradeHelper_PositionNotLiquidatable();
    error TradeHelper_InvalidCollateralReduction();

    // Validate whether a request should execute or not
    function validateRequest(address _tradeStorage, bytes32 _key, bool _isLimit) external view returns (bool) {
        MarketStructs.PositionRequest memory request = ITradeStorage(_tradeStorage).orders(_isLimit, _key);
        if (request.user != address(0)) revert TradeHelper_RequestAlreadyExists();
        return true;
    }

    function generateKey(MarketStructs.PositionRequest memory _positionRequest) external pure returns (bytes32) {
        return keccak256(abi.encode(_positionRequest.indexToken, _positionRequest.user, _positionRequest.isLong));
    }

    function checkLimitPrice(uint256 _price, MarketStructs.PositionRequest memory _positionRequest) external pure {
        if (_positionRequest.isLong) {
            if (_price > _positionRequest.orderPrice) revert TradeHelper_LimitPriceNotMet();
        } else {
            if (_price < _positionRequest.orderPrice) revert TradeHelper_LimitPriceNotMet();
        }
    }

    // 1x = 100
    function checkLeverage(
        address _dataOracle,
        address _priceOracle,
        address _indexToken,
        uint256 _signedPrice,
        uint256 _size,
        uint256 _collateral
    ) external view {
        uint256 leverage = calculateLeverage(_dataOracle, _priceOracle, _indexToken, _signedPrice, _size, _collateral);
        if (leverage < MIN_LEVERAGE || leverage > MAX_LEVERAGE) revert TradeHelper_InvalidLeverage();
    }

    function calculateLeverage(
        address _dataOracle,
        address _priceOracle,
        address _indexToken,
        uint256 _signedPrice,
        uint256 _size,
        uint256 _collateral
    ) public view returns (uint256) {
        uint256 sizeUsd = getTradeValueUsd(_dataOracle, _indexToken, _size, _signedPrice);
        uint256 collateralUsd = (_collateral * IPriceOracle(_priceOracle).getCollateralPrice()) / PRECISION;
        return (sizeUsd * LEVERAGE_PRECISION) / collateralUsd;
    }

    function createPositionRequest(
        address _tradeStorage,
        MarketStructs.Trade calldata _trade,
        address _user,
        uint256 _collateralAmount
    ) external view returns (MarketStructs.PositionRequest memory positionRequest) {
        (uint256 marketLen, uint256 limitLen) = ITradeStorage(_tradeStorage).getRequestQueueLengths();
        uint256 index = _trade.isLimit ? limitLen : marketLen;

        positionRequest = MarketStructs.PositionRequest({
            requestIndex: index,
            indexToken: _trade.indexToken,
            user: _user,
            collateralDelta: _collateralAmount,
            sizeDelta: _trade.sizeDelta,
            requestBlock: block.number,
            orderPrice: _trade.orderPrice,
            maxSlippage: _trade.maxSlippage,
            isLimit: _trade.isLimit,
            isLong: _trade.isLong,
            isIncrease: _trade.isIncrease
        });
    }

    function generateNewPosition(
        address _market,
        address _tradeStorage,
        address _dataOracle,
        address _priceOracle,
        MarketStructs.PositionRequest memory _positionRequest,
        uint256 _price
    ) external view returns (MarketStructs.Position memory) {
        // create a new position
        // calculate all input variables
        (uint256 longFunding, uint256 shortFunding, uint256 longBorrowFee, uint256 shortBorrowFee) =
            IMarket(_market).getMarketParameters();
        // make sure all Position and PositionRequest instantiations are in the correct order.
        uint256 leverage = calculateLeverage(
            _dataOracle,
            _priceOracle,
            _positionRequest.indexToken,
            _price,
            _positionRequest.sizeDelta,
            _positionRequest.collateralDelta
        );
        uint256 sizeUsd = getTradeValueUsd(_dataOracle, _positionRequest.indexToken, _positionRequest.sizeDelta, _price);
        bytes32 marketKey = getMarketKey(_positionRequest.indexToken);
        return MarketStructs.Position({
            index: ITradeStorage(_tradeStorage).getNextPositionIndex(marketKey, _positionRequest.isLong),
            market: marketKey,
            indexToken: _positionRequest.indexToken,
            user: _positionRequest.user,
            collateralAmount: _positionRequest.collateralDelta,
            positionSize: _positionRequest.sizeDelta,
            isLong: _positionRequest.isLong,
            realisedPnl: 0,
            borrowParams: MarketStructs.BorrowParams(0, block.timestamp, longBorrowFee, shortBorrowFee),
            fundingParams: MarketStructs.FundingParams(0, 0, block.timestamp, longFunding, shortFunding),
            pnlParams: MarketStructs.PnLParams(_price, sizeUsd, leverage),
            entryTimestamp: block.timestamp
        });
    }

    /// @dev Need to adjust for decimals
    function getTradeValueUsd(address _dataOracle, address _indexToken, uint256 _sizeDelta, uint256 _signedPrice)
        public
        view
        returns (uint256)
    {
        uint256 baseUnit = IDataOracle(_dataOracle).getBaseUnits(_indexToken);
        return (_sizeDelta * _signedPrice) / baseUnit;
    }

    // Value Provided USD > Liquidation Fee + Fees + Losses USD
    function checkIsLiquidatable(
        MarketStructs.Position memory _position,
        uint256 _collateralPriceUsd,
        address _tradeStorage,
        address _marketStorage,
        address _priceOracle,
        address _dataOracle
    ) public view returns (bool) {
        // get the total value provided in USD
        uint256 collateralValueUsd = (_position.collateralAmount * _collateralPriceUsd) / PRECISION;
        // get the liquidation fee in USD
        uint256 liquidationFeeUsd = ITradeStorage(_tradeStorage).liquidationFeeUsd();
        // get the total fees owed (funding + borrowing) in USD => funding should be net
        // If fees earned > fees owed, should just be 0 => Let's extrapolate this out to FUnding Calculator
        uint256 totalFeesOwedUsd = getTotalFeesOwedUsd(_position, _collateralPriceUsd, _marketStorage);
        // get the total losses in USD
        int256 pnl = PricingCalculator.calculatePnL(_priceOracle, _dataOracle, _position);
        int256 reminance = int256(collateralValueUsd) - int256(liquidationFeeUsd) - int256(totalFeesOwedUsd) + pnl;
        // check if value provided > liquidation fee + fees + losses
        if (reminance <= 0) {
            return true;
        } else {
            return false;
        }
    }

    function calculateLiquidationFee(address _priceOracle, uint256 _liquidationFeeUsd)
        external
        pure
        returns (uint256)
    {
        return (_liquidationFeeUsd * PRECISION) / (IPriceOracle(_priceOracle).getCollateralPrice());
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
        address _priceOracle,
        address _dataOracle,
        address _marketStorage
    ) external view returns (bool) {
        if (_position.collateralAmount <= _collateralDelta) return false;
        _position.collateralAmount -= _collateralDelta;
        uint256 collateralPrice = IPriceOracle(_priceOracle).getCollateralPrice();
        bool isValid =
            !checkIsLiquidatable(_position, collateralPrice, _marketStorage, _marketStorage, _priceOracle, _dataOracle);
        return isValid;
    }

    function getTotalFeesOwedUsd(MarketStructs.Position memory _position, uint256 _price, address _market)
        public
        view
        returns (uint256)
    {
        uint256 positionValueUsd = (_position.positionSize * _price) / PRECISION;
        uint256 borrowingFees = BorrowingCalculator.getBorrowingFees(_market, _position);

        uint256 borrowingFeesUsd = (positionValueUsd * borrowingFees) / PRECISION;

        (, uint256 fundingFeeOwed) = FundingCalculator.getTotalPositionFees(_market, _position);
        uint256 fundingValueUsd = (fundingFeeOwed * _price) / PRECISION;

        return borrowingFeesUsd + fundingValueUsd;
    }

    function getMarket(address _marketStorage, address _indexToken) external view returns (address) {
        bytes32 market = keccak256(abi.encode(_indexToken));
        return IMarketStorage(_marketStorage).markets(market).market;
    }

    function getMarketKey(address _indexToken) public pure returns (bytes32) {
        return keccak256(abi.encode(_indexToken));
    }
}
