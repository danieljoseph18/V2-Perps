//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

library Deposit {
    struct Params {
        address owner;
        address tokenIn;
        uint256 amountIn;
        uint256 executionFee;
        uint256 maxSlippage;
    }

    struct Data {
        Params params;
        uint32 blockNumber;
        uint32 expirationTimestamp;
    }

    function generateKey(address owner, address tokenIn, uint256 amountIn, uint32 blockNumber)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(owner, tokenIn, amountIn, blockNumber));
    }
}
