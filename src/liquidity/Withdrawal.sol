//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {ILiquidityVault} from "./interfaces/ILiquidityVault.sol";
import {Fee} from "../libraries/Fee.sol";
import {Pool} from "./Pool.sol";
import {IPriceFeed} from "../oracle/interfaces/IPriceFeed.sol";
import {Oracle} from "../oracle/Oracle.sol";
import {IProcessor} from "../router/interfaces/IProcessor.sol";

library Withdrawal {
    uint256 public constant MIN_SLIPPAGE = 0.0001e18; // 0.01%
    uint256 public constant MAX_SLIPPAGE = 0.9999e18; // 99.99%
    uint256 public constant SCALING_FACTOR = 1e18;

    struct Input {
        address owner;
        address tokenOut;
        uint256 marketTokenAmountIn;
        uint256 executionFee;
        bool shouldUnwrap;
    }

    struct Data {
        Input input;
        uint256 blockNumber;
        uint48 expirationTimestamp;
        bytes32 key;
    }

    struct ExecuteParams {
        ILiquidityVault liquidityVault;
        IProcessor processor;
        IPriceFeed priceFeed;
        Data data;
        Pool.Values values;
        bytes32 key;
        int256 cumulativePnl;
        bool isLongToken;
        bool shouldUnwrap;
    }

    struct ExecuteCache {
        Oracle.Price longPrices;
        Oracle.Price shortPrices;
        Fee.Params feeParams;
        uint256 fee;
        uint256 totalTokensOut;
        uint256 amountOut;
    }

    event WithdrawalExecuted(
        bytes32 indexed key,
        address indexed owner,
        address indexed tokenOut,
        uint256 marketTokenAmountIn,
        uint256 amountOut
    );

    function validateCancellation(Data memory _data, address _caller) internal view {
        require(_data.input.owner == _caller, "Withdrawal: invalid owner");
        require(_data.expirationTimestamp < block.timestamp, "Withdrawal: deposit not expired");
    }

    function create(Input memory _input, uint48 _minTimeToExpiration) external view returns (Data memory data) {
        uint256 blockNumber = block.number;
        data = Data({
            input: _input,
            blockNumber: blockNumber,
            expirationTimestamp: uint48(block.timestamp) + _minTimeToExpiration,
            key: _generateKey(_input.owner, _input.tokenOut, _input.marketTokenAmountIn, blockNumber)
        });
    }

    function execute(ExecuteParams memory _params) external view returns (ExecuteCache memory cache) {
        // get price signed to the block number of the request
        if (Oracle.priceWasSigned(_params.priceFeed, _params.data.input.tokenOut, _params.data.blockNumber)) {
            (cache.longPrices, cache.shortPrices) =
                Oracle.getMarketTokenPrices(_params.priceFeed, _params.data.blockNumber);
        } else {
            (cache.longPrices, cache.shortPrices) = Oracle.getLastMarketTokenPrices(_params.priceFeed);
        }
        // Calculate amountOut
        cache.totalTokensOut = Pool.withdrawMarketTokensToTokens(
            _params.values,
            cache.longPrices,
            cache.shortPrices,
            _params.data.input.marketTokenAmountIn,
            _params.cumulativePnl,
            _params.isLongToken
        );

        if (_params.isLongToken) {
            require(cache.totalTokensOut <= _params.values.longTokenBalance, "Withdrawal: insufficient balance");
        } else {
            require(cache.totalTokensOut <= _params.values.shortTokenBalance, "Withdrawal: insufficient balance");
        }

        // Calculate Fee
        cache.feeParams = Fee.constructFeeParams(
            _params.liquidityVault,
            cache.totalTokensOut,
            _params.isLongToken,
            _params.values,
            cache.longPrices,
            cache.shortPrices,
            false
        );
        cache.fee = Fee.calculateForMarketAction(cache.feeParams);

        // calculate amount remaining after fee and price impact
        cache.amountOut = cache.totalTokensOut - cache.fee;
    }

    function _generateKey(address owner, address tokenOut, uint256 marketTokenAmountIn, uint256 blockNumber)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(owner, tokenOut, marketTokenAmountIn, blockNumber));
    }
}
