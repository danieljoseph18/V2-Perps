// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {MarketStructs} from "../markets/MarketStructs.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";

// library responsible for handling all borrowing calculations
library BorrowingCalculator {
    // Get the borrowing fees owed for a particular position
    function getBorrowingFees(address _market, MarketStructs.Position memory _position) public view returns (uint256) {
        return _position.isLong
            ? IMarket(_market).longCumulativeBorrowFee() - _position.borrowParams.entryLongCumulativeBorrowFee
            : IMarket(_market).shortCumulativeBorrowFee() - _position.borrowParams.entryShortCumulativeBorrowFee;
    }

    function calculateBorrowingFee(address _market, MarketStructs.Position memory _position, uint256 _collateralDelta)
        public
        view
        returns (uint256)
    {
        return _position.isLong
            ? (IMarket(_market).longCumulativeBorrowFee() - _position.borrowParams.entryLongCumulativeBorrowFee)
                * _collateralDelta
            : (IMarket(_market).shortCumulativeBorrowFee() - _position.borrowParams.entryShortCumulativeBorrowFee)
                * _collateralDelta;
    }
}
