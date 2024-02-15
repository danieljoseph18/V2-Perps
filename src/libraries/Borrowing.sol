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
import {IPriceFeed} from "../oracle/interfaces/IPriceFeed.sol";
import {ILiquidityVault} from "../liquidity/interfaces/ILiquidityVault.sol";
import {Oracle} from "../oracle/Oracle.sol";

/// @dev Library responsible for handling Borrowing related Calculations
library Borrowing {
    uint256 public constant PRECISION = 1e18;

    struct BorrowingCache {
        IMarket.BorrowingConfig config;
        UD60x18 openInterest;
        UD60x18 poolBalance;
        UD60x18 exponentiatedOI;
        UD60x18 borrowingFactor;
    }

    // @audit - correct use of OI / PB here?
    function calculateRate(
        IMarket market,
        ILiquidityVault liquidityVault,
        IPriceFeed priceFeed,
        uint256 _indexPrice,
        address _indexToken,
        uint256 _longTokenPrice,
        uint256 _shortTokenPrice,
        uint256 _longTokenBaseUnit,
        uint256 _shortTokenBaseUnit
    ) external view returns (uint256 rate) {
        BorrowingCache memory cache;
        // Calculate the new Borrowing Rate
        cache.config = market.getBorrowingConfig();
        cache.openInterest =
            ud(MarketUtils.getTotalOpenInterestUSD(market, _indexPrice, Oracle.getBaseUnit(priceFeed, _indexToken)));
        cache.poolBalance = ud(
            MarketUtils.getTotalPoolBalanceUSD(
                market, liquidityVault, _longTokenPrice, _shortTokenPrice, _longTokenBaseUnit, _shortTokenBaseUnit
            )
        );
        cache.exponentiatedOI = cache.openInterest.powu(cache.config.exponent);
        cache.borrowingFactor = ud(cache.config.factor);
        rate = unwrap(cache.borrowingFactor.mul(cache.exponentiatedOI).div(cache.poolBalance));
    }

    function calculateFeeAddition(uint256 _prevRate, uint256 _lastUpdate) external view returns (uint256 feeAddition) {
        uint256 timeElapsed = block.timestamp - _lastUpdate;
        feeAddition = _prevRate * timeElapsed;
    }

    /// @dev Gets the Total Fee To Charge For a Position Change in Tokens
    function calculateFeeForPositionChange(IMarket market, Position.Data calldata _position, uint256 _collateralDelta)
        external
        view
        returns (uint256 indexFee)
    {
        indexFee = mulDiv(getTotalPositionFeesOwed(market, _position), _collateralDelta, _position.collateralAmount);
    }

    /// @dev Gets Total Fees Owed By a Position in Tokens
    function getTotalPositionFeesOwed(IMarket market, Position.Data calldata _position)
        public
        view
        returns (uint256 indexTotalFeesOwed)
    {
        uint256 feeSinceUpdate = getFeesSinceLastPositionUpdate(market, _position);
        indexTotalFeesOwed = feeSinceUpdate + _position.borrowingParams.feesOwed;
    }

    /// @dev Gets Fees Owed Since the Last Time a Position Was Updated
    /// @dev Units: Fees in Tokens (% of fees applied to position size)
    function getFeesSinceLastPositionUpdate(IMarket market, Position.Data calldata _position)
        public
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
