// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IMarket} from "../markets/interfaces/IMarket.sol";
import {Fee} from "../libraries/Fee.sol";
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
        IMarket market;
        IProcessor processor;
        IPriceFeed priceFeed;
        Data data;
        bytes32 key;
        int256 cumulativePnl;
        bool isLongToken;
        bool shouldUnwrap;
    }

    event WithdrawalExecuted(
        bytes32 indexed key,
        address indexed owner,
        address indexed tokenOut,
        uint256 marketTokenAmountIn,
        uint256 amountOut
    );

    error Withdrawal_InvalidOwner();
    error Withdrawal_DepositNotExpired();
    error Withdrawal_InsufficientLongBalance();
    error Withdrawal_InsufficientShortBalance();
    error Withdrawal_InvalidPrices();

    function validateCancellation(Data memory _data, address _caller) internal view {
        if (_data.input.owner != _caller) revert Withdrawal_InvalidOwner();
        if (_data.expirationTimestamp >= block.timestamp) revert Withdrawal_DepositNotExpired();
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

    function _generateKey(address owner, address tokenOut, uint256 marketTokenAmountIn, uint256 blockNumber)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(owner, tokenOut, marketTokenAmountIn, blockNumber));
    }
}
