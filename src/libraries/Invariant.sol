// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {Position} from "../positions/Position.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {console, console2} from "forge-std/Test.sol";

library Invariant {
    using SignedMath for int256;

    function validateCollateralIncrease(
        Position.Data memory _positionBefore,
        Position.Data memory _positionAfter,
        uint256 _collateralDelta,
        uint256 _positionFee,
        uint256 _borrowFee,
        uint256 _affiliateRebate
    ) external view {
        // ensure the position collateral has changed by the correct amount
        uint256 expectedCollateralDelta = _collateralDelta - _positionFee - _borrowFee - _affiliateRebate;
        console.log("Trading Fee: ", _positionFee);
        console.log("Rebate: ", _affiliateRebate);
        console.log("expectedCollateralDelta: ", expectedCollateralDelta);
        console.log("Collateral Amount After: ", _positionAfter.collateralAmount);
        console.log("Collateral Amount Before: ", _positionBefore.collateralAmount);
        require(
            _positionAfter.collateralAmount == _positionBefore.collateralAmount + expectedCollateralDelta,
            "Invariant: Collateral Delta"
        );

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

        require(sigBefore == sigAfter, "Invariant: Invalid Collateral Edit");
    }

    function validateCollateralDecrease(
        Position.Data memory _positionBefore,
        Position.Data memory _positionAfter,
        uint256 _collateralDelta,
        uint256 _positionFee, // trading fee not charged on collateral delta
        uint256 _borrowFee,
        uint256 _affiliateRebate
    ) external view {
        // ensure the position collateral has changed by the correct amount
        uint256 expectedCollateralDelta = _collateralDelta + _positionFee + _borrowFee + _affiliateRebate;
        console.log("Trading Fee: ", _positionFee);
        console.log("Borrow Fee: ", _borrowFee);
        console.log("Rebate: ", _affiliateRebate);
        console.log("expectedCollateralDelta: ", expectedCollateralDelta);
        console.log("Collateral Amount After: ", _positionAfter.collateralAmount);
        console.log("Collateral Amount Before: ", _positionBefore.collateralAmount);
        require(
            _positionAfter.collateralAmount == _positionBefore.collateralAmount - expectedCollateralDelta,
            "Invariant: Collateral Delta"
        );

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

        require(sigBefore == sigAfter, "Invariant: Invalid Collateral Edit");
    }

    function validateNewPosition(
        uint256 _collateralIn,
        uint256 _positionCollateral,
        uint256 _positionFee,
        uint256 _affiliateRebate
    ) external view {
        console.log("collateralIn: ", _collateralIn);
        console.log("positionCollateral: ", _positionCollateral);
        console.log("tradingFee: ", _positionFee);
        console.log("feeDiscount: ", _affiliateRebate);
        require(_collateralIn == _positionCollateral + _positionFee + _affiliateRebate, "Invariant: New Position");
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
    ) external view {
        uint256 expectedCollateralDelta = _collateralIn - _positionFee - _affiliateRebate - _borrowFee;
        if (_fundingFee < 0) {
            expectedCollateralDelta -= _fundingFee.abs();
        } else {
            expectedCollateralDelta += _fundingFee.abs();
        }
        console.log("Collateral In: ", _collateralIn);
        console.log("Position Fee: ", _positionFee);
        console.log("Rebate: ", _affiliateRebate);
        console2.log("Funding Fee: ", _fundingFee);
        console.log("Borrow Fee: ", _borrowFee);
        console.log("Expected Collateral Delta: ", expectedCollateralDelta);
        console.log("Collateral Amount After: ", _positionAfter.collateralAmount);
        console.log("Collateral Amount Before: ", _positionBefore.collateralAmount);
        require(
            _positionAfter.collateralAmount == _positionBefore.collateralAmount + expectedCollateralDelta,
            "Invariant: Increase Position Collateral"
        );
        require(
            _positionAfter.positionSize == _positionBefore.positionSize + _sizeDelta,
            "Invariant: Increase Position Size"
        );
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
        require(sigBefore == sigAfter, "Invariant: Invalid Increase Position");
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
    ) external view {
        // Amount out should = collateralDelta +- pnl += fundingFee - borrow fee - trading fee
        /**
         * collat before should = collat after + collateralDelta + fees + pnl
         * feeDiscount / 2, as 1/2 is rebate to referrer
         */
        uint256 expectedCollateralDelta = _collateralOut + _positionFee + _affiliateRebate + _borrowFee;
        // Account for funding / pnl paid out from collateral
        if (_pnl < 0) expectedCollateralDelta += _pnl.abs();

        require(
            _positionBefore.collateralAmount == _positionAfter.collateralAmount + expectedCollateralDelta,
            "Invariant: Decrease Position Collateral"
        );
        console.log("Position Size Before: ", _positionBefore.positionSize);
        console.log("Position Size After: ", _positionAfter.positionSize);
        console.log("Size Delta: ", _sizeDelta);
        // @audit - need to account for price impact??
        require(
            _positionBefore.positionSize == _positionAfter.positionSize + _sizeDelta,
            "Invariant: Decrease Position Size"
        );
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
        require(sigBefore == sigAfter, "Invariant: Invalid Decrease Position");
    }
}
