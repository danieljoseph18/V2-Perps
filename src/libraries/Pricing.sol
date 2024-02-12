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

import {Market} from "../markets/Market.sol";
import {MarketUtils} from "../markets/MarketUtils.sol";
import {Position} from "../positions/Position.sol";
import {ud, UD60x18, unwrap} from "@prb/math/UD60x18.sol";
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
        uint256 entryValue = mulDiv(_position.positionSize, _position.pnlParams.weightedAvgEntryPrice, _indexBaseUnit);
        uint256 currentValue = mulDiv(_position.positionSize, _indexPriceUsd, _indexBaseUnit);
        return _position.isLong
            ? currentValue.toInt256() - entryValue.toInt256()
            : entryValue.toInt256() - currentValue.toInt256();
    }

    /// weightedAverageEntryPrice = Σ(indexSizeUSD * entryPrice) / Σ(IndexSizesUSD)
    /// @dev Calculates the Next WAEP after a delta in a position
    function calculateWeightedAverageEntryPrice(
        uint256 _prevWAEP, // PREV WEIGHTED AVG ENTRY PRICE
        uint256 _prevSISU, // Σ INDEX SIZE USD
        int256 _sizeDeltaUsd, // Δ SIZE
        uint256 _price
    ) external pure returns (uint256 weightedAvgEntryPrice) {
        if (_prevWAEP == 0 && _prevSISU == 0) {
            return _price;
        }

        UD60x18 prevWAEP = ud(_prevWAEP);
        UD60x18 prevSISU = ud(_prevSISU);
        UD60x18 sizeDeltaUsd = ud(_sizeDeltaUsd.abs());
        UD60x18 price = ud(_price);

        UD60x18 newWAEP;

        if (_sizeDeltaUsd > 0) {
            newWAEP = (prevWAEP.mul(prevSISU).add(sizeDeltaUsd.mul(price))).div(prevSISU.add(sizeDeltaUsd));
        } else {
            newWAEP = (prevWAEP.mul(prevSISU).sub(sizeDeltaUsd.mul(price))).div(prevSISU.sub(sizeDeltaUsd));
        }

        return unwrap(newWAEP);
    }

    /// @dev Positive for profit, negative for loss. Returns PNL in USD
    function getPnl(Market _market, uint256 _indexPrice, uint256 _indexBaseUnit, bool _isLong)
        public
        view
        returns (int256 netPnl)
    {
        // Get OI in USD
        if (_isLong) {
            // get index value
            uint256 indexValue = MarketUtils.getLongOpenInterestUSD(_market, _indexPrice, _indexBaseUnit);
            // get entry value
            uint256 entryValue = MarketUtils.getTotalEntryValueUSD(_market, _indexBaseUnit, _isLong);
            // return index value - entry value
            netPnl = indexValue.toInt256() - entryValue.toInt256();
        } else {
            // get entry value
            uint256 entryValue = MarketUtils.getTotalEntryValueUSD(_market, _indexBaseUnit, _isLong);
            // get index value
            uint256 indexValue = MarketUtils.getShortOpenInterestUSD(_market, _indexPrice, _indexBaseUnit);
            // return entry value - index value
            netPnl = entryValue.toInt256() - indexValue.toInt256();
        }
    }

    function getNetPnl(Market _market, uint256 _indexPrice, uint256 _indexBaseUnit) external view returns (int256) {
        int256 longPnl = getPnl(_market, _indexPrice, _indexBaseUnit, true);
        int256 shortPnl = getPnl(_market, _indexPrice, _indexBaseUnit, false);
        return longPnl + shortPnl;
    }

    /// RealisedPNL=(Current price − Weighted average entry price)×(Realised position size/Current price)
    /// int256 pnl = int256(amountToRealise * currentTokenPrice) - int256(amountToRealise * userPos.entryPriceWeighted);
    /// @dev Returns fractional PNL in USD
    function getDecreasePositionPnl(
        uint256 _indexBaseUnit,
        uint256 _sizeDelta,
        uint256 _positionWAEP,
        uint256 _currentPrice,
        bool _isLong
    ) external pure returns (int256 decreasePositionPnl) {
        // only realise a percentage equivalent to the percentage of the position being closed
        uint256 entryValue = mulDiv(_sizeDelta, _positionWAEP, _indexBaseUnit);
        uint256 exitValue = mulDiv(_sizeDelta, _currentPrice, _indexBaseUnit);
        // if long, > 0 is profit, < 0 is loss
        // if short, > 0 is loss, < 0 is profit
        if (_isLong) {
            decreasePositionPnl = exitValue.toInt256() - entryValue.toInt256();
        } else {
            decreasePositionPnl = entryValue.toInt256() - exitValue.toInt256();
        }
    }
}
