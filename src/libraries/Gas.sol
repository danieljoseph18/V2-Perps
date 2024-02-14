// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {IProcessor} from "../router/interfaces/IProcessor.sol";

library Gas {
    enum Action {
        DEPOSIT,
        WITHDRAW,
        POSITION
    }

    function getLimitForAction(IProcessor _processor, Action _action) external view returns (uint256 gasLimit) {
        if (_action == Action.DEPOSIT) {
            gasLimit = _processor.depositGasLimit();
        } else if (_action == Action.WITHDRAW) {
            gasLimit = _processor.withdrawalGasLimit();
        } else if (_action == Action.POSITION) {
            gasLimit = _processor.positionGasLimit();
        } else {
            revert("Gas: Invalid Action");
        }
    }

    function getMinExecutionFee(IProcessor _processor, uint256 _expectedGasLimit)
        external
        view
        returns (uint256 minExecutionFee)
    {
        uint256 baseGasLimit = _processor.baseGasLimit();
        minExecutionFee = (baseGasLimit + _expectedGasLimit) * tx.gasprice;
    }

    function payExecutionFee(
        IProcessor _processor,
        uint256 _executionFee,
        uint256 _initialGas,
        address payable _executor,
        address payable _refundReceiver
    ) external {
        // See EIP 150
        _initialGas -= gasleft() / 63;
        uint256 gasUsed = _initialGas - gasleft();

        uint256 baseGasLimit = _processor.baseGasLimit();
        uint256 feeForExecutor = (baseGasLimit + gasUsed) * tx.gasprice;

        // Ensure we do not send more than the execution fee provided
        if (feeForExecutor > _executionFee) {
            feeForExecutor = _executionFee;
        }

        // Send the execution fee to the executor
        _processor.sendExecutionFee(_executor, feeForExecutor);

        // Calculate the amount to refund to the refund receiver
        uint256 feeToRefund = _executionFee - feeForExecutor;
        if (feeToRefund > 0) {
            _processor.sendExecutionFee(_refundReceiver, feeToRefund);
        }
    }
}
