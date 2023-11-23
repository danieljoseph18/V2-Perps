// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {MarketStructs} from "../markets/MarketStructs.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";

// library responsible for handling all borrowing calculations
library BorrowingCalculator {
    /// @dev Gets the Fee Per Token
    function getBorrowingFees(address _market, MarketStructs.Position memory _position)
        external
        view
        returns (uint256)
    {
        return _position.isLong
            ? IMarket(_market).longCumulativeBorrowFee() - _position.borrowParams.entryLongCumulativeBorrowFee
            : IMarket(_market).shortCumulativeBorrowFee() - _position.borrowParams.entryShortCumulativeBorrowFee;
    }

    /// @dev Gets the Total Fee For a Position Change
    function calculateBorrowingFee(address _market, MarketStructs.Position memory _position, uint256 _collateralDelta)
        external
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
