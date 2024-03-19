// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Position} from "../positions/Position.sol";
import {IMarket, IVault} from "../markets/interfaces/IMarket.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {mulDiv, mulDivSigned} from "@prb/math/Common.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {console} from "forge-std/Test.sol";

library Invariant {
    using SignedMath for int256;
    using SafeCast for uint256;

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
    error Invariant_MarketConfigChanged();
    error Invariant_FundingTimestamp();
    error Invariant_FundingRate();
    error Invariant_FundingAccrual();
    error Invariant_BorrowingTimestamp();
    error Invariant_BorrowDelta();
    error Invariant_BorrowRateDelta();
    error Invariant_CumulativeBorrowDelta();
    error Invariant_OpenInterestDelta();
    error Invariant_DepositFee();
    error Invariant_DepositAmountIn();
    error Invariant_DepositAccounting();
    error Invariant_TokenBurnFailed();

    uint256 constant SCALAR = 1e18;

    function validateDeposit(
        IVault.State calldata _stateBefore,
        IVault.State calldata _stateAfter,
        IVault.Deposit calldata _deposit,
        uint256 _feeScale
    ) external pure {
        uint256 minFee = mulDiv(_deposit.amountIn, 0.001e18, SCALAR);
        uint256 maxFee = mulDiv(_deposit.amountIn, 0.001e18 + _feeScale, SCALAR);
        if (_deposit.isLongToken) {
            if (_stateAfter.longAccumulatedFees < _stateBefore.longAccumulatedFees + minFee) {
                revert Invariant_DepositFee();
            }

            if (_stateAfter.longAccumulatedFees > _stateBefore.longAccumulatedFees + maxFee) {
                revert Invariant_DepositFee();
            }
            // Long Pool Balance should increase by a minimum of (amount in - max fee) and a maximum of (amount in - min fee)
            if (
                _stateAfter.longPoolBalance < _stateBefore.longPoolBalance + _deposit.amountIn - maxFee
                    || _stateAfter.longPoolBalance > _stateBefore.longPoolBalance + _deposit.amountIn - minFee
            ) {
                revert Invariant_DepositAccounting();
            }
            // Market's WETH Balance should increase by AmountIn
            if (_stateAfter.wethBalance != _stateBefore.wethBalance + _deposit.amountIn) {
                revert Invariant_DepositAmountIn();
            }
        } else {
            if (_stateAfter.shortAccumulatedFees < _stateBefore.shortAccumulatedFees + minFee) {
                revert Invariant_DepositFee();
            }
            if (_stateAfter.shortAccumulatedFees > _stateBefore.shortAccumulatedFees + maxFee) {
                revert Invariant_DepositFee();
            }
            // Short Pool Balance should increase by a minimum of (amount in - max fee) and a maximum of (amount in - min fee)
            if (
                _stateAfter.shortPoolBalance < _stateBefore.shortPoolBalance + _deposit.amountIn - maxFee
                    || _stateAfter.shortPoolBalance > _stateBefore.shortPoolBalance + _deposit.amountIn - minFee
            ) {
                revert Invariant_DepositAccounting();
            }
            // Market's USDC Balance should increase by AmountIn
            if (_stateAfter.usdcBalance != _stateBefore.usdcBalance + _deposit.amountIn) {
                revert Invariant_DepositAmountIn();
            }
        }
    }

    /**
     * - Total Supply should decrease by the market token amount in
     * - The Fee should increase within S.D of the max fee
     * - The pool balance should decrease by the amount out
     * - The vault balance should decrease by the amount out
     */
    function validateWithdrawal(
        IVault.State calldata _stateBefore,
        IVault.State calldata _stateAfter,
        IVault.Withdrawal calldata _withdrawal,
        uint256 _amountOut,
        uint256 _feeScale
    ) external pure {
        uint256 minFee = mulDiv(_amountOut, 0.001e18, SCALAR);
        uint256 maxFee = mulDiv(_amountOut, 0.001e18 + _feeScale, SCALAR);
        if (_stateBefore.totalSupply != _stateAfter.totalSupply + _withdrawal.marketTokenAmountIn) {
            revert Invariant_TokenBurnFailed();
        }
        if (_withdrawal.isLongToken) {
            if (
                _stateAfter.longAccumulatedFees < _stateBefore.longAccumulatedFees + minFee
                    || _stateAfter.longAccumulatedFees > _stateBefore.longAccumulatedFees + maxFee
            ) {
                revert Invariant_DepositFee();
            }
            if (_stateAfter.longPoolBalance != _stateBefore.longPoolBalance - _amountOut) {
                revert Invariant_DepositAccounting();
            }
            // WETH Balance should decrease by (AmountOut - Fee)
            // WETH balance after is between (Before - AmountOut + MinFee) and (Before - AmountOut + MaxFee)
            if (
                _stateAfter.wethBalance < _stateBefore.wethBalance - _amountOut + minFee
                    || _stateAfter.wethBalance > _stateBefore.wethBalance - _amountOut + maxFee
            ) {
                revert Invariant_DepositAmountIn();
            }
        } else {
            if (
                _stateAfter.shortAccumulatedFees < _stateBefore.shortAccumulatedFees + minFee
                    || _stateAfter.shortAccumulatedFees > _stateBefore.shortAccumulatedFees + maxFee
            ) {
                revert Invariant_DepositFee();
            }
            if (_stateAfter.shortPoolBalance != _stateBefore.shortPoolBalance - _amountOut) {
                revert Invariant_DepositAccounting();
            }
            // USDC Balance should decrease by (AmountOut - Fee)
            // USDC balance after is between (Before - AmountOut + MinFee) and (Before - AmountOut + MaxFee)
            if (
                _stateAfter.usdcBalance < _stateBefore.usdcBalance - _amountOut + minFee
                    || _stateAfter.usdcBalance > _stateBefore.usdcBalance - _amountOut + maxFee
            ) {
                revert Invariant_DepositAmountIn();
            }
        }
    }

    function validateMarketDeltaPosition(
        IMarket.MarketStorage calldata _prevStorage,
        IMarket.MarketStorage calldata _storage,
        Position.Request calldata _request
    ) external view {
        // Hash Constants and Compare Signatures to ensure no changes
        bytes32 constSigBefore = keccak256(abi.encode(_prevStorage.config, _prevStorage.allocationPercentage));
        bytes32 constSigAfter = keccak256(abi.encode(_storage.config, _storage.allocationPercentage));
        if (constSigBefore != constSigAfter) {
            revert Invariant_MarketConfigChanged();
        }

        _validateFundingValues(_prevStorage.funding, _storage.funding);
        _validateBorrowingValues(
            _prevStorage.borrowing, _storage.borrowing, _request.input.sizeDelta, _request.input.isLong
        );
        _validateOpenInterest(
            _prevStorage.openInterest,
            _storage.openInterest,
            _request.input.sizeDelta,
            _request.input.isLong,
            _request.input.isIncrease
        );
        _validatePnlValues(_prevStorage.pnl, _storage.pnl, _request.input.isLong);
    }

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
                _positionBefore.fundingParams.lastFundingAccrued,
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
                _positionAfter.fundingParams.lastFundingAccrued,
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
                _positionBefore.fundingParams.lastFundingAccrued,
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
                _positionAfter.fundingParams.lastFundingAccrued,
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
        uint256 _borrowFee,
        uint256 _sizeDelta
    ) external pure {
        uint256 expectedCollateralDelta = _collateralIn - _positionFee - _affiliateRebate - _borrowFee;
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
                    _positionBefore.assetId,
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
                    _positionAfter.assetId,
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

        if (_positionBefore.positionSize != _positionAfter.positionSize + _sizeDelta) {
            revert Invariant_DecreasePositionSize();
        }
        // Validate the variables that shouldn't have changed, haven't
        bytes32 sigBefore;
        {
            sigBefore = keccak256(
                abi.encode(
                    _positionBefore.market,
                    _positionBefore.assetId,
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
                    _positionAfter.assetId,
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

    /**
     * ============ Internal Helper Functions ============
     */
    function _validateFundingValues(
        IMarket.FundingValues calldata _prevFunding,
        IMarket.FundingValues calldata _funding
    ) internal view {
        // Funding Rate should update to current block timestamp
        if (_funding.lastFundingUpdate != block.timestamp) {
            revert Invariant_FundingTimestamp();
        }
        // If Funding Rate Velocity was non 0, funding rate should change
        if (_prevFunding.fundingRateVelocity != 0) {
            int256 timeElapsed = (block.timestamp - _prevFunding.lastFundingUpdate).toInt256();
            // currentFundingRate = prevRate + velocity * (timeElapsetd / 1 days)
            int256 expectedRate =
                _prevFunding.fundingRate + mulDivSigned(_prevFunding.fundingRateVelocity, timeElapsed, 1 days);
            if (expectedRate != _funding.fundingRate) {
                revert Invariant_FundingRate();
            }
        }
        // If Funding Rate was non 0, accrued USD should change
        if (_prevFunding.fundingRate != 0 && _prevFunding.fundingAccruedUsd == _funding.fundingAccruedUsd) {
            revert Invariant_FundingAccrual();
        }
    }

    function _validateBorrowingValues(
        IMarket.BorrowingValues calldata _prevBorrowing,
        IMarket.BorrowingValues calldata _borrowing,
        uint256 _sizeDelta,
        bool _isLong
    ) internal view {
        // Borrowing Rate should update to current block timestamp
        if (_borrowing.lastBorrowUpdate != block.timestamp) {
            revert Invariant_BorrowingTimestamp();
        }
        if (_isLong) {
            // Signature of opposite side should remain constant
            bytes32 sigBefore =
                keccak256(abi.encode(_prevBorrowing.shortBorrowingRate, _prevBorrowing.shortCumulativeBorrowFees));
            bytes32 sigAfter =
                keccak256(abi.encode(_borrowing.shortBorrowingRate, _borrowing.shortCumulativeBorrowFees));
            if (sigBefore != sigAfter) {
                revert Invariant_BorrowDelta();
            }
            // If Size Delta != 0 -> Borrow Rate should change due to updated OI
            if (_sizeDelta != 0 && _borrowing.longBorrowingRate == _prevBorrowing.longBorrowingRate) {
                revert Invariant_BorrowRateDelta();
            }
            // If Time elapsed = 0, Cumulative Fees should remain constant
            if (_prevBorrowing.lastBorrowUpdate == block.timestamp) {
                if (_borrowing.longCumulativeBorrowFees != _prevBorrowing.longCumulativeBorrowFees) {
                    revert Invariant_CumulativeBorrowDelta();
                }
            } else {
                // Else should change for side if rate not 0
                if (
                    _borrowing.longCumulativeBorrowFees == _prevBorrowing.longCumulativeBorrowFees
                        && _prevBorrowing.longBorrowingRate != 0
                ) {
                    revert Invariant_CumulativeBorrowDelta();
                }
            }
        } else {
            // Signature of opposite side should remain constant
            bytes32 sigBefore =
                keccak256(abi.encode(_prevBorrowing.longBorrowingRate, _prevBorrowing.longCumulativeBorrowFees));
            bytes32 sigAfter = keccak256(abi.encode(_borrowing.longBorrowingRate, _borrowing.longCumulativeBorrowFees));
            if (sigBefore != sigAfter) {
                revert Invariant_BorrowDelta();
            }
            // If Size Delta != 0 -> Borrow Rate should change due to updated OI
            if (_sizeDelta != 0 && _borrowing.shortBorrowingRate == _prevBorrowing.shortBorrowingRate) {
                revert Invariant_BorrowRateDelta();
            }
            // If Time elapsed = 0, Cumulative Fees should remain constant
            if (_prevBorrowing.lastBorrowUpdate == block.timestamp) {
                if (_borrowing.shortCumulativeBorrowFees != _prevBorrowing.shortCumulativeBorrowFees) {
                    revert Invariant_CumulativeBorrowDelta();
                }
            } else {
                // Else should change for side if rate not 0
                if (
                    _borrowing.shortCumulativeBorrowFees == _prevBorrowing.shortCumulativeBorrowFees
                        && _prevBorrowing.shortBorrowingRate != 0
                ) {
                    revert Invariant_CumulativeBorrowDelta();
                }
            }
        }
    }

    function _validateOpenInterest(
        IMarket.OpenInterestValues calldata _prevOpenInterest,
        IMarket.OpenInterestValues calldata _openInterest,
        uint256 _sizeDelta,
        bool _isLong,
        bool _isIncrease
    ) internal pure {
        if (_isLong) {
            // If increase, long open interest should increase by size delta. Short open interest should be same
            if (_isIncrease) {
                if (_openInterest.longOpenInterest != _prevOpenInterest.longOpenInterest + _sizeDelta) {
                    revert Invariant_OpenInterestDelta();
                }
                if (_openInterest.shortOpenInterest != _prevOpenInterest.shortOpenInterest) {
                    revert Invariant_OpenInterestDelta();
                }
            } else {
                // If decrease, long open interest should decrease by size delta. Short open interest should be same
                if (_openInterest.longOpenInterest != _prevOpenInterest.longOpenInterest - _sizeDelta) {
                    revert Invariant_OpenInterestDelta();
                }
                if (_openInterest.shortOpenInterest != _prevOpenInterest.shortOpenInterest) {
                    revert Invariant_OpenInterestDelta();
                }
            }
        } else {
            // If increase, short open interest should increase by size delta. Long open interest should be same
            if (_isIncrease) {
                if (_openInterest.shortOpenInterest != _prevOpenInterest.shortOpenInterest + _sizeDelta) {
                    revert Invariant_OpenInterestDelta();
                }
                if (_openInterest.longOpenInterest != _prevOpenInterest.longOpenInterest) {
                    revert Invariant_OpenInterestDelta();
                }
            } else {
                // If decrease, short open interest should decrease by size delta. Long open interest should be same
                if (_openInterest.shortOpenInterest != _prevOpenInterest.shortOpenInterest - _sizeDelta) {
                    revert Invariant_OpenInterestDelta();
                }
                if (_openInterest.longOpenInterest != _prevOpenInterest.longOpenInterest) {
                    revert Invariant_OpenInterestDelta();
                }
            }
        }
    }

    function _validatePnlValues(IMarket.PnlValues calldata _prevPnl, IMarket.PnlValues calldata _pnl, bool _isLong)
        internal
        pure
    {
        // WAEP for the Opposite side should never change
        if (_isLong) {
            if (_pnl.shortAverageEntryPriceUsd != _prevPnl.shortAverageEntryPriceUsd) {
                revert Invariant_InvalidIncreasePosition();
            }
        } else {
            if (_pnl.longAverageEntryPriceUsd != _prevPnl.longAverageEntryPriceUsd) {
                revert Invariant_InvalidIncreasePosition();
            }
        }
    }
}
