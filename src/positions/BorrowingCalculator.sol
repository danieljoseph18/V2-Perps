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
import {IMarket} from "../markets/interfaces/IMarket.sol";

// library responsible for handling all borrowing calculations
library BorrowingCalculator {
    uint256 public constant PRECISION = 1e18;

    /// @dev Gets the Total Fee To Charge For a Position Change in Tokens
    function calculateBorrowingFee(address _market, MarketStructs.Position memory _position, uint256 _collateralDelta)
        external
        view
        returns (uint256)
    {
        return (getBorrowingFees(_market, _position) * _collateralDelta) / _position.collateralAmount;
    }

    /// @dev Gets Total Fees Owed By a Position in Tokens
    function getBorrowingFees(address _market, MarketStructs.Position memory _position) public view returns (uint256) {
        uint256 feeSinceUpdate = getFeesSinceLastPositionUpdate(_market, _position);
        return feeSinceUpdate + _position.borrowParams.feesOwed;
    }

    /// @dev Gets Fees Owed Since the Last Time a Position Was Updated
    /// @dev Units: Fees in Tokens (% of fees applied to position size)
    function getFeesSinceLastPositionUpdate(address _market, MarketStructs.Position memory _position)
        public
        view
        returns (uint256 feesOwed)
    {
        // get cumulative funding fees since last update
        uint256 borrowFee = _position.isLong
            ? IMarket(_market).longCumulativeBorrowFee() - _position.borrowParams.lastLongCumulativeBorrowFee
            : IMarket(_market).shortCumulativeBorrowFee() - _position.borrowParams.lastShortCumulativeBorrowFee;
        borrowFee += _calculatePendingFees(_market, _position.isLong);
        if (borrowFee == 0) {
            feesOwed = 0;
        } else {
            feesOwed = (_position.positionSize * borrowFee) / PRECISION;
        }
    }

    /// @dev Units: Fees as a percentage (e.g 0.03e18 = 3%)
    function _calculatePendingFees(address _market, bool _isLong) internal view returns (uint256) {
        uint256 borrowRate = _isLong ? IMarket(_market).longBorrowingRate() : IMarket(_market).shortBorrowingRate();
        if (borrowRate == 0) return 0;
        uint256 timeElapsed = block.timestamp - IMarket(_market).lastBorrowUpdateTime();
        if (timeElapsed == 0) return 0;
        return borrowRate * timeElapsed;
    }
}
