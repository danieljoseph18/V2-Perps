//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {IDataOracle} from "../oracle/interfaces/IDataOracle.sol";
import {IPriceOracle} from "../oracle/interfaces/IPriceOracle.sol";
import {Fee} from "../libraries/Fee.sol";
import {PriceImpact} from "../libraries/PriceImpact.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Pool} from "./Pool.sol";

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
    }

    struct Data {
        Params params;
        uint256 blockNumber;
        uint48 expirationTimestamp;
    }

    function validateParameters(Params memory _params, uint256 _executionFee) internal view {
        require(_params.executionFee >= _executionFee, "Deposit: execution fee too low");
        require(msg.value == _params.executionFee, "Deposit: invalid execution fee");
        require(_params.maxSlippage < MAX_SLIPPAGE && _params.maxSlippage > MIN_SLIPPAGE, "Deposit: invalid slippage");
    }

    function validateCancellation(Data memory _data) internal view {
        require(_data.params.owner == msg.sender, "Deposit: invalid owner");
        require(_data.expirationTimestamp < block.timestamp, "Deposit: deposit not expired");
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

        key = _generateKey(_params.owner, _params.tokenIn, _params.amountIn, blockNumber);
    }

    function execute(
        Data memory _data,
        Pool.Values memory _values,
        bool _isLongToken,
        uint8 _priceImpactExponent,
        uint256 _priceImpactFactor
    ) external view returns (uint256 mintAmount, uint256 fee, uint256 remaining) {
        // Get token price and calculate price impact directly to reduce local variables
        uint256 tokenPrice = _values.priceOracle.getSignedPrice(_data.params.tokenIn, _data.blockNumber);
        uint256 impactedPrice =
            _calculateImpactedPrice(_data, _values, _isLongToken, tokenPrice, _priceImpactExponent, _priceImpactFactor);

        // Calculate fee based on the impacted price
        fee = _calculateFee(_data, _values, _isLongToken, tokenPrice, impactedPrice);

        // Calculate remaining after fee
        remaining = _data.params.amountIn - fee;

        // Mint amount calculation is now more streamlined
        mintAmount = _calculateMintAmount(
            _isLongToken ? _values.longBaseUnit : _values.shortBaseUnit, impactedPrice, remaining, _values
        );
    }

    // Assumes impactedPrice calculation can be isolated
    function _calculateImpactedPrice(
        Data memory _data,
        Pool.Values memory _values,
        bool _isLongToken,
        uint256 tokenPrice,
        uint8 _priceImpactExponent,
        uint256 _priceImpactFactor
    ) internal pure returns (uint256) {
        return PriceImpact.executeForMarket(
            PriceImpact.Params({
                longTokenBalance: _values.longTokenBalance,
                shortTokenBalance: _values.shortTokenBalance,
                longTokenPrice: tokenPrice,
                shortTokenPrice: tokenPrice,
                amount: _data.params.amountIn,
                maxSlippage: _data.params.maxSlippage,
                isIncrease: true,
                isLongToken: _isLongToken,
                longBaseUnit: _values.longBaseUnit,
                shortBaseUnit: _values.shortBaseUnit
            }),
            _priceImpactExponent,
            _priceImpactFactor
        );
    }

    // Assumes fee calculation can be isolated
    function _calculateFee(
        Data memory _data,
        Pool.Values memory _values,
        bool _isLongToken,
        uint256 tokenPrice,
        uint256 impactedPrice
    ) internal pure returns (uint256 fee) {
        fee = Fee.calculateForMarketAction(
            _data.params.amountIn,
            _values.longTokenBalance,
            tokenPrice,
            _values.longBaseUnit,
            _values.shortTokenBalance,
            impactedPrice, // Assuming impacted price is used here for an example
            _values.shortBaseUnit,
            _isLongToken
        );
    }

    function _calculateMintAmount(uint256 baseUnit, uint256 price, uint256 remaining, Pool.Values memory _values)
        internal
        view
        returns (uint256)
    {
        uint256 valueUsd = Math.mulDiv(remaining, price, baseUnit);
        uint256 marketTokenPrice = Pool.getMarketTokenPrice(_values, price, price); // Assuming the same price for simplicity
        return marketTokenPrice == 0 ? valueUsd : Math.mulDiv(valueUsd, SCALING_FACTOR, marketTokenPrice);
    }

    function _calculateUsdValue(
        bool _isLongToken,
        uint256 _longBaseUnit,
        uint256 _shortBaseUnit,
        uint256 _price,
        uint256 _amount
    ) internal pure returns (uint256 valueUsd) {
        if (_isLongToken) {
            valueUsd = Math.mulDiv(_amount, _price, _longBaseUnit);
        } else {
            valueUsd = Math.mulDiv(_amount, _price, _shortBaseUnit);
        }
    }

    function _calculateMintAmount(
        uint256 _valueUsd,
        Pool.Values memory _values,
        uint256 _longTokenPrice,
        uint256 _shortTokenPrice
    ) internal view returns (uint256 mintAmount) {
        uint256 marketTokenPrice = Pool.getMarketTokenPrice(_values, _longTokenPrice, _shortTokenPrice);
        mintAmount = marketTokenPrice == 0 ? _valueUsd : Math.mulDiv(_valueUsd, SCALING_FACTOR, marketTokenPrice);
    }

    function _generateKey(address owner, address tokenIn, uint256 amountIn, uint256 blockNumber)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(owner, tokenIn, amountIn, blockNumber));
    }
}
