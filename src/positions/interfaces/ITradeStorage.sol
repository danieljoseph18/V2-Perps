// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {PositionRequest} from "../../structs/PositionRequest.sol";
import {Position} from "../../structs/Position.sol";

interface ITradeStorage {
    function initialise(uint256 _liquidationFee, uint256 _tradingFee, uint256 _executionFee) external;
    function createOrderRequest(PositionRequest.Data calldata _request) external;
    function cancelOrderRequest(bytes32 _orderKey, bool _isLimit) external;
    function executeCollateralIncrease(PositionRequest.Execution calldata _params) external;
    function executeCollateralDecrease(PositionRequest.Execution calldata _params) external;
    function createNewPosition(PositionRequest.Execution calldata _params) external;
    function increaseExistingPosition(PositionRequest.Execution calldata _params) external;
    function decreaseExistingPosition(PositionRequest.Execution calldata _params) external;
    function liquidatePosition(bytes32 _positionKey, address _liquidator, uint256 _collateralPrice) external;
    function setFees(uint256 _liquidationFee, uint256 _tradingFee) external;
    function claimFundingFees(bytes32 _positionKey) external;
    function getOpenPositionKeys(bytes32 _marketKey, bool _isLong) external view returns (bytes32[] memory);
    function getOrderKeys(bool _isLimit) external view returns (bytes32[] memory orderKeys);
    function getRequestQueueLengths() external view returns (uint256 marketLen, uint256 limitLen);
    function orders(bytes32 _key) external view returns (PositionRequest.Data memory);
    function openPositions(bytes32 _key) external view returns (Position.Data memory);
    function minCollateralUsd() external view returns (uint256);
    function executionFee() external view returns (uint256);
}
