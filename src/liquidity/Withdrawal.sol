//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {IDataOracle} from "../oracle/interfaces/IDataOracle.sol";
import {IPriceOracle} from "../oracle/interfaces/IPriceOracle.sol";
import {Fee} from "../libraries/Fee.sol";
import {PriceImpact} from "../libraries/PriceImpact.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Pool} from "./Pool.sol";

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
    }

    struct Data {
        Params params;
        uint256 blockNumber;
        uint48 expirationTimestamp;
    }

    function validateParameters(Params memory _params, uint256 _executionFee) external view {
        require(_params.executionFee >= _executionFee, "Withdrawal: execution fee too low");
        require(msg.value == _params.executionFee, "Withdrawal: invalid execution fee");
        require(_params.owner == msg.sender, "Withdrawal: invalid owner");
        require(
            _params.maxSlippage < MAX_SLIPPAGE && _params.maxSlippage > MIN_SLIPPAGE, "Withdrawal: invalid slippage"
        );
    }

    function validateCancellation(Data memory _data) internal view {
        require(_data.params.owner == msg.sender, "Withdrawal: invalid owner");
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
        Data memory _data,
        Pool.Values memory _values,
        bool _isLongToken,
        uint8 _priceImpactExponent,
        uint256 _priceImpactFactor
    ) external view returns (uint256 amountOut, uint256 fee, uint256 remaining) {
        // get price signed to the block number of the request
        (uint256 longTokenPrice, uint256 shortTokenPrice) =
            _validateAndRetrievePrices(_values.dataOracle, _data.blockNumber);
        // calculate the value of the assets provided
        // Calculate impacted price
        uint256 impactedPrice = _calculateImpactedPrice(
            _values,
            _isLongToken,
            _data.params.marketTokenAmountIn,
            _data.params.maxSlippage,
            longTokenPrice,
            shortTokenPrice,
            _priceImpactExponent,
            _priceImpactFactor
        );

        // Calculate amountOut
        amountOut = _calculateAmountOut(_isLongToken, impactedPrice, _values, longTokenPrice, shortTokenPrice);

        // Calculate fee and remaining amount in separate functions to reduce stack depth
        fee = _calculateFee(_data, _values, _isLongToken, longTokenPrice, shortTokenPrice);
        // calculate amount remaining after fee and price impact
        remaining = amountOut - fee;
    }

    /////////////////////////////////////////////////////////
    // INTERNAL FUNCTIONS: To Prevent Stack Too Deep Error //
    /////////////////////////////////////////////////////////

    function _calculateImpactedPrice(
        Pool.Values memory _values,
        bool _isLongToken,
        uint256 _marketTokenAmountIn,
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
                amount: _marketTokenAmountIn,
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

    function _calculateFee(
        Data memory _data,
        Pool.Values memory _values,
        bool _isLongToken,
        uint256 _longTokenPrice,
        uint256 _shortTokenPrice
    ) internal pure returns (uint256 fee) {
        fee = Fee.calculateForMarketAction(
            _data.params.marketTokenAmountIn,
            _values.longTokenBalance,
            _longTokenPrice,
            _values.longBaseUnit,
            _values.shortTokenBalance,
            _shortTokenPrice,
            _values.shortBaseUnit,
            _isLongToken
        );
    }

    function _validateAndRetrievePrices(IDataOracle _dataOracle, uint256 _blockNumber)
        internal
        view
        returns (uint256, uint256)
    {
        (bool isValid,,,, uint256 longTokenPrice, uint256 shortTokenPrice) = _dataOracle.blockData(_blockNumber);
        require(isValid, "Withdrawal: invalid block data");
        require(longTokenPrice > 0 && shortTokenPrice > 0, "Withdrawal: invalid token prices");
        return (longTokenPrice, shortTokenPrice);
    }

    function _calculateAmountOut(
        bool _isLongToken,
        uint256 _impactedPrice,
        Pool.Values memory _values,
        uint256 _longTokenPrice,
        uint256 _shortTokenPrice
    ) internal view returns (uint256 amountOut) {
        uint256 lpTokenPrice = Pool.getMarketTokenPrice(_values, _longTokenPrice, _shortTokenPrice);
        uint256 marketTokenValueUsd = Math.mulDiv(lpTokenPrice, _values.marketTokenSupply, SCALING_FACTOR);
        amountOut = _isLongToken
            ? Math.mulDiv(marketTokenValueUsd, _values.longBaseUnit, _impactedPrice)
            : Math.mulDiv(marketTokenValueUsd, _values.shortBaseUnit, _impactedPrice);
    }

    function _generateKey(address owner, address tokenOut, uint256 marketTokenAmountIn, uint256 blockNumber)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(owner, tokenOut, marketTokenAmountIn, blockNumber));
    }
}
