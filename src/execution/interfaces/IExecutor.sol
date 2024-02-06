// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

interface IExecutor {
    function transferDepositTokens(address _token, uint256 _amount) external;
}
