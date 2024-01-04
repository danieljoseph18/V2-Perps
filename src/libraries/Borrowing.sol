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

import {Types} from "../libraries/Types.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";

/// @dev Library responsible for handling Borrowing related Calculations
library Borrowing {
    uint256 public constant PRECISION = 1e18;

    /// @dev Gets the Total Fee To Charge For a Position Change in Tokens
    function calculateFeeForPositionChange(address _market, Types.Position calldata _position, uint256 _collateralDelta)
        external
        view
        returns (uint256 feeIndexTokens)
    {
        feeIndexTokens = (getTotalPositionFeesOwed(_market, _position) * _collateralDelta) / _position.collateralAmount;
    }

    /// @dev Gets Total Fees Owed By a Position in Tokens
    function getTotalPositionFeesOwed(address _market, Types.Position calldata _position)
        public
        view
        returns (uint256 totalFeesOwedIndexTokens)
    {
        uint256 feeSinceUpdate = getFeesSinceLastPositionUpdate(_market, _position);
        totalFeesOwedIndexTokens = feeSinceUpdate + _position.borrow.feesOwed;
    }

    /// @dev Gets Fees Owed Since the Last Time a Position Was Updated
    /// @dev Units: Fees in Tokens (% of fees applied to position size)
    function getFeesSinceLastPositionUpdate(address _market, Types.Position calldata _position)
        public
        view
        returns (uint256 feesSinceUpdateIndexTokens)
    {
        // get cumulative borrowing fees since last update
        uint256 borrowFee = _position.isLong
            ? IMarket(_market).longCumulativeBorrowFees() - _position.borrow.lastLongCumulativeBorrowFee
            : IMarket(_market).shortCumulativeBorrowFees() - _position.borrow.lastShortCumulativeBorrowFee;
        borrowFee += _calculatePendingFees(_market, _position.isLong);
        if (borrowFee == 0) {
            feesSinceUpdateIndexTokens = 0;
        } else {
            feesSinceUpdateIndexTokens = (_position.positionSize * borrowFee) / PRECISION;
        }
    }

    /// @dev Units: Fees as a percentage (e.g 0.03e18 = 3%)
    /// @dev Gets fees since last time the cumulative market rate was updated
    function _calculatePendingFees(address _market, bool _isLong) internal view returns (uint256 pendingFees) {
        uint256 borrowRate = _isLong ? IMarket(_market).longBorrowingRate() : IMarket(_market).shortBorrowingRate();
        if (borrowRate == 0) return 0;
        uint256 timeElapsed = block.timestamp - IMarket(_market).lastBorrowUpdateTime();
        if (timeElapsed == 0) return 0;
        pendingFees = borrowRate * timeElapsed;
    }
}
