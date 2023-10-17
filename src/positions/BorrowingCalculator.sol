// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {MarketStructs} from "../markets/MarketStructs.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMarketStorage} from "../markets/interfaces/IMarketStorage.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {SD59x18, sd, unwrap, pow} from "@prb/math/SD59x18.sol";
import {UD60x18, ud, unwrap} from "@prb/math/UD60x18.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

// library responsible for handling all borrowing calculations
library BorrowingCalculator {
    using SafeCast for uint256;
    using SafeCast for int256;

    // Get the borrowing fees owed for a particular position
    function getBorrowingFees(address _market, MarketStructs.Position memory _position) public view returns (uint256) {
        return _position.isLong
            ? IMarket(_market).longCumulativeBorrowFee() - _position.borrowParams.entryLongCumulativeBorrowFee
            : IMarket(_market).shortCumulativeBorrowFee() - _position.borrowParams.entryShortCumulativeBorrowFee;
    }

    function calculateBorrowingFee(address _market, MarketStructs.Position memory _position, uint256 _collateralDelta) public view returns (uint256) {
        return _position.isLong
            ? (IMarket(_market).longCumulativeBorrowFee() - _position.borrowParams.entryLongCumulativeBorrowFee) * _collateralDelta
            : (IMarket(_market).shortCumulativeBorrowFee() - _position.borrowParams.entryShortCumulativeBorrowFee) * _collateralDelta;
    }
}
