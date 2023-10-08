// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {MarketStructs} from "../../markets/MarketStructs.sol";

interface ITradeStorage {
    function createMarketOrderRequest(MarketStructs.PositionRequest calldata _positionRequest) external;
    function executeTrade(
        MarketStructs.PositionRequest memory _positionRequest,
        uint256 _signedBlockPrice,
        address _executor
    ) external returns (MarketStructs.Position memory);
    function createLimitOrderRequest(MarketStructs.PositionRequest calldata _positionRequest) external;
    function createSwapOrderRequest() external;
    function getMarketOrderKeys() external view returns (bytes32[] memory, bytes32[] memory);
    function getRequestQueueLengths() external view returns (uint256, uint256, uint256, uint256, uint256);

    // Optional: Getter functions for state variables if needed
    function marketOrderRequests(bytes32 _key) external view returns (MarketStructs.PositionRequest memory);
    function marketOrderKeys(uint256 _index) external view returns (bytes32);
    function limitOrderRequests(bytes32 _key) external view returns (MarketStructs.PositionRequest memory);
    function limitOrderKeys(uint256 _index) external view returns (bytes32);
    function swapOrderRequests(bytes32 _key) external view returns (MarketStructs.PositionRequest memory);
    function swapOrderKeys(uint256 _index) external view returns (bytes32);
    function marketDecreaseRequests(bytes32 _key)
        external
        view
        returns (MarketStructs.DecreasePositionRequest memory);
    function marketDecreaseKeys(uint256 _index) external view returns (bytes32);
    function limitDecreaseRequests(bytes32 _key) external view returns (MarketStructs.DecreasePositionRequest memory);
    function limitDecreaseKeys(uint256 _index) external view returns (bytes32);
    function openPositions(bytes32 _key) external view returns (MarketStructs.Position memory);
    function openLongPositionKeys(bytes32 _key) external view returns (bytes32[] memory);
    function openShortPositionKeys(bytes32 _key) external view returns (bytes32[] memory);
    function openPositionIndex(bytes32 _key) external view returns (uint256);
    function marketStorage() external view returns (address);
    function createMarketDecreaseRequest(MarketStructs.DecreasePositionRequest memory _decreaseRequest) external;
    function createLimitDecreaseRequest(MarketStructs.DecreasePositionRequest memory _decreaseRequest) external;
    function cancelOrderRequest(bytes32 _key, bool _isLimit) external;
    function executeDecreaseRequest(
        MarketStructs.DecreasePositionRequest memory _decreaseRequest,
        uint256 _signedBlockPrice,
        address _executor
    ) external;
    function liquidationFeeUsd() external view returns (uint256);
    function liquidatePosition(bytes32 _positionKey) external;
    function getPositionFees(MarketStructs.Position memory _position)
        external
        view
        returns (uint256, int256, uint256);
    function tradingFee() external view returns (uint256);
    function minExecutionFee() external view returns (uint256);
    function setFees(uint256 _liquidationFee, uint256 _tradingFee) external;
}
