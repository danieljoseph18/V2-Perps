// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {ITradeStorage} from "../positions/interfaces/ITradeStorage.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMarket, IVault} from "../markets/interfaces/IMarket.sol";
import {IMarketMaker} from "../markets/interfaces/IMarketMaker.sol";
import {ReentrancyGuard} from "@solmate/utils/ReentrancyGuard.sol";
import {Position} from "../positions/Position.sol";
import {IWETH} from "../tokens/interfaces/IWETH.sol";
import {RoleValidation} from "../access/RoleValidation.sol";
import {IPriceFeed} from "../oracle/interfaces/IPriceFeed.sol";
import {Oracle} from "../oracle/Oracle.sol";
import {Gas} from "../libraries/Gas.sol";
import {IProcessor} from "./interfaces/IProcessor.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

/// @dev Needs Router role
// All user interactions should come through this contract
contract Router is ReentrancyGuard, RoleValidation {
    using SafeERC20 for IERC20;
    using SafeERC20 for IWETH;
    using Address for address payable;

    ITradeStorage private tradeStorage;
    IMarketMaker private marketMaker;
    IPriceFeed private priceFeed;
    IERC20 private immutable USDC;
    IWETH private immutable WETH;
    IProcessor private processor;

    // Used to request a secondary price update from the Keeper
    event Router_PriceUpdateRequested(bytes32 indexed assetId, uint256 indexed blockNumber);

    error Router_InvalidOwner();
    error Router_InvalidAmountIn();
    error Router_CantWrapUSDC();
    error Router_InvalidTokenIn();
    error Router_InvalidKey();
    error Router_InvalidTokenOut();
    error Router_InvalidAsset();
    error Router_InvalidCollateralToken();
    error Router_InvalidAmountInForWrap();
    error Router_ExecutionFeeTransferFailed();
    error Router_InvalidCollateralDelta();
    error Router_InvalidSizeDelta();

    constructor(
        address _tradeStorage,
        address _marketMaker,
        address _priceFeed,
        address _usdc,
        address _weth,
        address _processor,
        address _roleStorage
    ) RoleValidation(_roleStorage) {
        tradeStorage = ITradeStorage(_tradeStorage);
        marketMaker = IMarketMaker(_marketMaker);
        priceFeed = IPriceFeed(_priceFeed);
        USDC = IERC20(_usdc);
        WETH = IWETH(_weth);
        processor = IProcessor(_processor);
    }

    receive() external payable {}

    function updateConfig(address _tradeStorage, address _marketMaker, address _processor) external onlyAdmin {
        tradeStorage = ITradeStorage(_tradeStorage);
        marketMaker = IMarketMaker(_marketMaker);
        processor = IProcessor(_processor);
    }

    function updatePriceFeed(IPriceFeed _priceFeed) external onlyConfigurator {
        priceFeed = _priceFeed;
    }

    function createDeposit(
        IMarket market,
        address _owner,
        address _tokenIn,
        uint256 _amountIn,
        uint256 _executionFee,
        bool _shouldWrap
    ) external payable nonReentrant {
        Gas.validateExecutionFee(processor, _executionFee, msg.value, Gas.Action.DEPOSIT);

        if (msg.sender != _owner) revert Router_InvalidOwner();
        if (_amountIn == 0) revert Router_InvalidAmountIn();
        if (_shouldWrap) {
            if (_amountIn > msg.value - _executionFee) revert Router_InvalidAmountIn();
            if (_tokenIn != address(WETH)) revert Router_CantWrapUSDC();
            WETH.deposit{value: _amountIn}();
            WETH.safeTransfer(address(processor), _amountIn);
        } else {
            if (_tokenIn != address(USDC) && _tokenIn != address(WETH)) revert Router_InvalidTokenIn();
            IERC20(_tokenIn).safeTransferFrom(msg.sender, address(processor), _amountIn);
        }

        market.createDeposit(_owner, _tokenIn, _amountIn, _executionFee, _shouldWrap);
        _sendExecutionFee(_executionFee);

        // Request a Price Update for the Asset
        emit Router_PriceUpdateRequested(bytes32(0), block.number); // Only Need Long / Short Tokens
    }

    function createWithdrawal(
        IMarket market,
        address _owner,
        address _tokenOut,
        uint256 _marketTokenAmountIn,
        uint256 _executionFee,
        bool _shouldUnwrap
    ) external payable nonReentrant {
        Gas.validateExecutionFee(processor, _executionFee, msg.value, Gas.Action.WITHDRAW);
        if (msg.sender != _owner) revert Router_InvalidOwner();
        if (_marketTokenAmountIn == 0) revert Router_InvalidAmountIn();
        if (_shouldUnwrap) {
            if (_tokenOut != address(WETH)) revert Router_InvalidTokenOut();
        } else {
            if (_tokenOut != address(USDC) && _tokenOut != address(WETH)) revert Router_InvalidTokenOut();
        }
        IERC20(address(market)).safeTransferFrom(msg.sender, address(processor), _marketTokenAmountIn);

        market.createWithdrawal(_owner, _tokenOut, _marketTokenAmountIn, _executionFee, _shouldUnwrap);
        _sendExecutionFee(_executionFee);

        // Request a Price Update for the Asset
        emit Router_PriceUpdateRequested(bytes32(0), block.number); // Only Need Long / Short Tokens
    }

    function createPositionRequest(Position.Input memory _trade) external payable nonReentrant {
        Gas.validateExecutionFee(processor, _trade.executionFee, msg.value, Gas.Action.POSITION);

        if (_trade.isLong) {
            if (_trade.collateralToken != address(WETH)) revert Router_InvalidTokenIn();
        } else {
            if (_trade.collateralToken != address(USDC)) revert Router_InvalidTokenIn();
        }

        // Handle Token Transfers
        if (_trade.isIncrease) _handleTokenTransfers(_trade);

        // Construct the state for Order Creation
        (address market, bytes32 positionKey) = Position.validateInputParameters(marketMaker, _trade);

        Position.Data memory position = tradeStorage.getPosition(positionKey);

        // Set the Request Type
        Position.RequestType requestType = Position.getRequestType(_trade, position);

        // Construct the Request from the user input
        Position.Request memory request = Position.createRequest(_trade, market, msg.sender, requestType);

        // Store the Order Request
        tradeStorage.createOrderRequest(request);

        // Send Full Execution Fee to Processor to Distribute
        _sendExecutionFee(_trade.executionFee);

        // Request a Price Update for the Asset
        emit Router_PriceUpdateRequested(_trade.assetId, block.number);
    }

    // @audit - need to update collateral balance wherever collateral is stored
    // @audit - decrease requests won't have any transfer in
    function _handleTokenTransfers(Position.Input memory _trade) private {
        if (_trade.reverseWrap) {
            if (_trade.collateralToken != address(WETH)) revert Router_InvalidCollateralToken();
            // Collateral Delta should always == msg.value - executionFee
            if (_trade.collateralDelta != msg.value - _trade.executionFee) revert Router_InvalidAmountInForWrap();
            WETH.deposit{value: _trade.collateralDelta}();
            WETH.safeTransfer(address(processor), _trade.collateralDelta);
        } else {
            // Attemps to transfer full collateralDelta -> Should always Revert if Transfer Fails
            // Router needs approval for Collateral Token, of amount >= Collateral Delta
            IERC20(_trade.collateralToken).safeTransferFrom(msg.sender, address(processor), _trade.collateralDelta);
        }
    }

    // Send Fee to Processor
    function _sendExecutionFee(uint256 _executionFee) private {
        payable(address(processor)).sendValue(_executionFee);
    }
}
