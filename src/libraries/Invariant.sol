// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {Position} from "../positions/Position.sol";

library Invariant {
    function validateCollateralEdit(
        Position.Data memory _positionBefore,
        Position.Data memory _positionAfter,
        uint256 _collateralDelta,
        uint256 _tradingFee,
        uint256 _borrowFee,
        bool _isIncrease
    ) public pure {
        // ensure the position collateral has changed by the correct amount
        uint256 expectedCollateralDelta = _collateralDelta - _tradingFee - _borrowFee;
        if (_isIncrease) {
            require(
                _positionAfter.collateralAmount == _positionBefore.collateralAmount + expectedCollateralDelta,
                "Invariant: Collateral Delta"
            );
        } else {
            require(
                _positionAfter.collateralAmount == _positionBefore.collateralAmount - expectedCollateralDelta,
                "Invariant: Collateral Delta"
            );
        }
        // hash the other variables from before and after, then compare them to ensure nothing else has changed
        bytes32 sigBefore = keccak256(
            abi.encode(
                _positionBefore.collateralToken,
                _positionBefore.positionSize,
                _positionBefore.weightedAvgEntryPrice,
                _positionBefore.lastUpdate,
                _positionBefore.lastFundingAccrued,
                _positionBefore.isLong,
                _positionBefore.stopLossKey,
                _positionBefore.takeProfitKey
            )
        );
        bytes32 sigAfter = keccak256(
            abi.encode(
                _positionAfter.collateralToken,
                _positionAfter.positionSize,
                _positionAfter.weightedAvgEntryPrice,
                _positionAfter.lastUpdate,
                _positionAfter.lastFundingAccrued,
                _positionAfter.isLong,
                _positionAfter.stopLossKey,
                _positionAfter.takeProfitKey
            )
        );

        require(sigBefore == sigAfter, "Invariant: Invalid Collateral Delta");
    }
}
