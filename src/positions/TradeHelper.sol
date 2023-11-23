// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {MarketStructs} from "../markets/MarketStructs.sol";
import {ITradeStorage} from "./interfaces/ITradeStorage.sol";
import {IMarketStorage} from "../markets/interfaces/IMarketStorage.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {UD60x18, ud, unwrap} from "@prb/math/UD60x18.sol";
import {FundingCalculator} from "./FundingCalculator.sol";
import {BorrowingCalculator} from "./BorrowingCalculator.sol";
import {PricingCalculator} from "./PricingCalculator.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

// Helper functions for trade related logic
library TradeHelper {
    using SafeCast for uint256;

    uint256 public constant MIN_LEVERAGE = 1e18; // 1x
    uint256 public constant MAX_LEVERAGE = 50e18; // 50x
    uint256 public constant MAX_LIQUIDATION_FEE = 100e18; // 100 USD
    uint256 public constant MAX_TRADING_FEE = 0.01e18; // 1%

    error TradeHelper_LimitPriceNotMet();
    error TradeHelper_PositionAlreadyExists();
    error TradeHelper_InvalidLeverage();
    error TradeHelper_PositionNotLiquidatable();

    // Validate whether a request should execute or not
    /// Note What is this???
    // Believe it's 1 of 3 steps in trade storage request function
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

    function checkLeverage(uint256 _size, uint256 _collateral) external pure {
        UD60x18 leverage = ud(_size).div(ud(_collateral));
        if (leverage < ud(MIN_LEVERAGE) || leverage > ud(MAX_LEVERAGE)) {
            revert TradeHelper_InvalidLeverage();
        }
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
            borrowParams: MarketStructs.BorrowParams(longBorrowFee, shortBorrowFee),
            fundingParams: MarketStructs.FundingParams(0, 0, 0, block.timestamp, longFunding, shortFunding),
            pnlParams: MarketStructs.PnLParams(
                _price,
                _positionRequest.sizeDelta * _price,
                unwrap(ud(_positionRequest.sizeDelta).div(ud(_positionRequest.collateralDelta)))
                ),
            entryTimestamp: block.timestamp
        });
    }

    function calculateTradingFee(address _tradeStorage, uint256 _sizeDelta) external view returns (uint256) {
        uint256 tradingFee = ITradeStorage(_tradeStorage).tradingFee();
        return unwrap(ud(_sizeDelta).mul(ud(tradingFee))); //e.g 0.01e18 * 100e18 / 1e18 = 1e18 = 1 Token fee
    }

    function getTradeSizeUsd(uint256 _sizeDelta, uint256 _signedPrice) external pure returns (uint256) {
        return unwrap(ud(_sizeDelta).mul(ud(_signedPrice)));
    }

    // Value Provided USD > Liquidation Fee + Fees + Losses USD
    function checkIsLiquidatable(
        MarketStructs.Position calldata _position,
        uint256 _collateralPriceUsd,
        address _tradeStorage,
        address _marketStorage
    ) external view {
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
        int256 reminance =
            collateralValueUsd.toInt256() - liquidationFeeUsd.toInt256() - totalFeesOwedUsd.toInt256() + pnl;
        // check if value provided > liquidation fee + fees + losses
        if (reminance <= 0) {
            revert TradeHelper_PositionNotLiquidatable();
        }
    }

    function getTotalFeesOwedUsd(MarketStructs.Position memory _position, uint256 _collateralPriceUsd, address _market)
        public
        view
        returns (uint256)
    {
        uint256 valueUsd = _position.collateralAmount * _collateralPriceUsd;
        uint256 borrowingFeesUsd = BorrowingCalculator.getBorrowingFees(_market, _position) * valueUsd;
        uint256 fundingFeeOwed = FundingCalculator.getTotalPositionFeeOwed(_market, _position);
        // should return % of total value => e.g 0.05 * 100 = 5
        uint256 fundingValueUsd = unwrap(ud(fundingFeeOwed) * ud(valueUsd));
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
