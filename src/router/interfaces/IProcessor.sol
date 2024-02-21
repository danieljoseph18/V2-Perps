// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {Position} from "../../positions/Position.sol";
import {IMarket} from "../../markets/interfaces/IMarket.sol";
import {IPriceFeed} from "../../oracle/interfaces/IPriceFeed.sol";

interface IProcessor {
    error OrderProcessor_InvalidRequestType();

    event ExecutePosition(bytes32 indexed _orderKey, Position.Request _request, uint256 _fee, uint256 _feeDiscount);
    event GasLimitsUpdated(
        uint256 indexed depositGasLimit, uint256 indexed withdrawalGasLimit, uint256 indexed positionGasLimit
    );
    event AdlExecuted(IMarket indexed market, bytes32 indexed positionKey, uint256 sizeDelta, bool isLong);

    function updatePriceFeed(IPriceFeed _priceFeed) external;
    function transferDepositTokens(address _token, uint256 _amount) external;
    function depositGasLimit() external view returns (uint256);
    function withdrawalGasLimit() external view returns (uint256);
    function positionGasLimit() external view returns (uint256);
    function sendExecutionFee(address payable _to, uint256 _amount) external;
    function baseGasLimit() external view returns (uint256);
}
