// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IVault} from "../../markets/interfaces/IVault.sol";
import {IMarket} from "../../markets/interfaces/IMarket.sol";
import {IPriceFeed} from "../../oracle/interfaces/IPriceFeed.sol";
import {IPositionManager} from "../../router/interfaces/IPositionManager.sol";
import {IReferralStorage} from "../../referrals/interfaces/IReferralStorage.sol";
import {Execution} from "../Execution.sol";
import {Position} from "../Position.sol";

interface ITradeEngine {
    event AdlExecuted(address indexed market, bytes32 indexed positionKey, uint256 sizeDelta, bool isLong);
    event LiquidatePosition(bytes32 indexed positionKey, address indexed liquidator, bool isLong);
    event CollateralEdited(bytes32 indexed positionKey, uint256 collateralDelta, bool isIncrease);
    event PositionCreated(bytes32 indexed positionKey, address indexed owner, address indexed market, bool isLong);
    event IncreasePosition(bytes32 indexed positionKey, uint256 collateralDelta, uint256 sizeDelta);
    event DecreasePosition(bytes32 indexed positionKey, uint256 collateralDelta, uint256 sizeDelta);

    error TradeEngine_InvalidRequestType();
    error TradeEngine_PositionDoesNotExist();

    function executePositionRequest(
        IMarket market,
        IVault vault,
        IPriceFeed priceFeed,
        IPositionManager positionManager,
        IReferralStorage referralStorage,
        bytes32 _orderKey,
        bytes32 _requestKey,
        address _feeReceiver
    ) external returns (Execution.FeeState memory feeState, Position.Request memory request);
    function executeAdl(
        IMarket market,
        IVault vault,
        IReferralStorage referralStorage,
        IPriceFeed priceFeed,
        bytes32 _positionKey,
        bytes32 _requestKey,
        address _feeReceiver
    ) external;
    function liquidatePosition(
        IMarket market,
        IVault vault,
        IReferralStorage referralStorage,
        IPriceFeed priceFeed,
        bytes32 _positionKey,
        bytes32 _requestKey,
        address _liquidator
    ) external;
}
