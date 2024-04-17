// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IPositionManager} from "../router/interfaces/IPositionManager.sol";
import {Oracle} from "../oracle/Oracle.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {IPriceFeed} from "../oracle/interfaces/IPriceFeed.sol";
import {MathUtils} from "./MathUtils.sol";

library Gas {
    using MathUtils for uint256;

    uint256 private constant CANCELLATION_PENALTY = 0.2e18; // 20%
    uint256 private constant SCALING_FACTOR = 1e18;
    uint256 private constant BUFFER_PERCENTAGE = 1.1e18; // 110%

    enum Action {
        DEPOSIT,
        WITHDRAW,
        POSITION,
        POSITION_WITH_LIMIT,
        POSITION_WITH_LIMITS
    }

    error Gas_InsufficientMsgValue(uint256 valueSent, uint256 executionFee);
    error Gas_InsufficientExecutionFee(uint256 executionFee, uint256 minExecutionFee);
    error Gas_InvalidActionType();

    function validateExecutionFee(
        IPriceFeed priceFeed,
        IPositionManager positionManager,
        uint256 _executionFee,
        uint256 _msgValue,
        Action _action,
        bool _hasPnlRequest,
        bool _isLimit
    ) external view returns (uint256 priceUpdateFee) {
        if (_msgValue < _executionFee) {
            revert Gas_InsufficientMsgValue(_msgValue, _executionFee);
        }
        uint256 estimatedFee;
        (estimatedFee, priceUpdateFee) =
            estimateExecutionFee(priceFeed, positionManager, _action, _hasPnlRequest, _isLimit);
        if (_executionFee < estimatedFee + priceUpdateFee) {
            revert Gas_InsufficientExecutionFee(_executionFee, estimatedFee);
        }
    }

    function estimateExecutionFee(
        IPriceFeed priceFeed,
        IPositionManager positionManager,
        Action _action,
        bool _hasPnlRequest,
        bool _isLimit
    ) public view returns (uint256 estimatedCost, uint256 priceUpdateCost) {
        uint256 actionCost = _getActionCost(positionManager, _action);
        priceUpdateCost = _getPriceUpdateCost(priceFeed, _hasPnlRequest, _isLimit);
        estimatedCost = (actionCost + priceUpdateCost).percentage(BUFFER_PERCENTAGE);
    }

    function getRefundForCancellation(uint256 _executionFee) external pure returns (uint256) {
        return _executionFee.percentage(CANCELLATION_PENALTY);
    }

    function _getActionCost(IPositionManager positionManager, Action _action) private view returns (uint256) {
        if (_action == Action.DEPOSIT) {
            return positionManager.averageDepositCost();
        } else if (_action == Action.WITHDRAW) {
            return positionManager.averageWithdrawalCost();
        } else if (_action == Action.POSITION) {
            return positionManager.averagePositionCost();
        } else if (_action == Action.POSITION_WITH_LIMIT) {
            return positionManager.averagePositionCost() * 2; // Eq 2x Positions
        } else if (_action == Action.POSITION_WITH_LIMITS) {
            return positionManager.averagePositionCost() * 3; // Eq 3x Positions
        } else {
            revert Gas_InvalidActionType();
        }
    }

    function _getPriceUpdateCost(IPriceFeed priceFeed, bool _hasPnlrequest, bool _isLimit)
        private
        view
        returns (uint256 estimatedCost)
    {
        // If limit, return 0
        if (_isLimit) return 0;
        // For PNL Requests, we double the cost as 2 feed updates are required
        estimatedCost =
            _hasPnlrequest ? 2 * Oracle.estimateRequestCost(priceFeed) : Oracle.estimateRequestCost(priceFeed);
    }
}
