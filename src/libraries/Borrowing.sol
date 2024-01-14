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

import {IMarketMaker} from "../markets/interfaces/IMarketMaker.sol";
import {Market} from "../structs/Market.sol";
import {Position} from "../structs/Position.sol";

/// @dev Library responsible for handling Borrowing related Calculations
library Borrowing {
    uint256 public constant PRECISION = 1e18;

    /// @dev Gets the Total Fee To Charge For a Position Change in Tokens
    function calculateFeeForPositionChange(
        address _marketMaker,
        Position.Data calldata _position,
        uint256 _collateralDelta
    ) external view returns (uint256 indexFee) {
        indexFee = (getTotalPositionFeesOwed(_marketMaker, _position) * _collateralDelta) / _position.collateralAmount;
    }

    /// @dev Gets Total Fees Owed By a Position in Tokens
    function getTotalPositionFeesOwed(address _marketMaker, Position.Data calldata _position)
        public
        view
        returns (uint256 indexTotalFeesOwed)
    {
        uint256 feeSinceUpdate =
            getFeesSinceLastPositionUpdate(_marketMaker, keccak256(abi.encode(_position.indexToken)), _position);
        indexTotalFeesOwed = feeSinceUpdate + _position.borrowing.feesOwed;
    }

    /// @dev Gets Fees Owed Since the Last Time a Position Was Updated
    /// @dev Units: Fees in Tokens (% of fees applied to position size)
    function getFeesSinceLastPositionUpdate(address _marketMaker, bytes32 _marketKey, Position.Data calldata _position)
        public
        view
        returns (uint256 indexFeesSinceUpdate)
    {
        Market.Data memory market = IMarketMaker(_marketMaker).markets(_marketKey);
        // get cumulative borrowing fees since last update
        uint256 borrowFee = _position.isLong
            ? market.borrowing.longCumulativeBorrowFees - _position.borrowing.lastLongCumulativeBorrowFee
            : market.borrowing.shortCumulativeBorrowFees - _position.borrowing.lastShortCumulativeBorrowFee;
        borrowFee += _calculatePendingFees(_marketMaker, _marketKey, _position.isLong);
        if (borrowFee == 0) {
            indexFeesSinceUpdate = 0;
        } else {
            indexFeesSinceUpdate = (_position.positionSize * borrowFee) / PRECISION;
        }
    }

    /// @dev Units: Fees as a percentage (e.g 0.03e18 = 3%)
    /// @dev Gets fees since last time the cumulative market rate was updated
    function _calculatePendingFees(address _marketMaker, bytes32 _marketKey, bool _isLong)
        internal
        view
        returns (uint256 pendingFees)
    {
        Market.Data memory market = IMarketMaker(_marketMaker).markets(_marketKey);
        uint256 borrowRate =
            _isLong ? market.borrowing.longBorrowingRatePerSecond : market.borrowing.shortBorrowingRatePerSecond;
        if (borrowRate == 0) return 0;
        uint256 timeElapsed = block.timestamp - market.borrowing.lastBorrowUpdateTime;
        if (timeElapsed == 0) return 0;
        pendingFees = borrowRate * timeElapsed;
    }
}
