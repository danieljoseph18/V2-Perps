// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

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
import {Oracle} from "../oracle/Oracle.sol";
import {Fee} from "../libraries/Fee.sol";
import {Referral} from "../referrals/Referral.sol";
import {ITradeStorage} from "./interfaces/ITradeStorage.sol";
import {IPriceFeed} from "../oracle/interfaces/IPriceFeed.sol";
import {ILiquidityVault} from "../liquidity/interfaces/ILiquidityVault.sol";
import {PriceImpact} from "../libraries/PriceImpact.sol";
import {IReferralStorage} from "../referrals/interfaces/IReferralStorage.sol";

// Library for Handling Trade related logic
library Order {
    using SignedMath for int256;
    using SafeCast for uint256;

    uint256 internal constant PRECISION = 1e18;
    uint256 private constant MIN_SLIPPAGE = 0.0001e18; // 0.01%
    uint256 private constant MAX_SLIPPAGE = 0.9999e18; // 99.99%

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
        int256 collateralDeltaUsd;
        int256 priceImpactUsd;
        uint256 collateralPrice;
        uint256 collateralBaseUnit;
        uint256 fee;
        uint256 feeDiscount;
        address referrer;
    }

    struct CreateCache {
        uint256 collateralRefPrice;
        address market;
        bytes32 positionKey;
        uint256 indexRefPrice;
        uint256 indexBaseUnit;
        uint256 sizeDeltaUsd;
        uint256 collateralDeltaUsd;
        uint256 collateralBaseUnit;
        uint256 minCollateralUsd;
        uint256 collateralAmountUsd;
        uint256 positionSizeUsd;
        Position.RequestType requestType;
    }

    ////////////////////////////
    // CONSTRUCTION FUNCTIONS //
    ////////////////////////////

    function constructExecuteParams(
        ITradeStorage tradeStorage,
        IMarketMaker marketMaker,
        IPriceFeed priceFeed,
        ILiquidityVault liquidityVault,
        bytes32 _orderKey,
        address _feeReceiver,
        bool _isLimitOrder,
        Oracle.TradingEnabled memory _isTradingEnabled
    ) external view returns (ExecuteCache memory cache, Position.Request memory request) {
        // Fetch and validate request from key
        request = tradeStorage.getOrder(_orderKey);
        require(request.user != address(0), "Order: Request Key");
        require(_feeReceiver != address(0), "Order: Fee Receiver");
        // Get the asset and validate trading is enabled
        Oracle.validateTradingHours(priceFeed, request.input.indexToken, _isTradingEnabled);
        // Fetch and validate price
        cache = fetchTokenValues(priceFeed, cache, request.input.indexToken, request.requestBlock, request.input.isLong);

        if (_isLimitOrder) Position.checkLimitPrice(cache.indexPrice, request.input);

        // Cache Variables
        cache.market = IMarket(marketMaker.tokenToMarkets(request.input.indexToken));
        cache.collateralDeltaUsd = _calculateValueUsd(
            request.input.collateralDelta, cache.collateralPrice, cache.collateralBaseUnit, request.input.isIncrease
        );
        if (request.input.sizeDelta != 0) {
            // Execute Price Impact
            (cache.impactedPrice, cache.priceImpactUsd) =
                PriceImpact.execute(cache.market, request, cache.indexPrice, cache.indexBaseUnit);
            // Cache Size Delta USD
            cache.sizeDeltaUsd = _calculateValueUsd(
                request.input.sizeDelta, cache.indexPrice, cache.indexBaseUnit, request.input.isIncrease
            );
            MarketUtils.validateAllocation(
                cache.market,
                liquidityVault,
                cache.sizeDeltaUsd.abs(),
                cache.collateralPrice,
                cache.indexPrice,
                cache.collateralBaseUnit,
                cache.indexBaseUnit,
                request.input.isLong
            );
        }
    }

    // SL / TP are just Decrease Orders
    function constructConditionalOrders(
        Position.Data memory _position,
        Position.Conditionals memory _conditionals,
        uint256 _referencePrice
    ) external view returns (Position.Request memory stopLossOrder, Position.Request memory takeProfitOrder) {
        // Validate the Conditionals
        Position.validateConditionals(_conditionals, _referencePrice, _position.isLong);
        // Construct the stop loss based on the values
        if (_conditionals.stopLossSet) {
            stopLossOrder = Position.Request({
                input: Position.Input({
                    indexToken: _position.indexToken,
                    collateralToken: _position.collateralToken,
                    collateralDelta: mulDiv(_position.collateralAmount, _conditionals.stopLossPercentage, PRECISION),
                    sizeDelta: mulDiv(_position.positionSize, _conditionals.stopLossPercentage, PRECISION),
                    limitPrice: _conditionals.stopLossPrice,
                    maxSlippage: MAX_SLIPPAGE,
                    executionFee: 0, // @audit - how do we get user to pay for execution?
                    isLong: !_position.isLong,
                    isLimit: true,
                    isIncrease: false,
                    shouldWrap: true,
                    conditionals: Position.Conditionals({
                        stopLossSet: false,
                        stopLossPrice: 0,
                        stopLossPercentage: 0,
                        takeProfitSet: false,
                        takeProfitPrice: 0,
                        takeProfitPercentage: 0
                    })
                }),
                market: address(_position.market),
                user: _position.user,
                requestBlock: block.number,
                requestType: Position.RequestType.STOP_LOSS
            });
        }
        // Construct the Take profit based on the values
        if (_conditionals.takeProfitSet) {
            takeProfitOrder = Position.Request({
                input: Position.Input({
                    indexToken: _position.indexToken,
                    collateralToken: _position.collateralToken,
                    collateralDelta: mulDiv(_position.collateralAmount, _conditionals.takeProfitPercentage, PRECISION),
                    sizeDelta: mulDiv(_position.positionSize, _conditionals.takeProfitPercentage, PRECISION),
                    limitPrice: _conditionals.takeProfitPrice,
                    maxSlippage: MAX_SLIPPAGE,
                    executionFee: 0, // @audit - how do we get user to pay for execution?
                    isLong: !_position.isLong,
                    isLimit: true,
                    isIncrease: false,
                    shouldWrap: true,
                    conditionals: Position.Conditionals({
                        stopLossSet: false,
                        stopLossPrice: 0,
                        stopLossPercentage: 0,
                        takeProfitSet: false,
                        takeProfitPrice: 0,
                        takeProfitPercentage: 0
                    })
                }),
                market: address(_position.market),
                user: _position.user,
                requestBlock: block.number,
                requestType: Position.RequestType.TAKE_PROFIT
            });
        }
    }

    //////////////////////////
    // VALIDATION FUNCTIONS //
    //////////////////////////

    function validateInitialParameters(
        IMarketMaker marketMaker,
        ITradeStorage tradeStorage,
        IPriceFeed priceFeed,
        Position.Input memory _trade
    ) external view returns (CreateCache memory cache) {
        require(_trade.maxSlippage >= MIN_SLIPPAGE && _trade.maxSlippage <= MAX_SLIPPAGE, "Order: Slippage");
        require(_trade.collateralDelta != 0, "Order: Collateral Delta");

        if (_trade.isLong) {
            cache.collateralRefPrice = Oracle.getLongReferencePrice(priceFeed);
        } else {
            cache.collateralRefPrice = Oracle.getShortReferencePrice(priceFeed);
        }

        require(cache.collateralRefPrice > 0, "Order: Invalid Collateral Ref Price");

        cache.market = marketMaker.tokenToMarkets(_trade.indexToken);
        require(cache.market != address(0), "Order: Market Doesn't Exist");

        cache.positionKey = keccak256(abi.encode(_trade.indexToken, msg.sender, _trade.isLong));

        cache.indexRefPrice = Oracle.getReferencePrice(priceFeed, priceFeed.getAsset(_trade.indexToken));
        require(cache.indexRefPrice > 0, "Order: Invalid Index Ref Price");

        cache.indexBaseUnit = Oracle.getBaseUnit(priceFeed, _trade.indexToken);
        cache.sizeDeltaUsd = mulDiv(_trade.sizeDelta, cache.indexRefPrice, cache.indexBaseUnit);

        if (_trade.isLimit) {
            if (_trade.isLong) {
                require(_trade.limitPrice > cache.indexRefPrice, "Order: mark price > limit price");
            } else {
                require(_trade.limitPrice < cache.indexRefPrice, "Order: mark price < limit price");
            }
        }

        cache.collateralBaseUnit = Oracle.getBaseUnit(priceFeed, _trade.collateralToken);
        cache.collateralDeltaUsd = mulDiv(_trade.collateralDelta, cache.collateralRefPrice, cache.collateralBaseUnit);
        cache.minCollateralUsd = tradeStorage.minCollateralUsd();
    }

    function validateParamsForType(
        Position.Input memory _trade,
        CreateCache memory _cache,
        uint256 _collateralAmount,
        uint256 _positionSize
    ) external view returns (CreateCache memory) {
        // Validate for each request type
        if (_cache.requestType == Position.RequestType.CREATE_POSITION) {
            Position.validateConditionals(_trade.conditionals, _cache.indexRefPrice, _trade.isLong);
            checkMinCollateral(
                _trade.collateralDelta, _cache.collateralRefPrice, _cache.collateralBaseUnit, _cache.minCollateralUsd
            );
            Position.checkLeverage(IMarket(_cache.market), _cache.sizeDeltaUsd, _cache.collateralDeltaUsd);
        } else if (_cache.requestType == Position.RequestType.POSITION_INCREASE) {
            // Clear the Conditionals
            _trade.conditionals = Position.Conditionals(false, false, 0, 0, 0, 0);
        } else if (_cache.requestType == Position.RequestType.POSITION_DECREASE) {
            checkMinCollateral(
                _collateralAmount - _trade.collateralDelta,
                _cache.collateralRefPrice,
                _cache.collateralBaseUnit,
                _cache.minCollateralUsd
            );
            // Clear the Conditionals
            _trade.conditionals = Position.Conditionals(false, false, 0, 0, 0, 0);
        } else if (_cache.requestType == Position.RequestType.COLLATERAL_INCREASE) {
            // convert existing collateral amount to usd
            _cache.collateralAmountUsd = mulDiv(_collateralAmount, _cache.collateralRefPrice, _cache.collateralBaseUnit);
            // conver position size to usd
            _cache.positionSizeUsd = mulDiv(_positionSize, _cache.indexRefPrice, _cache.indexBaseUnit);
            // subtract collateral delta usd
            _cache.collateralAmountUsd += _cache.collateralDeltaUsd;
            // chcek it doesnt go below min leverage
            Position.checkLeverage(IMarket(_cache.market), _cache.positionSizeUsd, _cache.collateralAmountUsd);
            // Clear the Conditionals
            _trade.conditionals = Position.Conditionals(false, false, 0, 0, 0, 0);
        } else if (_cache.requestType == Position.RequestType.COLLATERAL_DECREASE) {
            checkMinCollateral(
                _collateralAmount - _trade.collateralDelta,
                _cache.collateralRefPrice,
                _cache.collateralBaseUnit,
                _cache.minCollateralUsd
            );
            // convert existing collateral amount to usd
            _cache.collateralAmountUsd = mulDiv(_collateralAmount, _cache.collateralRefPrice, _cache.collateralBaseUnit);
            // conver position size to usd
            _cache.positionSizeUsd = mulDiv(_positionSize, _cache.indexRefPrice, _cache.indexBaseUnit);
            // subtract collateral delta usd
            _cache.collateralAmountUsd -= _cache.collateralDeltaUsd;
            // chcek it doesnt go below min leverage
            Position.checkLeverage(IMarket(_cache.market), _cache.positionSizeUsd, _cache.collateralAmountUsd);
            // Clear the Conditionals
            _trade.conditionals = Position.Conditionals(false, false, 0, 0, 0, 0);
        } else {
            revert("Order: Invalid Request Type");
        }
        return _cache;
    }

    //////////////////////////////
    // MAIN EXECUTION FUNCTIONS //
    //////////////////////////////

    // @audit - check the position isn't put below min leverage
    // @audit - should we process fees before updating the fee parameters?
    function executeCollateralIncrease(
        Position.Data memory _position,
        Position.Execution calldata _params,
        ExecuteCache memory _cache
    ) external view returns (Position.Data memory position, uint256 fundingFeeOwed, uint256 borrowFeeOwed) {
        // Update the Fee Parameters
        position = _updateFeeParameters(_position);
        // Process any Outstanding Fees
        uint256 afterFeeAmount;
        (position, afterFeeAmount, fundingFeeOwed, borrowFeeOwed) = _processFees(position, _params, _cache);
        require(afterFeeAmount > 0, "Order: After Fee");
        // Edit the Position for Increase
        position = _editPosition(position, _cache, afterFeeAmount, 0, true);
        // Check the Leverage
        Position.checkLeverage(
            _cache.market,
            mulDiv(position.positionSize, _cache.indexPrice, _cache.indexBaseUnit),
            mulDiv(position.collateralAmount, _cache.collateralPrice, _cache.collateralBaseUnit)
        );
    }

    function executeCollateralDecrease(
        Position.Data memory _position,
        Position.Execution calldata _params,
        ExecuteCache memory _cache,
        uint256 _minCollateralUsd,
        uint256 _liquidationFeeUsd
    ) external view returns (Position.Data memory position, uint256 fundingFeeOwed, uint256 borrowFeeOwed) {
        // Update the Fee Parameters
        position = _updateFeeParameters(_position);
        // Process any Outstanding Fees
        (position,, fundingFeeOwed, borrowFeeOwed) = _processFees(position, _params, _cache);
        // Edit the Position
        position = _editPosition(position, _cache, _params.request.input.collateralDelta, 0, false);
        // Check if the Decrease puts the position below the min collateral threshold
        require(
            checkMinCollateral(
                position.collateralAmount, _cache.collateralPrice, _cache.collateralBaseUnit, _minCollateralUsd
            ),
            "Order: Min Collat"
        );
        // Check if the Decrease makes the Position Liquidatable
        require(!_checkIsLiquidatable(position, _cache, _liquidationFeeUsd), "Order: Liquidatable");
        // Check the Leverage
        Position.checkLeverage(
            _cache.market,
            mulDiv(position.positionSize, _cache.indexPrice, _cache.indexBaseUnit),
            mulDiv(position.collateralAmount, _cache.collateralPrice, _cache.collateralBaseUnit)
        );
    }

    function createNewPosition(
        Position.Execution calldata _params,
        ExecuteCache memory _cache,
        uint256 _minCollateralUsd
    ) external view returns (Position.Data memory, uint256 sizeUsd) {
        // Check that the Position meets the minimum collateral threshold
        require(
            checkMinCollateral(
                _params.request.input.collateralDelta,
                _cache.collateralPrice,
                _cache.collateralBaseUnit,
                _minCollateralUsd
            ),
            "Order: Min Collat"
        );
        // Generate the Position
        Position.Data memory position = Position.generateNewPosition(_params.request, _cache);
        // Check the Position's Leverage is Valid
        uint256 absSizeDelta = _cache.sizeDeltaUsd.abs();
        Position.checkLeverage(_cache.market, absSizeDelta, _cache.collateralDeltaUsd.abs());
        // Return the Position
        return (position, absSizeDelta);
    }

    function increaseExistingPosition(
        Position.Data memory _position,
        Position.Execution calldata _params,
        ExecuteCache memory _cache
    )
        external
        view
        returns (Position.Data memory position, uint256 sizeDeltaUsd, uint256 fundingFeeOwed, uint256 borrowFeeOwed)
    {
        // Update the Fee Parameters
        position = _updateFeeParameters(_position);
        // Process any Outstanding Fees
        (position,, fundingFeeOwed, borrowFeeOwed) = _processFees(position, _params, _cache);

        // Update the Existing Position
        position = _editPosition(
            position, _cache, _params.request.input.collateralDelta, _params.request.input.sizeDelta, true
        );

        sizeDeltaUsd = _cache.sizeDeltaUsd.abs();
        // Check the Leverage
        Position.checkLeverage(
            _cache.market,
            mulDiv(position.positionSize, _cache.indexPrice, _cache.indexBaseUnit),
            mulDiv(position.collateralAmount, _cache.collateralPrice, _cache.collateralBaseUnit)
        );
    }

    function decreaseExistingPosition(
        Position.Data memory _position,
        Position.Execution calldata _params,
        ExecuteCache memory _cache,
        uint256 _minCollateralUsd,
        uint256 _liquidationFeeUsd
    ) external view returns (Position.Data memory position, DecreaseCache memory decreaseCache) {
        position = _updateFeeParameters(_position);

        if (_params.request.input.collateralDelta == position.collateralAmount) {
            decreaseCache.sizeDelta = position.positionSize;
        } else {
            decreaseCache.sizeDelta =
                mulDiv(position.positionSize, _params.request.input.collateralDelta, position.collateralAmount);
        }
        decreaseCache.decreasePnl = Pricing.getDecreasePositionPnl(
            _cache.indexBaseUnit,
            decreaseCache.sizeDelta,
            position.weightedAvgEntryPrice,
            _cache.impactedPrice,
            _cache.collateralPrice,
            _cache.collateralBaseUnit,
            position.isLong
        );

        position =
            _editPosition(position, _cache, _params.request.input.collateralDelta, decreaseCache.sizeDelta, false);

        (position, decreaseCache.afterFeeAmount, decreaseCache.fundingFee, decreaseCache.borrowFee) =
            _processFees(position, _params, _cache);

        // Check if the Decrease puts the position below the min collateral threshold
        // Only check these if it's not a full decrease
        if (position.collateralAmount != 0) {
            require(
                checkMinCollateral(
                    position.collateralAmount, _cache.collateralPrice, _cache.collateralBaseUnit, _minCollateralUsd
                ),
                "Order: Min Collat"
            );
            // Check if the Decrease makes the Position Liquidatable
            require(!_checkIsLiquidatable(position, _cache, _liquidationFeeUsd), "Order: Liquidatable");
        }
    }

    // Checks if a position meets the minimum collateral threshold
    function checkMinCollateral(
        uint256 _collateralAmount,
        uint256 _collateralPriceUsd,
        uint256 _collateralBaseUnit,
        uint256 _minCollateralUsd
    ) public pure returns (bool isValid) {
        uint256 requestCollateralUsd = mulDiv(_collateralAmount, _collateralPriceUsd, _collateralBaseUnit);
        if (requestCollateralUsd < _minCollateralUsd) {
            isValid = false;
        } else {
            isValid = true;
        }
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
                _position = _updatePositionForIncrease(_position, _sizeDelta, _cache.impactedPrice);
            }
        } else {
            _position.collateralAmount -= _collateralDelta;
            if (_sizeDelta > 0) {
                _position = _updatePositionForDecrease(_position, _sizeDelta, _cache.impactedPrice);
            }
        }
        return _position;
    }

    function _updatePositionForIncrease(Position.Data memory _position, uint256 _sizeDelta, uint256 _price)
        internal
        pure
        returns (Position.Data memory)
    {
        _position.weightedAvgEntryPrice = Pricing.calculateWeightedAverageEntryPrice(
            _position.weightedAvgEntryPrice, _position.positionSize, _sizeDelta.toInt256(), _price
        );
        _position.positionSize += _sizeDelta;
        return _position;
    }

    // @audit - cache variables for gas savings
    function _updatePositionForDecrease(Position.Data memory position, uint256 _sizeDelta, uint256 _price)
        internal
        pure
        returns (Position.Data memory)
    {
        position.weightedAvgEntryPrice = Pricing.calculateWeightedAverageEntryPrice(
            position.weightedAvgEntryPrice, position.positionSize, -_sizeDelta.toInt256(), _price
        );
        position.positionSize -= _sizeDelta;
        return position;
    }

    function _checkIsLiquidatable(
        Position.Data memory _position,
        ExecuteCache memory _cache,
        uint256 _liquidationFeeUsd
    ) public view returns (bool isLiquidatable) {
        uint256 collateralValueUsd =
            mulDiv(_position.collateralAmount, _cache.collateralPrice, _cache.collateralBaseUnit);
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
    )
        internal
        view
        returns (Position.Data memory position, uint256 afterFeeAmount, uint256 fundingFee, uint256 borrowFee)
    {
        (position, fundingFee) = _subtractFundingFee(_position, _cache, _params.request.input.collateralDelta);

        (position, borrowFee) = _subtractBorrowingFee(position, _cache, _params.request.input.collateralDelta);
        afterFeeAmount = _params.request.input.collateralDelta - fundingFee - borrowFee;

        return (position, afterFeeAmount, fundingFee, borrowFee);
    }

    function _subtractFundingFee(Position.Data memory _position, ExecuteCache memory _cache, uint256 _collateralDelta)
        internal
        pure
        returns (Position.Data memory, uint256 fundingAmountOwed)
    {
        uint256 feesOwedUsd = mulDiv(_position.fundingParams.feesOwed, _cache.indexPrice, _cache.indexBaseUnit);
        fundingAmountOwed = mulDiv(feesOwedUsd, _cache.collateralBaseUnit, _cache.collateralPrice);

        require(fundingAmountOwed <= _collateralDelta, "Order: Fee > CollateralDelta");

        _position.fundingParams.feesOwed = 0;

        return (_position, fundingAmountOwed);
    }

    /// @dev Returns borrow fee in collateral tokens (original value is in index tokens)
    function _subtractBorrowingFee(Position.Data memory _position, ExecuteCache memory _cache, uint256 _collateralDelta)
        internal
        view
        returns (Position.Data memory, uint256 borrowingAmountOwed)
    {
        uint256 borrowFee = Borrowing.calculateFeeForPositionChange(_cache.market, _position, _collateralDelta);
        _position.borrowingParams.feesOwed -= borrowFee;
        // convert borrow fee from index tokens to collateral tokens to subtract from collateral:
        uint256 borrowFeeUsd = mulDiv(borrowFee, _cache.indexPrice, _cache.indexBaseUnit);
        borrowingAmountOwed = mulDiv(borrowFeeUsd, _cache.collateralBaseUnit, _cache.collateralPrice);

        require(borrowingAmountOwed <= _collateralDelta, "Order: Fee > CollateralDelta");

        return (_position, borrowingAmountOwed);
    }

    function _calculateValueUsd(uint256 _tokenAmount, uint256 _tokenPrice, uint256 _tokenBaseUnit, bool _isIncrease)
        internal
        pure
        returns (int256 valueUsd)
    {
        // Flip sign if decreasing position
        uint256 absValueUsd = Position.getTradeValueUsd(_tokenAmount, _tokenPrice, _tokenBaseUnit);
        if (_isIncrease) {
            valueUsd = absValueUsd.toInt256();
        } else {
            valueUsd = -1 * absValueUsd.toInt256();
        }
    }

    // @audit - We're giving the position extra size by using max price
    function fetchTokenValues(
        IPriceFeed priceFeed,
        ExecuteCache memory _cache,
        address _indexToken,
        uint256 _requestBlock,
        bool _isLong
    ) public view returns (ExecuteCache memory) {
        require(Oracle.priceWasSigned(priceFeed, _indexToken, _requestBlock), "Order: Price Not Signed");
        if (_isLong) {
            _cache.indexPrice = Oracle.getMaxPrice(priceFeed, _indexToken, _requestBlock);
            (_cache.longMarketTokenPrice, _cache.shortMarketTokenPrice) =
                Oracle.getMarketTokenPrices(priceFeed, _requestBlock, true);
            _cache.collateralBaseUnit = Oracle.getLongBaseUnit(priceFeed);
            _cache.collateralPrice = _cache.longMarketTokenPrice;
        } else {
            _cache.indexPrice = Oracle.getMinPrice(priceFeed, _indexToken, _requestBlock);
            (_cache.longMarketTokenPrice, _cache.shortMarketTokenPrice) =
                Oracle.getMarketTokenPrices(priceFeed, _requestBlock, false);
            _cache.collateralBaseUnit = Oracle.getShortBaseUnit(priceFeed);
            _cache.collateralPrice = _cache.shortMarketTokenPrice;
        }
        _cache.indexBaseUnit = Oracle.getBaseUnit(priceFeed, _indexToken);
        return _cache;
    }
}
