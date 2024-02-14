// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

interface IProcessor {
    function transferDepositTokens(address _token, uint256 _amount) external;
    function depositGasLimit() external view returns (uint256);
    function withdrawalGasLimit() external view returns (uint256);
    function positionGasLimit() external view returns (uint256);
    function sendExecutionFee(address payable _to, uint256 _amount) external;
    function baseGasLimit() external view returns (uint256);
}
