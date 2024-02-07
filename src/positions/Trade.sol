// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {ITradeStorage} from "./interfaces/ITradeStorage.sol";
import {ILiquidityVault} from "../liquidity/interfaces/ILiquidityVault.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {IDataOracle} from "../oracle/interfaces/IDataOracle.sol";
import {IMarketMaker} from "../markets/interfaces/IMarketMaker.sol";
import {Position} from "./Position.sol";
import {MarketUtils} from "../markets/MarketUtils.sol";
import {Funding} from "../libraries/Funding.sol";
import {Borrowing} from "../libraries/Borrowing.sol";
import {Pricing} from "../libraries/Pricing.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

// Library for Handling Trade related logic
library Trade {
    uint256 internal constant PRECISION = 1e18;

    struct DecreaseCache {
        uint256 sizeDelta;
        uint256 collateralPrice;
        int256 decreasePnl;
        uint256 afterFeeAmount;
        uint256 fundingFee;
        uint256 borrowFee;
        uint256 indexBaseUnit;
    }

    //////////////////////////////
    // MAIN EXECUTION FUNCTIONS //
    //////////////////////////////

    function executeCollateralIncrease(
        IDataOracle _dataOracle,
        Position.Data memory _position,
        Position.Execution calldata _params
    ) external view returns (Position.Data memory) {
        // Update the Fee Parameters
        _position = _updateFeeParameters(_position);
        // Edit the Position for Increase
        _position = _editPosition(
            _position,
            _params.request.input.collateralDelta,
            0,
            0,
            _params.indexPrice,
            true,
            _dataOracle.getBaseUnits(_position.indexToken)
        );
        return _position;
    }

    function executeCollateralDecrease(
        IDataOracle _dataOracle,
        Position.Data memory _position,
        Position.Execution calldata _params,
        uint256 _minCollateralUsd,
        uint256 _liquidationFeeUsd
    ) external view returns (Position.Data memory) {
        // Update the Fee Parameters
        _position = _updateFeeParameters(_position);

        uint256 collateralPrice;

        if (_params.request.input.isLong) {
            (collateralPrice,) = MarketUtils.validateAndRetrievePrices(_dataOracle, _params.request.requestBlock);
        } else {
            (, collateralPrice) = MarketUtils.validateAndRetrievePrices(_dataOracle, _params.request.requestBlock);
        }
        _position.collateralAmount -= _params.request.input.collateralDelta;

        // Check if the Decrease puts the position below the min collateral threshold
        require(_checkMinCollateral(_position.collateralAmount, collateralPrice, _minCollateralUsd), "TS: Min Collat");

        uint256 indexBaseUnit = _dataOracle.getBaseUnits(_position.indexToken);

        // Check if the Decrease makes the Position Liquidatable
        require(
            !_checkIsLiquidatable(
                _dataOracle,
                _position.market,
                _position,
                collateralPrice,
                _params.indexPrice,
                _liquidationFeeUsd,
                indexBaseUnit
            ),
            "TS: Liquidatable"
        );

        // Edit the Position
        return _editPosition(
            _position, _params.request.input.collateralDelta, 0, 0, _params.indexPrice, false, indexBaseUnit
        );
    }

    function createNewPosition(
        IDataOracle _dataOracle,
        IMarketMaker _marketMaker,
        Position.Execution calldata _params,
        uint256 _minCollateralUsd
    ) external view returns (Position.Data memory, uint256 sizeUsd, uint256 collateralPrice) {
        // Get and Validate the Collateral Price
        collateralPrice;
        if (_params.request.input.isLong) {
            (collateralPrice,) = MarketUtils.validateAndRetrievePrices(_dataOracle, _params.request.requestBlock);
        } else {
            (, collateralPrice) = MarketUtils.validateAndRetrievePrices(_dataOracle, _params.request.requestBlock);
        }
        // Get the Size Delta in USD
        sizeUsd = Position.getTradeValueUsd(
            _params.request.input.sizeDelta,
            _params.indexPrice,
            _dataOracle.getBaseUnits(_params.request.input.indexToken)
        );
        // Check that the Position meets the minimum collateral threshold
        require(
            _checkMinCollateral(_params.request.input.collateralDelta, collateralPrice, _minCollateralUsd),
            "TS: Min Collat"
        );
        // Generate the Position
        IMarket market = IMarket(_marketMaker.tokenToMarkets(_params.request.input.indexToken));
        Position.Data memory position =
            Position.generateNewPosition(market, _dataOracle, _params.request, _params.indexPrice);
        // Check the Position's Leverage is Valid
        Position.checkLeverage(collateralPrice, sizeUsd, position.collateralAmount);
        // Return the Position
        return (position, sizeUsd, collateralPrice);
    }

    function increaseExistingPosition(
        IDataOracle _dataOracle,
        Position.Data memory _position,
        Position.Execution calldata _params
    ) external view returns (Position.Data memory, uint256 sizeDelta, uint256 sizeDeltaUsd) {
        // Update the Fee Parameters
        _position = _updateFeeParameters(_position);

        uint256 newCollateralAmount = _position.collateralAmount + _params.request.input.collateralDelta;
        // Calculate the Size Delta to keep Leverage Consistent
        sizeDelta = Math.mulDiv(newCollateralAmount, _position.positionSize, _position.collateralAmount);
        // Reserve Liquidity Equal to the Position Size
        sizeDeltaUsd = Position.getTradeValueUsd(
            _params.request.input.sizeDelta,
            _params.indexPrice,
            _dataOracle.getBaseUnits(_params.request.input.indexToken)
        );
        // Update the Existing Position
        _position = _editPosition(
            _position,
            _params.request.input.collateralDelta,
            sizeDelta,
            sizeDeltaUsd,
            _params.indexPrice,
            true,
            _dataOracle.getBaseUnits(_params.request.input.indexToken)
        );

        return (_position, sizeDelta, sizeDeltaUsd);
    }

    function decreaseExistingPosition(
        IDataOracle _dataOracle,
        Position.Data memory _position,
        Position.Execution calldata _params
    ) external view returns (Position.Data memory, DecreaseCache memory) {
        DecreaseCache memory cache;

        if (_params.request.input.isLong) {
            (cache.collateralPrice,) = MarketUtils.validateAndRetrievePrices(_dataOracle, _params.request.requestBlock);
        } else {
            (, cache.collateralPrice) = MarketUtils.validateAndRetrievePrices(_dataOracle, _params.request.requestBlock);
        }

        if (_params.request.input.collateralDelta == _position.collateralAmount) {
            cache.sizeDelta = _position.positionSize;
        } else {
            cache.sizeDelta =
                Math.mulDiv(_position.positionSize, _params.request.input.collateralDelta, _position.collateralAmount);
        }
        cache.indexBaseUnit = _dataOracle.getBaseUnits(_params.request.input.indexToken);
        cache.decreasePnl = Pricing.getDecreasePositionPnl(
            cache.indexBaseUnit,
            cache.sizeDelta,
            _position.pnlParams.weightedAvgEntryPrice,
            _params.indexPrice,
            _position.isLong
        );

        _position = _editPosition(
            _position,
            _params.request.input.collateralDelta,
            cache.sizeDelta,
            Position.getTradeValueUsd(cache.sizeDelta, _params.indexPrice, cache.indexBaseUnit),
            _params.indexPrice,
            false,
            cache.indexBaseUnit
        );

        (_position, cache.afterFeeAmount, cache.fundingFee, cache.borrowFee) =
            _processFees(_position, _params, cache.collateralPrice, cache.indexBaseUnit);

        return (_position, cache);
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
        uint256 _collateralDelta,
        uint256 _sizeDelta,
        uint256 _sizeDeltaUsd,
        uint256 _price,
        bool _isIncrease,
        uint256 _baseUnit
    ) internal pure returns (Position.Data memory) {
        if (_isIncrease) {
            // Increase the Position's collateral
            _position.collateralAmount += _collateralDelta;
            if (_sizeDelta > 0) {
                _position = _updatePositionForIncrease(_position, _sizeDelta, _sizeDeltaUsd, _price);
            }
        } else {
            _position.collateralAmount -= _collateralDelta;
            if (_sizeDelta > 0) {
                _position = _updatePositionForDecrease(_position, _sizeDelta, _price, _baseUnit);
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
            int256(_sizeDeltaUsd),
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
            -int256(sizeDeltaUsd),
            _price
        );
        position.pnlParams.sigmaIndexSizeUSD -= sizeDeltaUsd;
        return position;
    }

    // Checks if a position meets the minimum collateral threshold
    function _checkMinCollateral(uint256 _collateralAmount, uint256 _collateralPriceUsd, uint256 _minCollateralUsd)
        internal
        pure
        returns (bool isValid)
    {
        uint256 requestCollateralUsd = Math.mulDiv(_collateralAmount, _collateralPriceUsd, PRECISION);
        if (requestCollateralUsd < _minCollateralUsd) {
            isValid = false;
        } else {
            isValid = true;
        }
    }

    function _checkIsLiquidatable(
        IDataOracle _dataOracle,
        IMarket _market,
        Position.Data memory _position,
        uint256 _collateralPrice,
        uint256 _indexPrice,
        uint256 _liquidationFeeUsd,
        uint256 _indexBaseUnit
    ) public view returns (bool isLiquidatable) {
        uint256 collateralValueUsd = Math.mulDiv(_position.collateralAmount, _collateralPrice, PRECISION);
        uint256 totalFeesOwedUsd = Position.getTotalFeesOwedUsd(_market, _dataOracle, _position, _indexPrice);
        int256 pnl = Pricing.calculatePnL(_position, _indexPrice, _indexBaseUnit);
        uint256 losses = _liquidationFeeUsd + totalFeesOwedUsd;
        if (pnl < 0) {
            losses += uint256(-pnl);
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
        uint256 _collateralPrice,
        uint256 _baseUnit
    ) internal view returns (Position.Data memory, uint256 afterFeeAmount, uint256 fundingFee, uint256 borrowFee) {
        (_position, fundingFee) = _subtractFundingFee(
            _position, _params.request.input.collateralDelta, _params.indexPrice, _collateralPrice, _baseUnit
        );
        (_position, borrowFee) = _subtractBorrowingFee(
            _position, _params.request.input.collateralDelta, _params.indexPrice, _collateralPrice, _baseUnit
        );
        afterFeeAmount = _params.request.input.collateralDelta - fundingFee - borrowFee;

        return (_position, afterFeeAmount, fundingFee, borrowFee);
    }

    function _subtractFundingFee(
        Position.Data memory _position,
        uint256 _collateralDelta,
        uint256 _signedPrice,
        uint256 _collateralPrice,
        uint256 _baseUnit
    ) internal pure returns (Position.Data memory, uint256 collateralFeesOwed) {
        uint256 feesOwedUsd = Math.mulDiv(_position.fundingParams.feesOwed, _signedPrice, _baseUnit);
        collateralFeesOwed = Math.mulDiv(feesOwedUsd, PRECISION, _collateralPrice);

        require(collateralFeesOwed <= _collateralDelta, "TS: Fee > CollateralDelta");

        _position.fundingParams.feesOwed = 0;

        return (_position, collateralFeesOwed);
    }

    /// @dev Returns borrow fee in collateral tokens (original value is in index tokens)
    function _subtractBorrowingFee(
        Position.Data memory _position,
        uint256 _collateralDelta,
        uint256 _signedPrice,
        uint256 _collateralPrice,
        uint256 _baseUnits
    ) internal view returns (Position.Data memory, uint256 collateralFeesOwed) {
        uint256 borrowFee = Borrowing.calculateFeeForPositionChange(_position.market, _position, _collateralDelta);
        _position.borrowingParams.feesOwed -= borrowFee;
        // convert borrow fee from index tokens to collateral tokens to subtract from collateral:
        uint256 borrowFeeUsd = Math.mulDiv(borrowFee, _signedPrice, _baseUnits);
        collateralFeesOwed = Math.mulDiv(borrowFeeUsd, PRECISION, _collateralPrice);

        require(collateralFeesOwed <= _collateralDelta, "TS: Fee > CollateralDelta");

        return (_position, collateralFeesOwed);
    }
}
