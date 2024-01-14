// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {Request} from "../../structs/Request.sol";
import {Position} from "../../structs/Position.sol";

interface ITradeStorage {
    function initialise(uint256 _liquidationFee, uint256 _tradingFee, uint256 _executionFee) external;
    function createOrderRequest(Request.Data calldata _request) external;
    function cancelOrderRequest(bytes32 _orderKey, bool _isLimit) external;
    function executeCollateralIncrease(Request.Execution calldata _params) external;
    function executeCollateralDecrease(Request.Execution calldata _params) external;
    function createNewPosition(Request.Execution calldata _params) external;
    function increaseExistingPosition(Request.Execution calldata _params) external;
    function decreaseExistingPosition(Request.Execution calldata _params) external;
    function liquidatePosition(bytes32 _positionKey, address _liquidator, uint256 _collateralPrice) external;
    function setFees(uint256 _liquidationFee, uint256 _tradingFee) external;
    function claimFundingFees(bytes32 _positionKey) external;
    function getOpenPositionKeys(bytes32 _marketKey, bool _isLong) external view returns (bytes32[] memory);
    function getOrderKeys(bool _isLimit) external view returns (bytes32[] memory orderKeys);
    function getRequestQueueLengths() external view returns (uint256 marketLen, uint256 limitLen);
    function orders(bytes32 _key) external view returns (Request.Data memory);
    function openPositions(bytes32 _key) external view returns (Position.Data memory);
    function minCollateralUsd() external view returns (uint256);
    function executionFee() external view returns (uint256);
}
