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
import {Oracle} from "../oracle/Oracle.sol";

/// @dev Library responsible for handling Borrowing related Calculations
library Borrowing {
    uint256 public constant PRECISION = 1e18;

    function calculateRate(
        IMarket _market,
        IPriceFeed _priceFeed,
        uint256 _indexPrice,
        address _indexToken,
        uint256 _longTokenPrice,
        uint256 _shortTokenPrice,
        uint256 _longTokenBaseUnit,
        uint256 _shortTokenBaseUnit
    ) external view returns (uint256 rate) {
        // Calculate the new Borrowing Rate
        UD60x18 openInterest =
            ud(MarketUtils.getTotalOpenInterestUSD(_market, _indexPrice, Oracle.getBaseUnit(_priceFeed, _indexToken)));
        UD60x18 poolBalance = ud(
            MarketUtils.getPoolBalanceUSD(
                _market, _longTokenPrice, _shortTokenPrice, _longTokenBaseUnit, _shortTokenBaseUnit
            )
        );
        UD60x18 exponentiatedOI = openInterest.powu(_market.borrowingExponent());
        UD60x18 borrowingFactor = ud(_market.borrowingFactor());
        rate = unwrap(borrowingFactor.mul(exponentiatedOI).div(poolBalance));
    }

    function calculateFeeAddition(uint256 _prevRate, uint256 _lastUpdate) external view returns (uint256 feeAddition) {
        uint256 timeElapsed = block.timestamp - _lastUpdate;
        feeAddition = _prevRate * timeElapsed;
    }

    /// @dev Gets the Total Fee To Charge For a Position Change in Tokens
    function calculateFeeForPositionChange(IMarket _market, Position.Data calldata _position, uint256 _collateralDelta)
        external
        view
        returns (uint256 indexFee)
    {
        indexFee = mulDiv(getTotalPositionFeesOwed(_market, _position), _collateralDelta, _position.collateralAmount);
    }

    /// @dev Gets Total Fees Owed By a Position in Tokens
    function getTotalPositionFeesOwed(IMarket _market, Position.Data calldata _position)
        public
        view
        returns (uint256 indexTotalFeesOwed)
    {
        uint256 feeSinceUpdate = getFeesSinceLastPositionUpdate(_market, _position);
        indexTotalFeesOwed = feeSinceUpdate + _position.borrowingParams.feesOwed;
    }

    /// @dev Gets Fees Owed Since the Last Time a Position Was Updated
    /// @dev Units: Fees in Tokens (% of fees applied to position size)
    function getFeesSinceLastPositionUpdate(IMarket _market, Position.Data calldata _position)
        public
        view
        returns (uint256 indexFeesSinceUpdate)
    {
        // get cumulative borrowing fees since last update
        uint256 borrowFee = _position.isLong
            ? _market.longCumulativeBorrowFees() - _position.borrowingParams.lastLongCumulativeBorrowFee
            : _market.shortCumulativeBorrowFees() - _position.borrowingParams.lastShortCumulativeBorrowFee;
        borrowFee += _calculatePendingFees(_market, _position.isLong);
        if (borrowFee == 0) {
            indexFeesSinceUpdate = 0;
        } else {
            indexFeesSinceUpdate = mulDiv(_position.positionSize, borrowFee, PRECISION);
        }
    }

    /// @dev Units: Fees as a percentage (e.g 0.03e18 = 3%)
    /// @dev Gets fees since last time the cumulative market rate was updated
    function _calculatePendingFees(IMarket _market, bool _isLong) internal view returns (uint256 pendingFees) {
        uint256 borrowRate = _isLong ? _market.longBorrowingRate() : _market.shortBorrowingRate();
        if (borrowRate == 0) return 0;
        uint256 timeElapsed = block.timestamp - _market.lastBorrowUpdate();
        if (timeElapsed == 0) return 0;
        pendingFees = borrowRate * timeElapsed;
    }
}
