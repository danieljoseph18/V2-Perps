// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

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
import {IWUSDC} from "../token/interfaces/IWUSDC.sol";

/// @dev Needs Router role
contract RequestRouter {
    using SafeERC20 for IERC20;
    using MarketStructs for MarketStructs.PositionRequest;
    // contract for creating requests for trades
    // limit orders, market orders, all will have 2 step process
    // swap orders included
    // orders will be stored in storage
    // orders will be executed by the Executor, which will put them on TradeManager

    ITradeStorage public tradeStorage;
    ILiquidityVault public liquidityVault;
    IMarketStorage public marketStorage;
    ITradeVault public tradeVault;
    IWUSDC public immutable WUSDC;

    error RequestRouter_ExecutionFeeTooLow();
    error RequestRouter_IncorrectFee();
    error RequestRouter_ExecutionFeeTransferFailed();
    error RequestRouter_PositionSizeTooLarge();

    constructor(
        ITradeStorage _tradeStorage,
        ILiquidityVault _liquidityVault,
        IMarketStorage _marketStorage,
        ITradeVault _tradeVault,
        IWUSDC _wusdc
    ) {
        tradeStorage = _tradeStorage;
        liquidityVault = _liquidityVault;
        marketStorage = _marketStorage;
        tradeVault = _tradeVault;
        WUSDC = _wusdc;
    }

    modifier validExecutionFee(uint256 _executionFee) {
        uint256 minExecutionFee = tradeStorage.minExecutionFee();
        if (msg.value < minExecutionFee) revert RequestRouter_ExecutionFeeTooLow();
        if (msg.value != _executionFee) revert RequestRouter_IncorrectFee();
        _;
    }

    function createTradeRequest(
        MarketStructs.PositionRequest memory _positionRequest,
        bool _isLimit,
        uint256 _executionFee,
        bool _isIncrease
    ) external payable validExecutionFee(_executionFee) {
        _sendExecutionFeeToStorage(_executionFee);

        // get the key for the market
        bytes32 marketKey = keccak256(abi.encodePacked(_positionRequest.indexToken));

        if (_isIncrease) {
            _validateAllocation(marketKey, _positionRequest.sizeDelta);

            uint256 wusdcAmount = _transferInCollateral(_positionRequest.collateralDelta);

            _transferOutTokens(_positionRequest, wusdcAmount, marketKey);
        }

        (uint256 marketLen, uint256 limitLen) = tradeStorage.getRequestQueueLengths();
        uint256 index = _isLimit ? limitLen : marketLen;

        _positionRequest.requestIndex = index;
        _positionRequest.requestBlock = block.number;

        tradeStorage.createOrderRequest(_positionRequest);
    }

    // get position to close
    // get the current price
    // create decrease request for full position size
    function createCloseRequest(bytes32 _positionKey, uint256 _acceptablePrice, bool _isLimit, uint256 _executionFee)
        external
        payable
        validExecutionFee(_executionFee)
    {
        // transfer execution fee to the liquidity vault
        _sendExecutionFeeToStorage(_executionFee);
        // validate the request meets all safety parameters
        // open the request on the trade storage contract
        (uint256 marketLen, uint256 limitLen) = tradeStorage.getRequestQueueLengths();

        uint256 index = _isLimit ? limitLen : marketLen;
        MarketStructs.Position memory _position = tradeStorage.openPositions(_positionKey);
        MarketStructs.PositionRequest memory _positionRequest = MarketStructs.PositionRequest({
            requestIndex: index,
            isLimit: _isLimit,
            indexToken: _position.indexToken,
            user: _position.user,
            collateralDelta: _position.collateralAmount,
            sizeDelta: _position.positionSize,
            requestBlock: block.number,
            acceptablePrice: _acceptablePrice,
            priceImpact: 0,
            isLong: _position.isLong,
            isIncrease: false
        });
        tradeStorage.createOrderRequest(_positionRequest);
    }

    function cancelOrderRequest(bytes32 _key, bool _isLimit, uint256 _executionFee)
        external
        payable
        validExecutionFee(_executionFee)
    {
        // transfer execution fee to the liquidity vault
        _sendExecutionFeeToStorage(_executionFee);
        // perform safety checks => it exists, it's their position etc.
        ITradeStorage(tradeStorage).cancelOrderRequest(_key, _isLimit);
    }

    function _transferInCollateral(uint256 _amountIn) internal returns (uint256) {
        IERC20(WUSDC.USDC()).safeTransferFrom(msg.sender, address(this), _amountIn);
        return _wrapUsdc(_amountIn);
    }

    // Note: User must approve full collateral amount for transfer
    function _transferOutTokens(
        MarketStructs.PositionRequest memory _positionRequest,
        uint256 _wusdcAmount,
        bytes32 _marketKey
    ) internal {
        // deduct trading fee from amount
        uint256 fee = TradeHelper.calculateTradingFee(address(tradeStorage), _positionRequest.sizeDelta);
        // validate fee vs request => can fee be deducted from collateral and still remain above minimum?
        // transfer fee to liquidity vault and increase accumulated fees
        liquidityVault.accumulateFees(fee);
        WUSDC.transfer(address(liquidityVault), fee);
        // transfer the rest of the collateral to trade vault and updateCollateralBalance
        uint256 collateralAmount = _wusdcAmount - fee;
        tradeVault.updateCollateralBalance(
            _marketKey, collateralAmount, _positionRequest.isLong, _positionRequest.isIncrease
        );
        WUSDC.transfer(address(tradeVault), collateralAmount);
    }

    function _sendExecutionFeeToStorage(uint256 _executionFee) internal returns (bool) {
        (bool success,) = address(liquidityVault).call{value: _executionFee}("");
        if (!success) revert RequestRouter_ExecutionFeeTransferFailed();
        return true;
    }

    function _wrapUsdc(uint256 _amount) internal returns (uint256) {
        return WUSDC.deposit(_amount);
    }

    // validate that the additional open interest won't put the market over the max open interest (allocated reserves)
    // call the mapping to get the allocation and divide by over collateralization then * 100
    // compare to what the size delta will put the open interest to
    // Review
    function _validateAllocation(bytes32 _marketKey, uint256 _sizeDelta) internal view {
        uint256 allocation = ILiquidityVault(liquidityVault).getMarketAllocation(_marketKey);
        uint256 overcollateralization = ILiquidityVault(liquidityVault).overCollateralizationPercentage();
        address market = IMarketStorage(marketStorage).getMarket(_marketKey).market;
        uint256 totalOI = IMarket(market).getTotalOpenInterest();
        uint256 maxOI = (allocation / overcollateralization) * 100;
        if (totalOI + _sizeDelta > maxOI) revert RequestRouter_PositionSizeTooLarge();
    }
}
