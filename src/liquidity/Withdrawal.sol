//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {IDataOracle} from "../oracle/interfaces/IDataOracle.sol";
import {IPriceOracle} from "../oracle/interfaces/IPriceOracle.sol";
import {ILiquidityVault} from "./interfaces/ILiquidityVault.sol";
import {Fee} from "../libraries/Fee.sol";
import {PriceImpact} from "../libraries/PriceImpact.sol";
import {mulDiv} from "@prb/math/Common.sol";
import {Pool} from "./Pool.sol";
import {MarketUtils} from "../markets/MarketUtils.sol";

library Withdrawal {
    uint256 public constant MIN_SLIPPAGE = 0.0001e18; // 0.01%
    uint256 public constant MAX_SLIPPAGE = 0.9999e18; // 99.99%
    uint256 public constant SCALING_FACTOR = 1e18;

    struct Params {
        address owner;
        address tokenOut;
        uint256 marketTokenAmountIn;
        uint256 executionFee;
        uint256 maxSlippage;
        bool shouldUnwrap;
    }

    struct Data {
        Params params;
        uint256 blockNumber;
        uint48 expirationTimestamp;
    }

    function validateCancellation(Data memory _data, address _caller) internal view {
        require(_data.params.owner == _caller, "Withdrawal: invalid owner");
        require(_data.expirationTimestamp < block.timestamp, "Withdrawal: deposit not expired");
    }

    function create(IDataOracle _dataOracle, Params memory _params, uint48 _minTimeToExpiration)
        external
        returns (Data memory data, bytes32 key)
    {
        uint256 blockNumber = block.number;
        data = Data({
            params: _params,
            blockNumber: blockNumber,
            expirationTimestamp: uint48(block.timestamp) + _minTimeToExpiration
        });

        // Request Required Data for the Block
        _dataOracle.requestBlockData(blockNumber);

        key = _generateKey(_params.owner, _params.tokenOut, _params.marketTokenAmountIn, blockNumber);
    }

    function execute(
        ILiquidityVault _liquidityVault,
        Data memory _data,
        Pool.Values memory _values,
        bool _isLongToken,
        uint8 _priceImpactExponent,
        uint256 _priceImpactFactor
    ) external view returns (uint256 amountOut, uint256 fee, uint256 remaining) {
        // get price signed to the block number of the request
        (uint256 longTokenPrice, uint256 shortTokenPrice) =
            MarketUtils.validateAndRetrievePrices(_values.dataOracle, _data.blockNumber);
        // Calculate amountOut
        uint256 tokenAmount = _calculateTokenAmount(_isLongToken, _values, longTokenPrice, shortTokenPrice);
        // Calculate impacted price
        uint256 impactedPrice = _calculateImpactedPrice(
            _values,
            _isLongToken,
            amountOut,
            _data.params.maxSlippage,
            longTokenPrice,
            shortTokenPrice,
            _priceImpactExponent,
            _priceImpactFactor
        );

        amountOut = _applyImpactToTokens(tokenAmount, impactedPrice, _isLongToken ? longTokenPrice : shortTokenPrice);

        // Calculate fee and remaining amount in separate functions to reduce stack depth
        fee = Fee.calculateForMarket(_liquidityVault, _data.params.marketTokenAmountIn);
        // calculate amount remaining after fee and price impact
        remaining = amountOut - fee;
    }

    /////////////////////////////////////////////////////////
    // INTERNAL FUNCTIONS: To Prevent Stack Too Deep Error //
    /////////////////////////////////////////////////////////

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
        impactedPrice = PriceImpact.executeForMarket(
            PriceImpact.Params({
                longTokenBalance: _values.longTokenBalance,
                shortTokenBalance: _values.shortTokenBalance,
                longTokenPrice: _longTokenPrice,
                shortTokenPrice: _shortTokenPrice,
                amountIn: _amountIn,
                maxSlippage: _maxSlippage,
                isIncrease: false,
                isLongToken: _isLongToken,
                longBaseUnit: _values.longBaseUnit,
                shortBaseUnit: _values.shortBaseUnit
            }),
            _priceImpactExponent,
            _priceImpactFactor
        );
    }

    function _applyImpactToTokens(uint256 _tokenAmount, uint256 _impactedPrice, uint256 _signedPrice)
        internal
        pure
        returns (uint256 amountOut)
    {
        return mulDiv(_tokenAmount, _impactedPrice, _signedPrice);
    }

    function _calculateTokenAmount(
        bool _isLongToken,
        Pool.Values memory _values,
        uint256 _longTokenPrice,
        uint256 _shortTokenPrice
    ) internal view returns (uint256 amountOut) {
        uint256 lpTokenPrice = Pool.getMarketTokenPrice(_values, _longTokenPrice, _shortTokenPrice);
        uint256 marketTokenValueUsd = mulDiv(lpTokenPrice, _values.marketTokenSupply, SCALING_FACTOR);
        amountOut = _isLongToken
            ? mulDiv(marketTokenValueUsd, _values.longBaseUnit, _longTokenPrice)
            : mulDiv(marketTokenValueUsd, _values.shortBaseUnit, _shortTokenPrice);
    }

    function _generateKey(address owner, address tokenOut, uint256 marketTokenAmountIn, uint256 blockNumber)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(owner, tokenOut, marketTokenAmountIn, blockNumber));
    }
}
