// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IMarket} from "../markets/interfaces/IMarket.sol";
import {Position} from "../positions/Position.sol";
import {mulDiv, mulDivSigned} from "@prb/math/Common.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {IPriceFeed} from "../oracle/interfaces/IPriceFeed.sol";
import {Oracle} from "../oracle/Oracle.sol";

/*
    weightedAverageEntryPrice = x(indexSizeUSD * entryPrice) / sigmaIndexSizesUSD
    PNL = (Current price of index tokens - Weighted average entry price) * (Total position size / Current price of index tokens)
 */
/// @dev Library for pricing related functions
library Pricing {
    using SignedMath for int256;
    using SafeCast for uint256;

    uint256 public constant PRICE_PRECISION = 1e30;

    /// @dev returns PNL in USD
    /// @dev returns PNL in USD
    // PNL = (Current Price - Average Entry Price) * (Position Value / Average Entry Price)
    function getPositionPnl(Position.Data memory _position, uint256 _indexPrice, uint256 _indexBaseUnit)
        external
        pure
        returns (int256)
    {
        int256 priceDelta = _indexPrice.toInt256() - _position.weightedAvgEntryPrice.toInt256();
        uint256 entryIndexAmount = mulDiv(_position.positionSize, _indexBaseUnit, _position.weightedAvgEntryPrice);
        if (_position.isLong) {
            return mulDivSigned(priceDelta, entryIndexAmount.toInt256(), _indexBaseUnit.toInt256());
        } else {
            return -mulDivSigned(priceDelta, entryIndexAmount.toInt256(), _indexBaseUnit.toInt256());
        }
    }

    /**
     * WAEP = ∑(Position Size in USD) / ∑(Entry Price in USD * Position Size in USD)
     */
    function calculateWeightedAverageEntryPrice(
        uint256 _prevAverageEntryPrice,
        uint256 _prevPositionSize,
        int256 _sizeDelta,
        uint256 _indexPrice
    ) external pure returns (uint256) {
        if (_sizeDelta <= 0) {
            // If full close, Avg Entry Price is reset to 0
            if (_sizeDelta == -_prevPositionSize.toInt256()) return 0;
            // Else, Avg Entry Price doesn't change for decrease
            else return _prevAverageEntryPrice;
        }

        // Increasing position size
        uint256 newPositionSize = _prevPositionSize + _sizeDelta.abs();

        uint256 numerator = _prevAverageEntryPrice * _prevPositionSize;
        numerator += _indexPrice * _sizeDelta.abs();

        uint256 newAverageEntryPrice = numerator / newPositionSize;

        return newAverageEntryPrice;
    }

    /// @dev Positive for profit, negative for loss. Returns PNL in USD
    function getMarketPnl(IMarket market, bytes32 _assetId, uint256 _indexPrice, uint256 _indexBaseUnit, bool _isLong)
        public
        view
        returns (int256 netPnl)
    {
        uint256 openInterest = market.getOpenInterest(_assetId, _isLong);
        uint256 averageEntryPrice = market.getAverageEntryPrice(_assetId, _isLong);
        if (openInterest == 0 || averageEntryPrice == 0) return 0;
        int256 priceDelta = _indexPrice.toInt256() - averageEntryPrice.toInt256();
        uint256 entryIndexAmount = mulDiv(openInterest, _indexBaseUnit, averageEntryPrice);
        if (_isLong) {
            netPnl = mulDivSigned(priceDelta, entryIndexAmount.toInt256(), _indexBaseUnit.toInt256());
        } else {
            netPnl = -mulDivSigned(priceDelta, entryIndexAmount.toInt256(), _indexBaseUnit.toInt256());
        }
    }

    function calculateCumulativeMarketPnl(IMarket market, IPriceFeed priceFeed, bool _isLong, bool _maximise)
        external
        view
        returns (int256 cumulativePnl)
    {
        // Get an array of Asset Ids within the market
        /**
         * For each token:
         * 1. Get the current price of the token
         * 2. Get the current open interest of the token
         * 3. Get the average entry price of the token
         * 4. Calculate the PNL of the token
         * 5. Add the PNL to the cumulative PNL
         */
        bytes32[] memory assetIds = market.getAssetIds();
        // Max 10,000 Loops, so uint16 sufficient
        for (uint16 i = 0; i < assetIds.length;) {
            bytes32 assetId = assetIds[i];
            uint256 indexPrice =
                _maximise ? Oracle.getMaxPrice(priceFeed, assetId) : Oracle.getMinPrice(priceFeed, assetId);
            uint256 indexBaseUnit = Oracle.getBaseUnit(priceFeed, assetId);
            int256 pnl = getMarketPnl(market, assetId, indexPrice, indexBaseUnit, _isLong);
            cumulativePnl += pnl;
            unchecked {
                ++i;
            }
        }
    }

    function getNetMarketPnl(IMarket market, bytes32 _assetId, uint256 _indexPrice, uint256 _indexBaseUnit)
        external
        view
        returns (int256)
    {
        int256 longPnl = getMarketPnl(market, _assetId, _indexPrice, _indexBaseUnit, true);
        int256 shortPnl = getMarketPnl(market, _assetId, _indexPrice, _indexBaseUnit, false);
        return longPnl + shortPnl;
    }

    /// @dev Returns fractional PNL in USD
    function getDecreasePositionPnl(
        uint256 _sizeDeltaUsd,
        uint256 _averageEntryPriceUsd,
        uint256 _indexPrice,
        uint256 _indexBaseUnit,
        uint256 _collateralPriceUsd,
        uint256 _collateralBaseUnit,
        bool _isLong
    ) external pure returns (int256 decreasePositionPnl) {
        int256 priceDelta = _indexPrice.toInt256() - _averageEntryPriceUsd.toInt256();
        uint256 entryIndexAmount = mulDiv(_sizeDeltaUsd, _indexBaseUnit, _averageEntryPriceUsd);
        int256 pnlUsd;
        if (_isLong) {
            pnlUsd = mulDivSigned(priceDelta, entryIndexAmount.toInt256(), _indexBaseUnit.toInt256());
        } else {
            pnlUsd = -mulDivSigned(priceDelta, entryIndexAmount.toInt256(), _indexBaseUnit.toInt256());
        }
        uint256 pnlCollateral = mulDiv(pnlUsd.abs(), _collateralBaseUnit, _collateralPriceUsd);
        return pnlUsd > 0 ? pnlCollateral.toInt256() : -pnlCollateral.toInt256();
    }
}
