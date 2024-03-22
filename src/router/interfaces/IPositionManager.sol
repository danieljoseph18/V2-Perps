// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Position} from "../../positions/Position.sol";
import {IMarket} from "../../markets/interfaces/IMarket.sol";
import {IPriceFeed} from "../../oracle/interfaces/IPriceFeed.sol";

interface IPositionManager {
    event ExecutePosition(bytes32 indexed _orderKey, Position.Request _request, uint256 _fee, uint256 _feeDiscount);
    event GasLimitsUpdated(
        uint256 indexed depositGasLimit, uint256 indexed withdrawalGasLimit, uint256 indexed positionGasLimit
    );
    event AdlExecuted(IMarket indexed market, bytes32 indexed positionKey, uint256 sizeDelta, bool isLong);
    event DepositRequestCancelled(
        bytes32 indexed _depositKey, address indexed _owner, address indexed _token, uint256 _amount
    );
    event WithdrawalRequestCancelled(
        bytes32 indexed _withdrawalKey, address indexed _owner, address indexed _token, uint256 _amount
    );

    error PositionManager_AccessDenied();
    error PositionManager_InvalidMarket();
    error PositionManager_InvalidKey();
    error PositionManager_ExecuteDepositFailed();
    error PositionManager_ExecuteWithdrawalFailed();
    error PositionManager_InvalidRequestType();
    error PositionManager_LiquidationFailed();
    error PositionManager_RequestDoesNotExist();
    error PositionManager_NotPositionOwner();
    error PositionManager_InsufficientDelay();
    error PositionManager_PTPRatioNotExceeded();
    error PositionManager_LongSideNotFlagged();
    error PositionManager_ShortSideNotFlagged();
    error PositionManager_PositionNotActive();
    error PositionManager_PNLFactorNotReduced();
    error PositionManager_InvalidPrice();
    error PositionManager_PriceAlreadyUpdated();
    error PositionManager_PnlToPoolRatioNotExceeded(int256 pnlFactor, uint256 maxPnlFactor);
    error PositionManager_PriceUpdateFee();
    error PositionManager_InvalidDepositOwner();
    error PositionManager_DepositNotExpired();
    error PositionManager_InvalidWithdrawalOwner();
    error PositionManager_WithdrawalNotExpired();
    error PositionManager_InvalidTransferIn();

    function updatePriceFeed(IPriceFeed _priceFeed) external;
    function transferDepositTokens(address _vault, address _token, uint256 _amount) external;
    function averageDepositCost() external view returns (uint256);
    function averageWithdrawalCost() external view returns (uint256);
    function averagePositionCost() external view returns (uint256);
    function baseGasLimit() external view returns (uint256);
}