// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IPositionManager} from "../router/interfaces/IPositionManager.sol";
import {Oracle} from "../oracle/Oracle.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {IPriceFeed} from "../oracle/interfaces/IPriceFeed.sol";
import {mulDiv} from "@prb/math/Common.sol";

library Gas {
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
        IMarket market,
        uint256 _executionFee,
        uint256 _msgValue,
        Action _action
    ) external view {
        if (_msgValue < _executionFee) {
            revert Gas_InsufficientMsgValue(_msgValue, _executionFee);
        }
        uint256 estimatedFee = estimateExecutionFee(priceFeed, positionManager, market, _action);
        if (_executionFee < estimatedFee) {
            revert Gas_InsufficientExecutionFee(_executionFee, estimatedFee);
        }
    }

    function estimateExecutionFee(
        IPriceFeed priceFeed,
        IPositionManager positionManager,
        IMarket market,
        Action _action
    ) public view returns (uint256) {
        uint256 actionCost = _getActionCost(positionManager, _action);
        uint256 priceUpdateCost = _getPriceUpdateCost(priceFeed, market, _action == Action.POSITION);

        uint256 estimatedCost = actionCost + priceUpdateCost;
        uint256 bufferAmount = mulDiv(estimatedCost, BUFFER_PERCENTAGE, SCALING_FACTOR);

        return estimatedCost + bufferAmount;
    }

    function getRefundForCancellation(uint256 _executionFee) external pure returns (uint256) {
        return mulDiv(_executionFee, CANCELLATION_PENALTY, SCALING_FACTOR);
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

    function _getPriceUpdateCost(IPriceFeed priceFeed, IMarket market, bool _isPosition)
        private
        view
        returns (uint256)
    {
        // If a Position, only need to update Long, Short and Index asset prices
        // For markets, need to update all prices in the market to track the cumulative pnl
        uint256 priceUpdateCount = _isPosition ? 3 : market.getAssetsInMarket();

        uint256 baseCost = priceFeed.averagePriceUpdateCost();
        uint256 assetCost = priceFeed.additionalCostPerAsset() * priceUpdateCount;

        return baseCost + assetCost;
    }
}
