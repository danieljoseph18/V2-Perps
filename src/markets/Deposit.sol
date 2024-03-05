//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {Fee} from "../libraries/Fee.sol";
import {Pool} from "./Pool.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {IPriceFeed} from "../oracle/interfaces/IPriceFeed.sol";
import {Oracle} from "../oracle/Oracle.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IProcessor} from "../router/interfaces/IProcessor.sol";

library Deposit {
    using SignedMath for int256;
    using SafeCast for uint256;

    uint256 public constant MIN_SLIPPAGE = 0.0001e18; // 0.01%
    uint256 public constant MAX_SLIPPAGE = 0.9999e18; // 99.99%
    uint256 public constant SCALING_FACTOR = 1e18;

    struct Input {
        address owner;
        address tokenIn;
        uint256 amountIn;
        uint256 executionFee;
        bool shouldWrap;
    }

    struct Data {
        Input input;
        uint256 blockNumber;
        uint48 expirationTimestamp;
        bytes32 key;
    }

    struct ExecuteParams {
        IMarket market;
        IProcessor processor;
        IPriceFeed priceFeed;
        Data data;
        Pool.Values values;
        bytes32 key;
        int256 cumulativePnl;
        bool isLongToken;
    }

    struct ExecutionState {
        Oracle.Price longPrices;
        Oracle.Price shortPrices;
        Fee.Params feeParams;
        uint256 fee;
        uint256 afterFeeAmount;
        uint256 mintAmount;
    }

    function validateCancellation(Data memory _data, address _caller) internal view {
        require(_data.input.owner == _caller, "Deposit: invalid owner");
        require(_data.expirationTimestamp < block.timestamp, "Deposit: deposit not expired");
    }

    function create(Input memory _input, uint48 _minTimeToExpiration) external view returns (Data memory data) {
        uint256 blockNumber = block.number;
        data = Data({
            input: _input,
            blockNumber: blockNumber,
            expirationTimestamp: uint48(block.timestamp) + _minTimeToExpiration,
            key: _generateKey(_input.owner, _input.tokenIn, _input.amountIn, blockNumber)
        });
    }

    function execute(ExecuteParams memory _params) external view returns (ExecutionState memory state) {
        // If prices were signed, return for the block, else, return prices
        if (Oracle.priceWasSigned(_params.priceFeed, _params.data.input.tokenIn, _params.data.blockNumber)) {
            (state.longPrices, state.shortPrices) =
                Oracle.getMarketTokenPrices(_params.priceFeed, _params.data.blockNumber);
        } else {
            (state.longPrices, state.shortPrices) = Oracle.getLastMarketTokenPrices(_params.priceFeed);
        }

        // Calculate Fee
        state.feeParams = Fee.constructFeeParams(
            _params.market,
            _params.data.input.amountIn,
            _params.isLongToken,
            _params.values,
            state.longPrices,
            state.shortPrices,
            true
        );
        state.fee = Fee.calculateForMarketAction(state.feeParams);
        require(state.fee > 0, "Deposit: zero fee");

        // Calculate remaining after fee
        state.afterFeeAmount = _params.data.input.amountIn - state.fee;

        // Calculate Mint amount with the remaining amount
        state.mintAmount = Pool.depositTokensToMarketTokens(
            _params.values,
            state.longPrices,
            state.shortPrices,
            state.afterFeeAmount,
            _params.cumulativePnl,
            _params.isLongToken
        );
    }

    function _generateKey(address owner, address tokenIn, uint256 amountIn, uint256 blockNumber)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(owner, tokenIn, amountIn, blockNumber));
    }
}
