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
import {Pricing} from "./Pricing.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {Order} from "../positions/Order.sol";

/// @dev Library responsible for handling Borrowing related Calculations
library Borrowing {
    using SignedMath for int256;

    uint256 private constant PRECISION = 1e18;

    struct BorrowingState {
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
    // @audit - does the last update time affect this?
    function calculateRate(
        IMarket market,
        address _indexToken,
        uint256 _indexPrice,
        uint256 _indexBaseUnit,
        uint256 _collateralPrice,
        uint256 _collateralBaseUnit,
        bool _isLong
    ) external view returns (uint256 rate) {
        BorrowingState memory state;
        // Calculate the new Borrowing Rate
        state.config = market.getBorrowingConfig(_indexToken);
        state.borrowingFactor = ud(state.config.factor);
        if (_isLong) {
            // get the long open interest
            state.openInterestUsd = ud(MarketUtils.getOpenInterestUsd(market, _indexToken, true));
            // get the long pending pnl
            state.pendingPnl = Pricing.getMarketPnl(market, _indexToken, _indexPrice, _indexBaseUnit, true);
            // get the long pool balance
            state.poolBalance =
                ud(MarketUtils.getPoolBalanceUsd(market, _indexToken, _collateralPrice, _collateralBaseUnit, true));
            // Adjust the OI by the Pending PNL
            if (state.pendingPnl > 0) {
                state.openInterestUsd = state.openInterestUsd.add(ud(uint256(state.pendingPnl)));
            } else if (state.pendingPnl < 0) {
                state.openInterestUsd = state.openInterestUsd.sub(ud(state.pendingPnl.abs()));
            }
            state.adjustedOiExponent = state.openInterestUsd.powu(state.config.exponent);
            // calculate the long rate
            rate = unwrap(state.borrowingFactor.mul(state.adjustedOiExponent).div(state.poolBalance));
        } else {
            // get the short open interest
            state.openInterestUsd = ud(MarketUtils.getOpenInterestUsd(market, _indexToken, false));
            // get the short pool balance
            state.poolBalance =
                ud(MarketUtils.getPoolBalanceUsd(market, _indexToken, _collateralPrice, _collateralBaseUnit, false));
            // calculate the short rate
            state.adjustedOiExponent = state.openInterestUsd.powu(state.config.exponent);
            rate = unwrap(state.borrowingFactor.mul(state.adjustedOiExponent).div(state.poolBalance));
        }
    }

    function calculateFeesSinceUpdate(uint256 _rate, uint256 _lastUpdate) external view returns (uint256 fee) {
        uint256 timeElapsed = block.timestamp - _lastUpdate;
        fee = _rate * timeElapsed;
    }

    function getTotalCollateralFeesOwed(Position.Data calldata _position, Order.ExecutionState memory _state)
        public
        view
        returns (uint256 collateralFeesOwed)
    {
        uint256 feesUsd = _getTotalPositionFeesOwed(_state.market, _position);
        collateralFeesOwed = mulDiv(feesUsd, _state.collateralBaseUnit, _state.collateralPrice);
    }

    /// @dev Gets Total Fees Owed By a Position in Tokens
    function _getTotalPositionFeesOwed(IMarket market, Position.Data calldata _position)
        internal
        view
        returns (uint256 feesOwedUsd)
    {
        uint256 feeSinceUpdate = _getFeesSinceLastPositionUpdate(market, _position);
        feesOwedUsd = feeSinceUpdate + _position.borrowingParams.feesOwed;
    }

    /// @dev Gets Fees Owed Since the Last Time a Position Was Updated
    /// @dev Units: Fees in USD (% of fees applied to position size)
    function _getFeesSinceLastPositionUpdate(IMarket market, Position.Data calldata _position)
        internal
        view
        returns (uint256 feesUsd)
    {
        // get cumulative borrowing fees since last update
        uint256 borrowFee = _position.isLong
            ? market.getCumulativeBorrowFee(_position.indexToken, true)
                - _position.borrowingParams.lastLongCumulativeBorrowFee
            : market.getCumulativeBorrowFee(_position.indexToken, false)
                - _position.borrowingParams.lastShortCumulativeBorrowFee;
        borrowFee += _calculatePendingFees(market, _position.indexToken, _position.isLong);
        if (borrowFee == 0) {
            feesUsd = 0;
        } else {
            feesUsd = mulDiv(_position.positionSize, borrowFee, PRECISION);
        }
    }

    /// @dev Units: Fees as a percentage (e.g 0.03e18 = 3%)
    /// @dev Gets fees since last time the cumulative market rate was updated
    function _calculatePendingFees(IMarket market, address _indexToken, bool _isLong)
        internal
        view
        returns (uint256 pendingFees)
    {
        uint256 borrowRate = market.getBorrowingRate(_indexToken, _isLong);
        if (borrowRate == 0) return 0;
        uint256 timeElapsed = block.timestamp - market.getLastBorrowingUpdate(_indexToken);
        if (timeElapsed == 0) return 0;
        pendingFees = borrowRate * timeElapsed;
    }
}
