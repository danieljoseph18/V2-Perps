// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Position} from "../../positions/Position.sol";
import {IMarket} from "../../markets/interfaces/IMarket.sol";
import {IPriceFeed} from "../../oracle/interfaces/IPriceFeed.sol";

interface IProcessor {
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

    error Processor_AccessDenied();
    error Processor_InvalidMarket();
    error Processor_InvalidKey();
    error Processor_ExecuteDepositFailed();
    error Processor_ExecuteWithdrawalFailed();
    error Processor_InvalidRequestType();
    error Processor_LiquidationFailed();
    error Processor_RequestDoesNotExist();
    error Processor_NotPositionOwner();
    error Processor_InsufficientDelay();
    error Processor_PTPRatioNotExceeded();
    error Processor_LongSideNotFlagged();
    error Processor_ShortSideNotFlagged();
    error Processor_PositionNotActive();
    error Processor_PNLFactorNotReduced();
    error Processor_InvalidPrice();
    error Processor_PriceAlreadyUpdated();
    error Processor_PnlToPoolRatioNotExceeded(int256 pnlFactor, uint256 maxPnlFactor);
    error Processor_PriceUpdateFee();
    error Processor_InvalidDepositOwner();
    error Processor_DepositNotExpired();
    error Processor_InvalidWithdrawalOwner();
    error Processor_WithdrawalNotExpired();

    function updatePriceFeed(IPriceFeed _priceFeed) external;
    function transferDepositTokens(address _vault, address _token, uint256 _amount) external;
    function depositGasLimit() external view returns (uint256);
    function withdrawalGasLimit() external view returns (uint256);
    function positionGasLimit() external view returns (uint256);
    function sendExecutionFee(address payable _to, uint256 _amount) external;
    function baseGasLimit() external view returns (uint256);
}
