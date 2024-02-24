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
import {Position} from "../positions/Position.sol";
import {MarketUtils} from "../markets/MarketUtils.sol";
import {ud, UD60x18, unwrap} from "@prb/math/UD60x18.sol";
import {mulDiv} from "@prb/math/Common.sol";
import {ILiquidityVault} from "../liquidity/interfaces/ILiquidityVault.sol";
import {Pricing} from "./Pricing.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {Order} from "../positions/Order.sol";

/// @dev Library responsible for handling Borrowing related Calculations
library Borrowing {
    using SafeCast for int256;
    using SignedMath for int256;

    uint256 private constant PRECISION = 1e18;
    uint256 private constant MAX_FEE_PERCENTAGE = 0.33e18;

    struct BorrowingCache {
        IMarket.BorrowingConfig config;
        UD60x18 openInterestUsd;
        UD60x18 poolBalance;
        UD60x18 adjustedOiExponent;
        UD60x18 borrowingFactor;
        int256 pendingPnl;
    }

    /**
     * Borrowing Fees are paid from open positions to liquidity providers in exchange
     * for reserving liquidity for their position.
     *
     * Long Fee Calculation: borrowing factor * (open interest in usd + pending pnl) ^ (borrowing exponent factor) / (pool usd)
     * Short Fee Calculation: borrowing factor * (open interest in usd) ^ (borrowing exponent factor) / (pool usd)
     */
    function calculateRate(
        IMarket market,
        ILiquidityVault liquidityVault,
        uint256 _indexPrice,
        uint256 _indexBaseUnit,
        uint256 _longTokenPrice,
        uint256 _shortTokenPrice,
        uint256 _longTokenBaseUnit,
        uint256 _shortTokenBaseUnit,
        bool _isLong
    ) external view returns (uint256 rate) {
        BorrowingCache memory cache;
        // Calculate the new Borrowing Rate
        cache.config = market.getBorrowingConfig();
        cache.openInterestUsd = ud(MarketUtils.getTotalOpenInterestUsd(market, _indexPrice, _indexBaseUnit));
        cache.poolBalance = ud(
            MarketUtils.getTotalPoolBalanceUsd(
                market, liquidityVault, _longTokenPrice, _shortTokenPrice, _longTokenBaseUnit, _shortTokenBaseUnit
            )
        );

        cache.borrowingFactor = ud(cache.config.factor);
        if (_isLong) {
            cache.pendingPnl = Pricing.getPnl(market, _indexPrice, _indexBaseUnit, true);
            // Adjust the OI by the Pending PNL
            if (cache.pendingPnl > 0) {
                cache.openInterestUsd = cache.openInterestUsd.add(ud(cache.pendingPnl.toUint256()));
            } else if (cache.pendingPnl < 0) {
                cache.openInterestUsd = cache.openInterestUsd.sub(ud(cache.pendingPnl.abs()));
            }
            cache.adjustedOiExponent = cache.openInterestUsd.powu(cache.config.exponent);
        } else {
            cache.adjustedOiExponent = cache.openInterestUsd.powu(cache.config.exponent);
        }

        rate = unwrap(cache.borrowingFactor.mul(cache.adjustedOiExponent).div(cache.poolBalance));
    }

    function calculateFeesSinceUpdate(uint256 _rate, uint256 _lastUpdate) external view returns (uint256 fee) {
        uint256 timeElapsed = block.timestamp - _lastUpdate;
        fee = _rate * timeElapsed;
    }

    function getTotalCollateralFeesOwed(Position.Data calldata _position, Order.ExecuteCache memory _cache)
        public
        view
        returns (uint256 collateralFeesOwed)
    {
        uint256 indexFees = _getTotalPositionFeesOwed(_cache.market, _position);
        uint256 feesUsd = mulDiv(indexFees, _cache.indexPrice, _cache.indexBaseUnit);
        collateralFeesOwed = mulDiv(feesUsd, _cache.collateralBaseUnit, _cache.collateralPrice);
    }

    /// @dev Gets Total Fees Owed By a Position in Tokens
    function _getTotalPositionFeesOwed(IMarket market, Position.Data calldata _position)
        internal
        view
        returns (uint256 indexTotalFeesOwed)
    {
        uint256 feeSinceUpdate = _getFeesSinceLastPositionUpdate(market, _position);
        indexTotalFeesOwed = feeSinceUpdate + _position.borrowingParams.feesOwed;
        uint256 maxPayableFee = mulDiv(_position.positionSize, MAX_FEE_PERCENTAGE, PRECISION);
        if (indexTotalFeesOwed > maxPayableFee) {
            indexTotalFeesOwed = maxPayableFee;
        }
    }

    /// @dev Gets Fees Owed Since the Last Time a Position Was Updated
    /// @dev Units: Fees in Tokens (% of fees applied to position size)
    function _getFeesSinceLastPositionUpdate(IMarket market, Position.Data calldata _position)
        internal
        view
        returns (uint256 indexFeesSinceUpdate)
    {
        // get cumulative borrowing fees since last update
        uint256 borrowFee = _position.isLong
            ? market.longCumulativeBorrowFees() - _position.borrowingParams.lastLongCumulativeBorrowFee
            : market.shortCumulativeBorrowFees() - _position.borrowingParams.lastShortCumulativeBorrowFee;
        borrowFee += _calculatePendingFees(market, _position.isLong);
        if (borrowFee == 0) {
            indexFeesSinceUpdate = 0;
        } else {
            indexFeesSinceUpdate = mulDiv(_position.positionSize, borrowFee, PRECISION);
        }
    }

    /// @dev Units: Fees as a percentage (e.g 0.03e18 = 3%)
    /// @dev Gets fees since last time the cumulative market rate was updated
    function _calculatePendingFees(IMarket market, bool _isLong) internal view returns (uint256 pendingFees) {
        uint256 borrowRate = _isLong ? market.longBorrowingRate() : market.shortBorrowingRate();
        if (borrowRate == 0) return 0;
        uint256 timeElapsed = block.timestamp - market.lastBorrowUpdate();
        if (timeElapsed == 0) return 0;
        pendingFees = borrowRate * timeElapsed;
    }
}
