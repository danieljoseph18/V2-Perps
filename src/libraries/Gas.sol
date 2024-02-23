// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {IProcessor} from "../router/interfaces/IProcessor.sol";
import {mulDiv} from "@prb/math/Common.sol";

library Gas {
    uint256 private constant CANCELLATION_PENALTY = 0.2e18; // 20%
    uint256 private constant SCALING_FACTOR = 1e18;

    enum Action {
        DEPOSIT,
        WITHDRAW,
        POSITION
    }

    function validateExecutionFee(IProcessor processor, uint256 _executionFee, uint256 _msgValue, Action _action)
        external
        view
    {
        require(_msgValue >= _executionFee, "Gas: Insufficient msg value");
        uint256 expectedGasLimit = getLimitForAction(processor, _action);
        uint256 minExecutionFee = getMinExecutionFee(processor, expectedGasLimit);
        require(_executionFee >= minExecutionFee, "Gas: Insufficient execution fee");
    }

    // @audit - is this vulnerable?
    function payExecutionFee(
        IProcessor processor,
        uint256 _executionFee,
        uint256 _initialGas,
        address payable _executor,
        address payable _refundReceiver
    ) external {
        // See EIP 150
        _initialGas -= gasleft() / 63;
        uint256 gasUsed = _initialGas - gasleft();

        uint256 baseGasLimit = processor.baseGasLimit();
        uint256 feeForExecutor = (baseGasLimit + gasUsed) * tx.gasprice;

        // Ensure we do not send more than the execution fee provided
        if (feeForExecutor > _executionFee) {
            feeForExecutor = _executionFee;
        }

        // Send the execution fee to the executor
        if (feeForExecutor > 0) processor.sendExecutionFee(_executor, feeForExecutor);

        // Calculate the amount to refund to the refund receiver
        uint256 feeToRefund = _executionFee - feeForExecutor;
        if (feeToRefund > 0) {
            processor.sendExecutionFee(_refundReceiver, feeToRefund);
        }
    }

    function getLimitForAction(IProcessor processor, Action _action) public view returns (uint256 gasLimit) {
        if (_action == Action.DEPOSIT) {
            gasLimit = processor.depositGasLimit();
        } else if (_action == Action.WITHDRAW) {
            gasLimit = processor.withdrawalGasLimit();
        } else if (_action == Action.POSITION) {
            gasLimit = processor.positionGasLimit();
        } else {
            revert("Gas: Invalid Action");
        }
    }

    function getMinExecutionFee(IProcessor processor, uint256 _expectedGasLimit)
        public
        view
        returns (uint256 minExecutionFee)
    {
        uint256 baseGasLimit = processor.baseGasLimit();
        minExecutionFee = (baseGasLimit + _expectedGasLimit) * tx.gasprice;
    }

    function getRefundForCancellation(uint256 _executionFee) public pure returns (uint256) {
        return mulDiv(_executionFee, CANCELLATION_PENALTY, SCALING_FACTOR);
    }
}
