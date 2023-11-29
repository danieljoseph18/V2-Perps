// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {MarketStructs} from "../markets/MarketStructs.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";

// library responsible for handling all borrowing calculations
library BorrowingCalculator {
    /// @dev Gets the Total Fee For a Position Change
    function calculateBorrowingFee(address _market, MarketStructs.Position memory _position, uint256 _collateralDelta)
        external
        view
        returns (uint256)
    {
        // get % deduction of position size
        uint256 divisor = _position.collateralAmount / _collateralDelta;
        // divide total borrowing fees by % deduction
        return getBorrowingFees(_market, _position) / divisor;
    }
    /// @dev Gets Total Fees Owed By a Position

    function getBorrowingFees(address _market, MarketStructs.Position memory _position) public view returns (uint256) {
        uint256 feeSinceUpdate = getFeesSinceLastPositionUpdate(_market, _position);
        return feeSinceUpdate + _position.borrowParams.feesOwed;
    }

    function getFeesSinceLastPositionUpdate(address _market, MarketStructs.Position memory _position)
        public
        view
        returns (uint256 feesOwed)
    {
        // get cumulative funding fees since last update
        uint256 borrowFee = _position.isLong
            ? IMarket(_market).longCumulativeBorrowFee() - _position.borrowParams.lastLongCumulativeBorrowFee
            : IMarket(_market).shortCumulativeBorrowFee() - _position.borrowParams.lastShortCumulativeBorrowFee;

        feesOwed = _position.positionSize / (1e18 / borrowFee);
    }
}
