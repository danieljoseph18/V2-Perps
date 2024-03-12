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

import {ITradeStorage} from "../positions/interfaces/ITradeStorage.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {IMarketMaker} from "../markets/interfaces/IMarketMaker.sol";
import {ReentrancyGuard} from "@solmate/utils/ReentrancyGuard.sol";
import {Position} from "../positions/Position.sol";
import {Deposit} from "../markets/Deposit.sol";
import {Withdrawal} from "../markets/Withdrawal.sol";
import {IWETH} from "../tokens/interfaces/IWETH.sol";
import {RoleValidation} from "../access/RoleValidation.sol";
import {IPriceFeed} from "../oracle/interfaces/IPriceFeed.sol";
import {Oracle} from "../oracle/Oracle.sol";
import {Gas} from "../libraries/Gas.sol";
import {IProcessor} from "./interfaces/IProcessor.sol";
import {Order} from "../positions/Order.sol";

/// @dev Needs Router role
// All user interactions should come through this contract
contract Router is ReentrancyGuard, RoleValidation {
    using SafeERC20 for IERC20;
    using SafeERC20 for IWETH;

    ITradeStorage private tradeStorage;
    IMarketMaker private marketMaker;
    IPriceFeed private priceFeed;
    IERC20 private immutable USDC;
    IWETH private immutable WETH;
    IProcessor private processor;

    uint256 private constant PRECISION = 1e18;
    uint256 private constant MIN_SLIPPAGE = 0.0001e18; // 0.01%
    uint256 private constant MAX_SLIPPAGE = 0.9999e18; // 99.99%

    // Used to request a secondary price update from the Keeper
    event SecondaryPriceRequested(address indexed token, uint256 indexed blockNumber);

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

    function createDeposit(IMarket market, Deposit.Input memory _input, bytes[] memory _priceUpdateData)
        external
        payable
        nonReentrant
    {
        Gas.validateExecutionFee(processor, _input.executionFee, msg.value, Gas.Action.DEPOSIT);

        if (msg.sender != _input.owner) revert Router_InvalidOwner();
        if (_input.amountIn == 0) revert Router_InvalidAmountIn();
        if (_input.shouldWrap) {
            if (_input.amountIn > msg.value - _input.executionFee) revert Router_InvalidAmountIn();
            if (_input.tokenIn != address(WETH)) revert Router_CantWrapUSDC();
            WETH.deposit{value: _input.amountIn}();
            WETH.safeTransfer(address(processor), _input.amountIn);
        } else {
            if (_input.tokenIn != address(USDC) && _input.tokenIn != address(WETH)) revert Router_InvalidTokenIn();
            IERC20(_input.tokenIn).safeTransferFrom(_input.owner, address(processor), _input.amountIn);
        }
        _input.executionFee -= _requestOraclePricing(_input.tokenIn, _priceUpdateData);
        market.createDeposit(_input);
        _sendExecutionFee(_input.executionFee);
    }

    function cancelDeposit(IMarket market, bytes32 _key) external nonReentrant {
        if (_key == bytes32(0)) revert Router_InvalidKey();
        market.cancelDeposit(_key, msg.sender);
    }

    function createWithdrawal(IMarket market, Withdrawal.Input memory _input, bytes[] memory _priceUpdateData)
        external
        payable
        nonReentrant
    {
        Gas.validateExecutionFee(processor, _input.executionFee, msg.value, Gas.Action.WITHDRAW);
        if (msg.sender != _input.owner) revert Router_InvalidOwner();
        if (_input.marketTokenAmountIn == 0) revert Router_InvalidAmountIn();
        if (_input.shouldUnwrap) {
            if (_input.tokenOut != address(WETH)) revert Router_InvalidTokenOut();
        } else {
            if (_input.tokenOut != address(USDC) && _input.tokenOut != address(WETH)) revert Router_InvalidTokenOut();
        }
        IERC20(address(market)).safeTransferFrom(_input.owner, address(processor), _input.marketTokenAmountIn);
        _input.executionFee -= _requestOraclePricing(_input.tokenOut, _priceUpdateData);
        market.createWithdrawal(_input);
        _sendExecutionFee(_input.executionFee);
    }

    function cancelWithdrawal(IMarket market, bytes32 _key) external nonReentrant {
        if (_key == bytes32(0)) revert Router_InvalidKey();
        market.cancelWithdrawal(_key, msg.sender);
    }

    function createPositionRequest(Position.Input memory _trade, bytes[] memory _priceUpdateData)
        external
        payable
        nonReentrant
    {
        Gas.validateExecutionFee(processor, _trade.executionFee, msg.value, Gas.Action.POSITION);

        if (_trade.isLong) {
            if (_trade.collateralToken != address(WETH)) revert Router_InvalidTokenIn();
        } else {
            if (_trade.collateralToken != address(USDC)) revert Router_InvalidTokenIn();
        }

        // Construct the state for Order Creation
        Order.CreationState memory state = Order.validateInitialParameters(marketMaker, tradeStorage, priceFeed, _trade);

        Position.Data memory position = tradeStorage.getPosition(state.positionKey);

        // Set the Request Type
        state.requestType = Position.getRequestType(_trade, position);

        if (state.requestType == Position.RequestType.POSITION_DECREASE) {
            _trade = Position.checkForFullClose(_trade, position);
        }

        // Validate Parameters
        Order.validateParamsForType(_trade, state, position.collateralAmount, position.positionSize);

        // Construct the Request from the user input
        Position.Request memory request = Position.createRequest(_trade, state.market, msg.sender, state.requestType);

        // Sign Oracle Prices and Subtract Value from Execution Fee
        request.input.executionFee -= _requestOraclePricing(_trade.indexToken, _priceUpdateData);

        // Store the Order Request
        tradeStorage.createOrderRequest(request);

        // Handle Token Transfers
        if (_trade.isIncrease) _handleTokenTransfers(_trade);

        // Send Full Execution Fee to Processor to Distribute
        _sendExecutionFee(_trade.executionFee);
    }

    // @audit - need ability to edit a limit order
    function createEditOrder(Position.Conditionals memory _conditionals, uint256 _executionFee, bytes32 _positionKey)
        external
        payable
        nonReentrant
    {
        Gas.validateExecutionFee(processor, _executionFee, msg.value, Gas.Action.POSITION);

        tradeStorage.createEditOrder(_conditionals, _positionKey);

        _sendExecutionFee(_executionFee);
    }

    function _requestOraclePricing(address _token, bytes[] memory _priceUpdateData)
        private
        returns (uint256 updateFee)
    {
        Oracle.Asset memory asset = priceFeed.getAsset(_token);
        if (!asset.isValid) revert Router_InvalidAsset();
        updateFee = priceFeed.getPrimaryUpdateFee(_priceUpdateData);
        priceFeed.signPriceData{value: updateFee}(_token, _priceUpdateData);
        if (asset.priceProvider != Oracle.PriceProvider.PYTH) {
            updateFee += priceFeed.secondaryPriceFee();
            emit SecondaryPriceRequested(_token, block.number);
        }
    }

    // @audit - need to update collateral balance wherever collateral is stored
    // @audit - decrease requests won't have any transfer in
    function _handleTokenTransfers(Position.Input memory _trade) private {
        if (_trade.shouldWrap) {
            if (_trade.collateralToken != address(WETH)) revert Router_InvalidCollateralToken();
            if (_trade.collateralDelta > msg.value - _trade.executionFee) revert Router_InvalidAmountInForWrap();
            WETH.deposit{value: _trade.collateralDelta}();
            WETH.safeTransfer(address(processor), _trade.collateralDelta);
        } else {
            IERC20(_trade.collateralToken).safeTransferFrom(msg.sender, address(processor), _trade.collateralDelta);
        }
    }

    // Send Fee to Processor
    function _sendExecutionFee(uint256 _executionFee) private {
        (bool success,) = payable(address(processor)).call{value: _executionFee}("");
        if (!success) revert Router_ExecutionFeeTransferFailed();
    }
}
