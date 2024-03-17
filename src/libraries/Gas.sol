// SPDX-License-Identifier: MIT
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

    /**
     * https://github.com/Synthetixio/external-nodes/blob/main/src/TxGasPriceOracle.sol
     */
    error Gas_InsufficientMsgValue(uint256 valueSent, uint256 executionFee);
    error Gas_InsufficientExecutionFee(uint256 executionFee, uint256 minExecutionFee);

    // @add -> If stop loss and take profit, add gas price for each that exists
    function validateExecutionFee(IProcessor processor, uint256 _executionFee, uint256 _msgValue, Action _action)
        external
        view
    {
        if (_msgValue < _executionFee) {
            revert Gas_InsufficientMsgValue(_msgValue, _executionFee);
        }
        uint256 expectedGasLimit = getLimitForAction(processor, _action);
        uint256 minExecutionFee = getMinExecutionFee(processor, expectedGasLimit);
        if (_executionFee < minExecutionFee) {
            revert Gas_InsufficientExecutionFee(_executionFee, minExecutionFee);
        }
    }

    // @audit - is this vulnerable?
    function payExecutionFee(
        IProcessor self,
        uint256 _executionFee,
        uint256 _initialGas,
        address payable _executor,
        address payable _refundReceiver
    ) external {
        // See EIP 150
        _initialGas -= gasleft() / 63;
        uint256 gasUsed = _initialGas - gasleft();

        uint256 baseGasLimit = self.baseGasLimit();
        uint256 feeForExecutor = (baseGasLimit + gasUsed) * tx.gasprice;

        // Ensure we do not send more than the execution fee provided
        if (feeForExecutor > _executionFee) {
            feeForExecutor = _executionFee;
        }

        // Send the execution fee to the executor
        if (feeForExecutor > 0) self.sendExecutionFee(_executor, feeForExecutor);

        // Calculate the amount to refund to the refund receiver
        uint256 feeToRefund = _executionFee - feeForExecutor;
        if (feeToRefund > 0) {
            self.sendExecutionFee(_refundReceiver, feeToRefund);
        }
    }

    // Refund Gas the executor has spent updating the price feed at the end of a transaction
    function refundPriceUpdateGas(IProcessor processor, uint256 _initialGas, address payable _executor) external {
        _initialGas -= gasleft() / 63;
        uint256 gasUsed = _initialGas - gasleft();
        uint256 baseGasLimit = processor.baseGasLimit();
        uint256 feeForExecutor = (baseGasLimit + gasUsed) * tx.gasprice;
        processor.sendExecutionFee(_executor, feeForExecutor);
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
