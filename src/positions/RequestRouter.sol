//  ,----,------------------------------,------.
//   | ## |                              |    - |
//   | ## |                              |    - |
//   |    |------------------------------|    - |
//   |    ||............................||      |
//   |    ||,-                        -.||      |
//   |    ||___                      ___||    ##|
//   |    ||---`--------------------'---||      |
//   `--mb'|_|______________________==__|`------'

//    ____  ____  ___ _   _ _____ _____ ____
//   |  _ \|  _ \|_ _| \ | |_   _|___ /|  _ \
//   | |_) | |_) || ||  \| | | |   |_ \| |_) |
//   |  __/|  _ < | || |\  | | |  ___) |  _ <
//   |_|   |_| \_\___|_| \_| |_| |____/|_| \_\

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {MarketStructs} from "../markets/MarketStructs.sol";
import {ITradeStorage} from "./interfaces/ITradeStorage.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ILiquidityVault} from "../markets/interfaces/ILiquidityVault.sol";
import {IMarketStorage} from "../markets/interfaces/IMarketStorage.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {ITradeVault} from "./interfaces/ITradeVault.sol";
import {ImpactCalculator} from "./ImpactCalculator.sol";
import {TradeHelper} from "./TradeHelper.sol";
import {MarketHelper} from "../markets/MarketHelper.sol";
import {IWUSDC} from "../token/interfaces/IWUSDC.sol";
import {ReentrancyGuard} from "@solmate/utils/ReentrancyGuard.sol";

/// @dev Needs Router role
contract RequestRouter is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeERC20 for IWUSDC;

    ITradeStorage tradeStorage;
    ILiquidityVault liquidityVault;
    IMarketStorage marketStorage;
    ITradeVault tradeVault;
    IWUSDC immutable WUSDC;

    uint256 constant PRECISION = 1e18;
    uint256 constant COLLATERAL_MULTIPLIER = 1e12;
    uint256 constant MIN_SLIPPAGE = 0.0003e18; // 0.03%
    uint256 constant MAX_SLIPPAGE = 0.99e18; // 99%

    error RequestRouter_InvalidExecutionFee();
    error RequestRouter_ExecutionFeeTransferFailed();
    error RequestRouter_PositionSizeTooLarge();
    error RequestRouter_CallerIsNotPositionOwner();
    error RequestRouter_ExecutionFeeDoesNotMatch();
    error RequestRouter_RequestDoesNotExist();
    error RequestRouter_InvalidIndexToken();
    error RequestRouter_InvalidSlippage();
    error RequestRouter_PositionDoesNotExist();
    error RequestRouter_CollateralDeltaIsZero();
    error RequestRouter_CallerIsContract();
    error RequestRouter_DecreaseNonExistentPosition();
    error RequestRouter_SizeDeltaIsZero();
    error RequestRouter_SizeDeltaExceedsPositionSize();
    error RequestRouter_CollateralDeltaExceedsCollateralAmount();

    constructor(
        address _tradeStorage,
        address _liquidityVault,
        address _marketStorage,
        address _tradeVault,
        address _wusdc
    ) {
        tradeStorage = ITradeStorage(_tradeStorage);
        liquidityVault = ILiquidityVault(_liquidityVault);
        marketStorage = IMarketStorage(_marketStorage);
        tradeVault = ITradeVault(_tradeVault);
        WUSDC = IWUSDC(_wusdc);
    }

    modifier validExecutionFee() {
        if (msg.value != tradeStorage.executionFee()) revert RequestRouter_InvalidExecutionFee();
        _;
    }

    function createTradeRequest(MarketStructs.Trade calldata _trade) external payable nonReentrant validExecutionFee {
        if (msg.sender.code.length > 0) revert RequestRouter_CallerIsContract();
        if (_trade.maxSlippage < MIN_SLIPPAGE || _trade.maxSlippage > MAX_SLIPPAGE) {
            revert RequestRouter_InvalidSlippage();
        }
        if (_trade.collateralDelta == 0) revert RequestRouter_CollateralDeltaIsZero();

        bytes32 marketKey = keccak256(abi.encode(_trade.indexToken));
        MarketStructs.Market memory market = marketStorage.markets(marketKey);
        if (address(market.market) == address(0)) {
            revert RequestRouter_InvalidIndexToken();
        }

        bytes32 positionKey = keccak256(abi.encode(_trade.indexToken, msg.sender, _trade.isLong));
        MarketStructs.Position memory position = tradeStorage.openPositions(positionKey);

        uint256 collateralDelta;
        if (_trade.isIncrease) {
            _validateAllocation(marketKey, _trade.sizeDelta);
            collateralDelta = _handleTokenTransfers(_trade.collateralDelta, marketKey, _trade.isLong, true);
        } else {
            collateralDelta = _trade.collateralDelta * COLLATERAL_MULTIPLIER;
        }

        MarketStructs.RequestType requestType = _calculateRequestType(_trade, position);
        _sendExecutionFeeToVault();
        MarketStructs.Request memory request =
            TradeHelper.createRequest(_trade, msg.sender, collateralDelta, requestType);
        tradeStorage.createOrderRequest(request);
    }

    function cancelOrderRequest(bytes32 _key, bool _isLimit) external payable nonReentrant {
        MarketStructs.Request memory request = tradeStorage.orders(_key);
        if (request.user == address(0)) revert RequestRouter_RequestDoesNotExist();
        if (msg.sender != request.user) revert RequestRouter_CallerIsNotPositionOwner();
        ITradeStorage(tradeStorage).cancelOrderRequest(_key, _isLimit);
    }

    function _calculateRequestType(MarketStructs.Trade calldata _trade, MarketStructs.Position memory _position)
        private
        pure
        returns (MarketStructs.RequestType requestType)
    {
        if (_position.user == address(0)) {
            if (!_trade.isIncrease) revert RequestRouter_DecreaseNonExistentPosition();
            if (_trade.sizeDelta == 0) revert RequestRouter_SizeDeltaIsZero();
            if (_trade.collateralDelta == 0) revert RequestRouter_CollateralDeltaIsZero();
            requestType = MarketStructs.RequestType.CREATE_POSITION;
        } else if (_trade.sizeDelta == 0) {
            if (_trade.isIncrease) {
                if (_trade.collateralDelta == 0) revert RequestRouter_CollateralDeltaIsZero();
                requestType = MarketStructs.RequestType.COLLATERAL_INCREASE;
            } else {
                if (_trade.collateralDelta == 0) revert RequestRouter_CollateralDeltaIsZero();
                if (_position.collateralAmount < _trade.collateralDelta) {
                    revert RequestRouter_CollateralDeltaExceedsCollateralAmount();
                }
                requestType = MarketStructs.RequestType.COLLATERAL_DECREASE;
            }
        } else {
            if (_trade.isIncrease) {
                if (_trade.sizeDelta == 0) revert RequestRouter_SizeDeltaIsZero();
                if (_trade.collateralDelta == 0) revert RequestRouter_CollateralDeltaIsZero();
                requestType = MarketStructs.RequestType.POSITION_INCREASE;
            } else {
                if (_trade.sizeDelta == 0) revert RequestRouter_SizeDeltaIsZero();
                if (_trade.collateralDelta == 0) revert RequestRouter_CollateralDeltaIsZero();
                if (_position.positionSize < _trade.sizeDelta) revert RequestRouter_SizeDeltaExceedsPositionSize();
                if (_position.collateralAmount < _trade.collateralDelta) {
                    revert RequestRouter_CollateralDeltaExceedsCollateralAmount();
                }
                requestType = MarketStructs.RequestType.POSITION_DECREASE;
            }
        }
    }

    function _handleTokenTransfers(uint256 _usdcAmountIn, bytes32 _marketKey, bool _isLong, bool _isIncrease)
        private
        returns (uint256 amountOut)
    {
        IERC20 usdc = WUSDC.USDC();
        usdc.safeTransferFrom(msg.sender, address(this), _usdcAmountIn);
        usdc.safeIncreaseAllowance(address(WUSDC), _usdcAmountIn);
        amountOut = WUSDC.deposit(_usdcAmountIn);
        tradeVault.updateCollateralBalance(_marketKey, amountOut, _isLong, _isIncrease);
        WUSDC.safeTransfer(address(tradeVault), amountOut);
    }

    function _sendExecutionFeeToVault() private {
        uint256 executionFee = tradeStorage.executionFee();
        (bool success,) = address(tradeVault).call{value: executionFee}("");
        if (!success) revert RequestRouter_ExecutionFeeTransferFailed();
    }

    function _validateAllocation(bytes32 _marketKey, uint256 _sizeDelta) private view {
        MarketStructs.Market memory market = marketStorage.markets(_marketKey);
        uint256 totalOI = MarketHelper.getTotalIndexOpenInterest(address(marketStorage), market.indexToken);
        if (totalOI + _sizeDelta > marketStorage.maxOpenInterests(_marketKey)) {
            revert RequestRouter_PositionSizeTooLarge();
        }
    }
}
