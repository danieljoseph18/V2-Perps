// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

library Block {
    struct Data {
        bool isValid;
        uint256 blockNumber;
        uint256 blockTimestamp;
        uint256 cumulativePnl;
    }
}
