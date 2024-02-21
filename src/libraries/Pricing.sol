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

import {IMarket} from "../markets/interfaces/IMarket.sol";
import {MarketUtils} from "../markets/MarketUtils.sol";
import {Position} from "../positions/Position.sol";
import {ud, UD60x18, unwrap, ZERO, gte} from "@prb/math/UD60x18.sol";
import {mulDiv} from "@prb/math/Common.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";

/*
    weightedAverageEntryPrice = x(indexSizeUSD * entryPrice) / sigmaIndexSizesUSD
    PNL = (Current price of index tokens - Weighted average entry price) * (Total position size / Current price of index tokens)
 */
/// @dev Library for pricing related functions
library Pricing {
    using SignedMath for int256;
    using SafeCast for uint256;

    uint256 public constant PRICE_PRECISION = 1e18;

    /// @dev returns PNL in USD
    function calculatePnL(Position.Data memory _position, uint256 _indexPriceUsd, uint256 _indexBaseUnit)
        external
        pure
        returns (int256)
    {
        uint256 entryValue = mulDiv(_position.positionSize, _position.weightedAvgEntryPrice, _indexBaseUnit);
        uint256 currentValue = mulDiv(_position.positionSize, _indexPriceUsd, _indexBaseUnit);
        return _position.isLong
            ? currentValue.toInt256() - entryValue.toInt256()
            : entryValue.toInt256() - currentValue.toInt256();
    }

    /**
     * WAEP = ∑(Position Size in Index Tokens) / ∑(Entry Price * Position Size in Index Tokens)
     */
    function calculateWeightedAverageEntryPrice(
        uint256 _prevAverageEntryPrice,
        uint256 _totalOpenInterest, // Total Index Tokens in Position / Market
        int256 _sizeDelta,
        uint256 _indexPrice
    ) external pure returns (uint256) {
        uint256 absSizeDelta = _sizeDelta.abs();
        if (_sizeDelta <= 0) {
            // If full close, Avg Entry Price is reset to 0
            if (absSizeDelta == _totalOpenInterest) return 0;
            // Else, Avg Entry Price doesn't change for decrease
            else return _prevAverageEntryPrice;
        }

        uint256 nextOpenInterest;
        uint256 nextTotalEntryValue;

        // Increasing position size
        nextOpenInterest = _totalOpenInterest + absSizeDelta;
        nextTotalEntryValue = (_prevAverageEntryPrice * _totalOpenInterest) + (_indexPrice * absSizeDelta);

        return nextTotalEntryValue / nextOpenInterest;
    }

    /// @dev Positive for profit, negative for loss. Returns PNL in USD
    function getPnl(IMarket market, uint256 _indexPrice, uint256 _indexBaseUnit, bool _isLong)
        public
        view
        returns (int256 netPnl)
    {
        // Get OI in USD
        if (_isLong) {
            // get index value
            uint256 indexValue = MarketUtils.getOpenInterestUsd(market, _indexPrice, _indexBaseUnit, true);
            // get entry value
            uint256 entryValue = MarketUtils.getTotalEntryValueUsd(market, _indexBaseUnit, _isLong);
            // return index value - entry value
            netPnl = indexValue.toInt256() - entryValue.toInt256();
        } else {
            // get entry value
            uint256 entryValue = MarketUtils.getTotalEntryValueUsd(market, _indexBaseUnit, _isLong);
            // get index value
            uint256 indexValue = MarketUtils.getOpenInterestUsd(market, _indexPrice, _indexBaseUnit, false);
            // return entry value - index value
            netPnl = entryValue.toInt256() - indexValue.toInt256();
        }
    }

    function getNetPnl(IMarket market, uint256 _indexPrice, uint256 _indexBaseUnit) external view returns (int256) {
        int256 longPnl = getPnl(market, _indexPrice, _indexBaseUnit, true);
        int256 shortPnl = getPnl(market, _indexPrice, _indexBaseUnit, false);
        return longPnl + shortPnl;
    }

    /// RealisedPNL=(Current price − Weighted average entry price)×(Realised position size/Current price)
    /// int256 pnl = int256(amountToRealise * currentTokenPrice) - int256(amountToRealise * userPos.entryPriceWeighted);
    /// @dev Returns fractional PNL in USD
    function getDecreasePositionPnl(
        uint256 _indexBaseUnit,
        uint256 _sizeDelta,
        uint256 _averageEntryPrice,
        uint256 _indexPrice,
        uint256 _collateralPrice,
        uint256 _collateralBaseUnit,
        bool _isLong
    ) external pure returns (int256 decreasePositionPnl) {
        // only realise a percentage equivalent to the percentage of the position being closed
        uint256 entryValue = mulDiv(_sizeDelta, _averageEntryPrice, _indexBaseUnit);
        uint256 exitValue = mulDiv(_sizeDelta, _indexPrice, _indexBaseUnit);
        // if long, > 0 is profit, < 0 is loss
        // if short, > 0 is loss, < 0 is profit
        int256 pnlUsd;
        if (_isLong) {
            pnlUsd = exitValue.toInt256() - entryValue.toInt256();
        } else {
            pnlUsd = entryValue.toInt256() - exitValue.toInt256();
        }
        // Convert PNL USD to Collateral Tokens
        uint256 pnlCollateral = mulDiv(pnlUsd.abs(), _collateralBaseUnit, _collateralPrice);
        return pnlUsd > 0 ? pnlCollateral.toInt256() : -pnlCollateral.toInt256();
    }
}
