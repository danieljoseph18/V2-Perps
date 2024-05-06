// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {MarketId} from "../../types/MarketId.sol";
import {Position} from "../Position.sol";
import {Execution} from "../Execution.sol";

interface ITradeEngine {
    function executePositionRequest(MarketId _id, Position.Settlement memory _params)
        external
        returns (Execution.FeeState memory, Position.Request memory);
    function executeAdl(MarketId _id, bytes32 _positionKey, bytes32 _requestKey, address _feeReceiver) external;
    function liquidatePosition(MarketId _id, bytes32 _positionKey, bytes32 _requestKey, address _liquidator) external;
    function tradingFee() external view returns (uint64);
    function feeForExecution() external view returns (uint64);
}
