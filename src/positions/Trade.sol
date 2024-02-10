// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {ITradeStorage} from "./interfaces/ITradeStorage.sol";
import {ILiquidityVault} from "../liquidity/interfaces/ILiquidityVault.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {IMarketMaker} from "../markets/interfaces/IMarketMaker.sol";
import {Position} from "./Position.sol";
import {MarketUtils} from "../markets/MarketUtils.sol";
import {Funding} from "../libraries/Funding.sol";
import {Borrowing} from "../libraries/Borrowing.sol";
import {Pricing} from "../libraries/Pricing.sol";
import {mulDiv} from "@prb/math/Common.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

// Library for Handling Trade related logic
library Trade {
    using SignedMath for int256;
    using SafeCast for uint256;

    uint256 internal constant PRECISION = 1e18;

    struct DecreaseCache {
        uint256 sizeDelta;
        int256 decreasePnl;
        uint256 afterFeeAmount;
        uint256 fundingFee;
        uint256 borrowFee;
    }

    // Cached Values for Execution
    struct ExecuteCache {
        IMarket market;
        uint256 indexPrice;
        uint256 indexBaseUnit;
        uint256 impactedPrice;
        uint256 longMarketTokenPrice;
        uint256 shortMarketTokenPrice;
        int256 sizeDeltaUsd;
        uint256 collateralPrice;
        uint256 fee;
        uint256 feeDiscount;
        address referrer;
    }

    //////////////////////////////
    // MAIN EXECUTION FUNCTIONS //
    //////////////////////////////

    function executeCollateralIncrease(
        Position.Data memory _position,
        Position.Execution calldata _params,
        ExecuteCache memory _cache
    ) external view returns (Position.Data memory) {
        // Update the Fee Parameters
        _position = _updateFeeParameters(_position);
        // Edit the Position for Increase
        _position = _editPosition(_position, _cache, _params.request.input.collateralDelta, 0, true);
        _position = _updateConditionals(_position, _params.request.input.conditionals);
        return _position;
    }

    function executeCollateralDecrease(
        Position.Data memory _position,
        Position.Execution calldata _params,
        ExecuteCache memory _cache,
        uint256 _minCollateralUsd,
        uint256 _liquidationFeeUsd
    ) external view returns (Position.Data memory) {
        // Update the Fee Parameters
        _position = _updateFeeParameters(_position);

        _position.collateralAmount -= _params.request.input.collateralDelta;

        // Check if the Decrease puts the position below the min collateral threshold
        require(
            _checkMinCollateral(_position.collateralAmount, _cache.collateralPrice, _minCollateralUsd), "TS: Min Collat"
        );

        // Check if the Decrease makes the Position Liquidatable
        require(!_checkIsLiquidatable(_position, _cache, _liquidationFeeUsd), "TS: Liquidatable");

        // Update the Position's conditionals
        _position = _updateConditionals(_position, _params.request.input.conditionals);

        // Edit the Position
        return _editPosition(_position, _cache, _params.request.input.collateralDelta, 0, false);
    }

    function executeConditionalEdit(Position.Data memory _position, Position.Execution calldata _params)
        external
        pure
        returns (Position.Data memory)
    {
        // Update the Position's conditionals
        return _updateConditionals(_position, _params.request.input.conditionals);
    }

    function createNewPosition(
        Position.Execution calldata _params,
        ExecuteCache memory _cache,
        uint256 _minCollateralUsd
    ) external view returns (Position.Data memory, uint256 sizeUsd) {
        // Check that the Position meets the minimum collateral threshold
        require(
            _checkMinCollateral(_params.request.input.collateralDelta, _cache.collateralPrice, _minCollateralUsd),
            "TS: Min Collat"
        );
        // Generate the Position
        Position.Data memory position = Position.generateNewPosition(_params.request, _cache);
        // Check the Position's Leverage is Valid
        uint256 absSizeDelta = _cache.sizeDeltaUsd.abs();
        Position.checkLeverage(_cache.collateralPrice, absSizeDelta, position.collateralAmount);
        // Return the Position
        return (position, absSizeDelta);
    }

    function increaseExistingPosition(
        Position.Data memory _position,
        Position.Execution calldata _params,
        ExecuteCache memory _cache
    ) external view returns (Position.Data memory, uint256 sizeDelta, uint256 sizeDeltaUsd) {
        // Update the Fee Parameters
        _position = _updateFeeParameters(_position);

        uint256 newCollateralAmount = _position.collateralAmount + _params.request.input.collateralDelta;
        // Calculate the Size Delta to keep Leverage Consistent
        sizeDelta = mulDiv(newCollateralAmount, _position.positionSize, _position.collateralAmount);

        // Update the Position's conditionals
        _position = _updateConditionals(_position, _params.request.input.conditionals);

        // Update the Existing Position
        _position = _editPosition(_position, _cache, _params.request.input.collateralDelta, sizeDelta, true);

        return (_position, sizeDelta, _cache.sizeDeltaUsd.abs());
    }

    function decreaseExistingPosition(
        Position.Data memory _position,
        Position.Execution calldata _params,
        ExecuteCache memory _cache
    ) external view returns (Position.Data memory, DecreaseCache memory) {
        DecreaseCache memory decreaseCache;

        _position = _updateFeeParameters(_position);

        if (_params.request.input.collateralDelta == _position.collateralAmount) {
            decreaseCache.sizeDelta = _position.positionSize;
        } else {
            decreaseCache.sizeDelta =
                mulDiv(_position.positionSize, _params.request.input.collateralDelta, _position.collateralAmount);
        }
        decreaseCache.decreasePnl = Pricing.getDecreasePositionPnl(
            _cache.indexBaseUnit,
            decreaseCache.sizeDelta,
            _position.pnlParams.weightedAvgEntryPrice,
            _params.indexPrice,
            _position.isLong
        );

        _position = _updateConditionals(_position, _params.request.input.conditionals);

        _position =
            _editPosition(_position, _cache, _params.request.input.collateralDelta, decreaseCache.sizeDelta, false);

        (_position, decreaseCache.afterFeeAmount, decreaseCache.fundingFee, decreaseCache.borrowFee) =
            _processFees(_position, _params, _cache);

        return (_position, decreaseCache);
    }

    ///////////////////////////////
    // INTERNAL HELPER FUNCTIONS //
    ///////////////////////////////

    function _updateFeeParameters(Position.Data memory _position) internal view returns (Position.Data memory) {
        // Borrowing Fees
        _position.borrowingParams.feesOwed = Borrowing.getTotalPositionFeesOwed(_position.market, _position);
        _position.borrowingParams.lastLongCumulativeBorrowFee = _position.market.longCumulativeBorrowFees();
        _position.borrowingParams.lastShortCumulativeBorrowFee = _position.market.shortCumulativeBorrowFees();
        _position.borrowingParams.lastBorrowUpdate = block.timestamp;
        // Funding Fees
        (_position.fundingParams.feesEarned, _position.fundingParams.feesOwed) =
            Funding.getTotalPositionFees(_position.market, _position);
        _position.fundingParams.lastLongCumulativeFunding = _position.market.longCumulativeFundingFees();
        _position.fundingParams.lastShortCumulativeFunding = _position.market.shortCumulativeFundingFees();
        _position.fundingParams.lastFundingUpdate = block.timestamp;
        return _position;
    }

    /// @dev Applies all changes to an active position
    function _editPosition(
        Position.Data memory _position,
        ExecuteCache memory _cache,
        uint256 _collateralDelta,
        uint256 _sizeDelta,
        bool _isIncrease
    ) internal pure returns (Position.Data memory) {
        if (_isIncrease) {
            // Increase the Position's collateral
            _position.collateralAmount += _collateralDelta;
            if (_sizeDelta > 0) {
                _position =
                    _updatePositionForIncrease(_position, _sizeDelta, _cache.sizeDeltaUsd.abs(), _cache.indexPrice);
            }
        } else {
            _position.collateralAmount -= _collateralDelta;
            if (_sizeDelta > 0) {
                _position = _updatePositionForDecrease(_position, _sizeDelta, _cache.indexPrice, _cache.indexBaseUnit);
            }
        }
        return _position;
    }

    function _updatePositionForIncrease(
        Position.Data memory _position,
        uint256 _sizeDelta,
        uint256 _sizeDeltaUsd,
        uint256 _price
    ) internal pure returns (Position.Data memory) {
        _position.positionSize += _sizeDelta;
        _position.pnlParams.weightedAvgEntryPrice = Pricing.calculateWeightedAverageEntryPrice(
            _position.pnlParams.weightedAvgEntryPrice,
            _position.pnlParams.sigmaIndexSizeUSD,
            _sizeDeltaUsd.toInt256(),
            _price
        );
        _position.pnlParams.sigmaIndexSizeUSD += _sizeDeltaUsd;
        return _position;
    }

    function _updatePositionForDecrease(
        Position.Data memory position,
        uint256 _sizeDelta,
        uint256 _price,
        uint256 _baseUnit
    ) internal pure returns (Position.Data memory) {
        position.positionSize -= _sizeDelta;
        uint256 sizeDeltaUsd = Position.getTradeValueUsd(_sizeDelta, _price, _baseUnit);
        position.pnlParams.weightedAvgEntryPrice = Pricing.calculateWeightedAverageEntryPrice(
            position.pnlParams.weightedAvgEntryPrice,
            position.pnlParams.sigmaIndexSizeUSD,
            -1 * sizeDeltaUsd.toInt256(),
            _price
        );
        position.pnlParams.sigmaIndexSizeUSD -= sizeDeltaUsd;
        return position;
    }

    function _updateConditionals(Position.Data memory _position, Position.Conditionals memory _conditionals)
        internal
        pure
        returns (Position.Data memory)
    {
        // If Conditionals are Valid, Update the Position
        try Position.validateConditionals(_conditionals, _position.pnlParams.weightedAvgEntryPrice) {
            _position.conditionals = _conditionals;
        } catch {}
        // Return the Updated Position
        return _position;
    }

    // Checks if a position meets the minimum collateral threshold
    function _checkMinCollateral(uint256 _collateralAmount, uint256 _collateralPriceUsd, uint256 _minCollateralUsd)
        internal
        pure
        returns (bool isValid)
    {
        uint256 requestCollateralUsd = mulDiv(_collateralAmount, _collateralPriceUsd, PRECISION);
        if (requestCollateralUsd < _minCollateralUsd) {
            isValid = false;
        } else {
            isValid = true;
        }
    }

    function _checkIsLiquidatable(
        Position.Data memory _position,
        ExecuteCache memory _cache,
        uint256 _liquidationFeeUsd
    ) public view returns (bool isLiquidatable) {
        uint256 collateralValueUsd = mulDiv(_position.collateralAmount, _cache.collateralPrice, PRECISION);
        uint256 totalFeesOwedUsd = Position.getTotalFeesOwedUsd(_position, _cache);
        int256 pnl = Pricing.calculatePnL(_position, _cache.indexPrice, _cache.indexBaseUnit);
        uint256 losses = _liquidationFeeUsd + totalFeesOwedUsd;
        if (pnl < 0) {
            losses += pnl.abs();
        }
        if (collateralValueUsd <= losses) {
            isLiquidatable = true;
        } else {
            isLiquidatable = false;
        }
    }

    function _processFees(
        Position.Data memory _position,
        Position.Execution calldata _params,
        ExecuteCache memory _cache
    ) internal view returns (Position.Data memory, uint256 afterFeeAmount, uint256 fundingFee, uint256 borrowFee) {
        (_position, fundingFee) = _subtractFundingFee(_position, _cache, _params.request.input.collateralDelta);
        (_position, borrowFee) = _subtractBorrowingFee(_position, _cache, _params.request.input.collateralDelta);
        afterFeeAmount = _params.request.input.collateralDelta - fundingFee - borrowFee;

        return (_position, afterFeeAmount, fundingFee, borrowFee);
    }

    function _subtractFundingFee(Position.Data memory _position, ExecuteCache memory _cache, uint256 _collateralDelta)
        internal
        pure
        returns (Position.Data memory, uint256 collateralFeesOwed)
    {
        uint256 feesOwedUsd = mulDiv(_position.fundingParams.feesOwed, _cache.indexPrice, _cache.indexBaseUnit);
        collateralFeesOwed = mulDiv(feesOwedUsd, PRECISION, _cache.collateralPrice);

        require(collateralFeesOwed <= _collateralDelta, "TS: Fee > CollateralDelta");

        _position.fundingParams.feesOwed = 0;

        return (_position, collateralFeesOwed);
    }

    /// @dev Returns borrow fee in collateral tokens (original value is in index tokens)
    function _subtractBorrowingFee(Position.Data memory _position, ExecuteCache memory _cache, uint256 _collateralDelta)
        internal
        view
        returns (Position.Data memory, uint256 collateralFeesOwed)
    {
        uint256 borrowFee = Borrowing.calculateFeeForPositionChange(_position.market, _position, _collateralDelta);
        _position.borrowingParams.feesOwed -= borrowFee;
        // convert borrow fee from index tokens to collateral tokens to subtract from collateral:
        uint256 borrowFeeUsd = mulDiv(borrowFee, _cache.indexPrice, _cache.indexBaseUnit);
        collateralFeesOwed = mulDiv(borrowFeeUsd, PRECISION, _cache.collateralPrice);

        require(collateralFeesOwed <= _collateralDelta, "TS: Fee > CollateralDelta");

        return (_position, collateralFeesOwed);
    }
}
