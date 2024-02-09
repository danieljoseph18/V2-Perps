//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {Fee} from "../libraries/Fee.sol";
import {PriceImpact} from "../libraries/PriceImpact.sol";
import {mulDiv} from "@prb/math/Common.sol";
import {Pool} from "./Pool.sol";
import {ILiquidityVault} from "./interfaces/ILiquidityVault.sol";
import {MarketUtils} from "../markets/MarketUtils.sol";
import {IPriceFeed} from "../oracle/interfaces/IPriceFeed.sol";
import {Oracle} from "../oracle/Oracle.sol";

library Deposit {
    uint256 public constant MIN_SLIPPAGE = 0.0001e18; // 0.01%
    uint256 public constant MAX_SLIPPAGE = 0.9999e18; // 99.99%
    uint256 public constant SCALING_FACTOR = 1e18;

    struct Params {
        address owner;
        address tokenIn;
        uint256 amountIn;
        uint256 executionFee;
        uint256 maxSlippage;
        bool shouldWrap;
    }

    struct Data {
        Params params;
        uint256 blockNumber;
        uint48 expirationTimestamp;
    }

    function validateCancellation(Data memory _data, address _caller) internal view {
        require(_data.params.owner == _caller, "Deposit: invalid owner");
        require(_data.expirationTimestamp < block.timestamp, "Deposit: deposit not expired");
    }

    function create(Params memory _params, uint48 _minTimeToExpiration)
        external
        view
        returns (Data memory data, bytes32 key)
    {
        uint256 blockNumber = block.number;
        data = Data({
            params: _params,
            blockNumber: blockNumber,
            expirationTimestamp: uint48(block.timestamp) + _minTimeToExpiration
        });

        key = _generateKey(_params.owner, _params.tokenIn, _params.amountIn, blockNumber);
    }

    function execute(
        ILiquidityVault _liquidityVault,
        IPriceFeed _priceFeed,
        Data memory _data,
        Pool.Values memory _values,
        bool _isLongToken,
        uint8 _priceImpactExponent,
        uint256 _priceImpactFactor
    ) external view returns (uint256 mintAmount, uint256 fee, uint256 remaining) {
        // Get token price and calculate price impact directly to reduce local variables
        (uint256 longTokenPrice, uint256 shortTokenPrice) = Oracle.getMarketTokenPrices(_priceFeed, _data.blockNumber);

        uint256 impactedPrice = _calculateImpactedPrice(
            _values,
            _isLongToken,
            _data.params.amountIn,
            _data.params.maxSlippage,
            longTokenPrice,
            shortTokenPrice,
            _priceImpactExponent,
            _priceImpactFactor
        );

        // Calculate fee based on the impacted price
        fee = Fee.calculateForMarket(_liquidityVault, _data.params.amountIn);

        // Calculate remaining after fee
        remaining = _data.params.amountIn - fee;

        // Calculate Mint amount
        mintAmount = _calculateMintAmount(
            _values, impactedPrice, longTokenPrice, shortTokenPrice, _values.longBaseUnit, remaining, _isLongToken
        );
    }

    function _calculateImpactedPrice(
        Pool.Values memory _values,
        bool _isLongToken,
        uint256 _amountIn,
        uint256 _maxSlippage,
        uint256 _longTokenPrice,
        uint256 _shortTokenPrice,
        uint8 _priceImpactExponent,
        uint256 _priceImpactFactor
    ) internal pure returns (uint256 impactedPrice) {
        return PriceImpact.executeForMarket(
            PriceImpact.Params({
                longTokenBalance: _values.longTokenBalance,
                shortTokenBalance: _values.shortTokenBalance,
                longTokenPrice: _longTokenPrice,
                shortTokenPrice: _shortTokenPrice,
                amountIn: _amountIn,
                maxSlippage: _maxSlippage,
                isIncrease: true,
                isLongToken: _isLongToken,
                longBaseUnit: _values.longBaseUnit,
                shortBaseUnit: _values.shortBaseUnit
            }),
            _priceImpactExponent,
            _priceImpactFactor
        );
    }

    function _calculateMintAmount(
        Pool.Values memory _values,
        uint256 _impactedPrice,
        uint256 _longTokenPrice,
        uint256 _shortTokenPrice,
        uint256 _baseUnitIn,
        uint256 _remaining,
        bool _isLongToken
    ) internal pure returns (uint256) {
        uint256 valueUsd = mulDiv(_remaining, _impactedPrice, _baseUnitIn);
        uint256 marketTokenPrice;
        if (_isLongToken) {
            marketTokenPrice = Pool.getMarketTokenPrice(_values, _impactedPrice, _shortTokenPrice);
        } else {
            marketTokenPrice = Pool.getMarketTokenPrice(_values, _longTokenPrice, _impactedPrice);
        }

        return marketTokenPrice == 0 ? valueUsd : mulDiv(valueUsd, SCALING_FACTOR, marketTokenPrice);
    }

    function _calculateUsdValue(
        bool _isLongToken,
        uint256 _longBaseUnit,
        uint256 _shortBaseUnit,
        uint256 _price,
        uint256 _amount
    ) internal pure returns (uint256 valueUsd) {
        if (_isLongToken) {
            valueUsd = mulDiv(_amount, _price, _longBaseUnit);
        } else {
            valueUsd = mulDiv(_amount, _price, _shortBaseUnit);
        }
    }

    function _generateKey(address owner, address tokenIn, uint256 amountIn, uint256 blockNumber)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(owner, tokenIn, amountIn, blockNumber));
    }
}
