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
pragma solidity 0.8.22;

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
    using MarketStructs for MarketStructs.PositionRequest;

    ITradeStorage tradeStorage;
    ILiquidityVault liquidityVault;
    IMarketStorage marketStorage;
    ITradeVault tradeVault;
    IWUSDC immutable WUSDC;

    uint256 constant PRECISION = 1e18;
    uint256 constant COLLATERAL_MULTIPLIER = 1e12;
    uint256 constant MIN_SLIPPAGE = 0.0003e18; // 0.03%
    uint256 constant MAX_SLIPPAGE = 0.99e18; // 99%

    error RequestRouter_ExecutionFeeTooLow();
    error RequestRouter_ExecutionFeeTransferFailed();
    error RequestRouter_PositionSizeTooLarge();
    error RequestRouter_CallerIsNotPositionOwner();
    error RequestRouter_ExecutionFeeDoesNotMatch();
    error RequestRouter_RequestDoesNotExist();
    error RequestRouter_InvalidIndexToken();
    error RequestRouter_InvalidSlippage();
    error RequestRouter_PositionDoesNotExist();

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
        if (msg.value < tradeStorage.minExecutionFee()) revert RequestRouter_ExecutionFeeTooLow();
        _;
    }

    function createTradeRequest(MarketStructs.Trade calldata _trade) external payable nonReentrant validExecutionFee {
        if (msg.value != _trade.executionFee) revert RequestRouter_ExecutionFeeDoesNotMatch();
        _sendExecutionFeeToVault(_trade.executionFee);
        bytes32 marketKey = keccak256(abi.encode(_trade.indexToken));
        if (marketStorage.markets(marketKey).market == address(0)) {
            revert RequestRouter_InvalidIndexToken();
        }
        if (_trade.maxSlippage < MIN_SLIPPAGE || _trade.maxSlippage > MAX_SLIPPAGE) {
            revert RequestRouter_InvalidSlippage();
        }

        uint256 collateralDelta;
        if (_trade.isIncrease) {
            _validateAllocation(marketKey, _trade.sizeDelta);
            // Converts USDC to WUSDC and Transfers Tokens to the Vault
            collateralDelta = _handleTokenTransfers(_trade.collateralDelta, marketKey, _trade.isLong, true);
        } else {
            // Convert USDC amount to WUSDC
            collateralDelta = _trade.collateralDelta * COLLATERAL_MULTIPLIER;
            bytes32 positionKey = keccak256(abi.encode(_trade.indexToken, msg.sender, _trade.isLong));
            MarketStructs.Position memory position = tradeStorage.openPositions(positionKey);
            // Check their existing position collateral is > collateralDelta
            assert(position.collateralAmount >= collateralDelta);
            // Check their existing position size is > sizeDelta
            assert(position.positionSize >= _trade.sizeDelta);
        }

        MarketStructs.PositionRequest memory positionRequest =
            TradeHelper.createPositionRequest(address(tradeStorage), _trade, msg.sender, collateralDelta);

        tradeStorage.createOrderRequest(positionRequest);
    }

    function cancelOrderRequest(bytes32 _key, bool _isLimit) external payable nonReentrant {
        MarketStructs.PositionRequest memory request = tradeStorage.orders(_isLimit, _key);
        if (request.user == address(0)) revert RequestRouter_RequestDoesNotExist();
        if (msg.sender != request.user) revert RequestRouter_CallerIsNotPositionOwner();
        ITradeStorage(tradeStorage).cancelOrderRequest(_key, _isLimit);
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

    function _sendExecutionFeeToVault(uint256 _executionFee) private {
        (bool success,) = address(tradeVault).call{value: _executionFee}("");
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
