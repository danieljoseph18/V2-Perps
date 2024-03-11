// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {Position} from "../positions/Position.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";

library Invariant {
    using SignedMath for int256;

    error Invariant_CollateralDelta();
    error Invariant_InvalidCollateralIncrease();
    error Invariant_InvalidCollateralDecrease();
    error Invariant_NewPosition();
    error Invariant_IncreasePositionCollateral();
    error Invariant_IncreasePositionSize();
    error Invariant_InvalidIncreasePosition();
    error Invariant_DecreasePositionCollateral();
    error Invariant_DecreasePositionSize();
    error Invariant_InvalidDecreasePosition();

    function validateCollateralIncrease(
        Position.Data memory _positionBefore,
        Position.Data memory _positionAfter,
        uint256 _collateralDelta,
        uint256 _positionFee,
        uint256 _borrowFee,
        uint256 _affiliateRebate
    ) external pure {
        // ensure the position collateral has changed by the correct amount
        uint256 expectedCollateralDelta = _collateralDelta - _positionFee - _borrowFee - _affiliateRebate;
        if (_positionAfter.collateralAmount != _positionBefore.collateralAmount + expectedCollateralDelta) {
            revert Invariant_CollateralDelta();
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

        if (sigBefore != sigAfter) {
            revert Invariant_InvalidCollateralIncrease();
        }
    }

    function validateCollateralDecrease(
        Position.Data memory _positionBefore,
        Position.Data memory _positionAfter,
        uint256 _collateralDelta,
        uint256 _positionFee, // trading fee not charged on collateral delta
        uint256 _borrowFee,
        uint256 _affiliateRebate
    ) external pure {
        // ensure the position collateral has changed by the correct amount
        uint256 expectedCollateralDelta = _collateralDelta + _positionFee + _borrowFee + _affiliateRebate;
        if (_positionAfter.collateralAmount != _positionBefore.collateralAmount - expectedCollateralDelta) {
            revert Invariant_CollateralDelta();
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

        if (sigBefore != sigAfter) {
            revert Invariant_InvalidCollateralDecrease();
        }
    }

    function validateNewPosition(
        uint256 _collateralIn,
        uint256 _positionCollateral,
        uint256 _positionFee,
        uint256 _affiliateRebate
    ) external pure {
        if (_collateralIn != _positionCollateral + _positionFee + _affiliateRebate) {
            revert Invariant_NewPosition();
        }
    }

    function validateIncreasePosition(
        Position.Data memory _positionBefore,
        Position.Data memory _positionAfter,
        uint256 _collateralIn,
        uint256 _positionFee,
        uint256 _affiliateRebate,
        int256 _fundingFee,
        uint256 _borrowFee,
        uint256 _sizeDelta
    ) external pure {
        uint256 expectedCollateralDelta = _collateralIn - _positionFee - _affiliateRebate - _borrowFee;
        if (_fundingFee < 0) {
            expectedCollateralDelta -= _fundingFee.abs();
        } else {
            expectedCollateralDelta += _fundingFee.abs();
        }
        if (_positionAfter.collateralAmount != _positionBefore.collateralAmount + expectedCollateralDelta) {
            revert Invariant_IncreasePositionCollateral();
        }
        if (_positionAfter.positionSize != _positionBefore.positionSize + _sizeDelta) {
            revert Invariant_IncreasePositionSize();
        }
        // Validate the variables that shouldn't have changed, haven't
        bytes32 sigBefore;
        {
            sigBefore = keccak256(
                abi.encode(
                    _positionBefore.market,
                    _positionBefore.indexToken,
                    _positionBefore.user,
                    _positionBefore.collateralToken,
                    _positionBefore.isLong,
                    _positionBefore.stopLossKey,
                    _positionBefore.takeProfitKey
                )
            );
        }
        bytes32 sigAfter;
        {
            sigAfter = keccak256(
                abi.encode(
                    _positionAfter.market,
                    _positionAfter.indexToken,
                    _positionAfter.user,
                    _positionAfter.collateralToken,
                    _positionAfter.isLong,
                    _positionAfter.stopLossKey,
                    _positionAfter.takeProfitKey
                )
            );
        }
        if (sigBefore != sigAfter) {
            revert Invariant_InvalidIncreasePosition();
        }
    }

    function validateDecreasePosition(
        Position.Data memory _positionBefore,
        Position.Data memory _positionAfter,
        uint256 _collateralOut,
        uint256 _positionFee,
        uint256 _affiliateRebate,
        int256 _pnl,
        uint256 _borrowFee,
        uint256 _sizeDelta
    ) external pure {
        // Amount out should = collateralDelta +- pnl += fundingFee - borrow fee - trading fee
        /**
         * collat before should = collat after + collateralDelta + fees + pnl
         * feeDiscount / 2, as 1/2 is rebate to referrer
         */
        uint256 expectedCollateralDelta = _collateralOut + _positionFee + _affiliateRebate + _borrowFee;
        // Account for funding / pnl paid out from collateral
        if (_pnl < 0) expectedCollateralDelta += _pnl.abs();

        if (_positionBefore.collateralAmount != _positionAfter.collateralAmount + expectedCollateralDelta) {
            revert Invariant_DecreasePositionCollateral();
        }
        // @audit - need to account for price impact??
        if (_positionBefore.positionSize != _positionAfter.positionSize + _sizeDelta) {
            revert Invariant_DecreasePositionSize();
        }
        // Validate the variables that shouldn't have changed, haven't
        bytes32 sigBefore;
        {
            sigBefore = keccak256(
                abi.encode(
                    _positionBefore.market,
                    _positionBefore.indexToken,
                    _positionBefore.user,
                    _positionBefore.collateralToken,
                    _positionBefore.isLong,
                    _positionBefore.stopLossKey,
                    _positionBefore.takeProfitKey
                )
            );
        }
        bytes32 sigAfter;
        {
            sigAfter = keccak256(
                abi.encode(
                    _positionAfter.market,
                    _positionAfter.indexToken,
                    _positionAfter.user,
                    _positionAfter.collateralToken,
                    _positionAfter.isLong,
                    _positionAfter.stopLossKey,
                    _positionAfter.takeProfitKey
                )
            );
        }
        if (sigBefore != sigAfter) {
            revert Invariant_InvalidDecreasePosition();
        }
    }
}
