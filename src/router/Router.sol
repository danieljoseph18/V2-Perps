// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {ITradeStorage} from "../positions/interfaces/ITradeStorage.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {IMarketMaker} from "../markets/interfaces/IMarketMaker.sol";
import {ReentrancyGuard} from "@solmate/utils/ReentrancyGuard.sol";
import {Position} from "../positions/Position.sol";
import {IWETH} from "../tokens/interfaces/IWETH.sol";
import {RoleValidation} from "../access/RoleValidation.sol";
import {IPriceFeed} from "../oracle/interfaces/IPriceFeed.sol";
import {Oracle} from "../oracle/Oracle.sol";
import {Gas} from "../libraries/Gas.sol";
import {IPositionManager} from "./interfaces/IPositionManager.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IMarketToken} from "../markets/interfaces/IMarketToken.sol";

/// @dev Needs Router role
// All user interactions should come through this contract
contract Router is ReentrancyGuard, RoleValidation {
    using SafeERC20 for IERC20;
    using SafeERC20 for IWETH;
    using SafeERC20 for IMarketToken;
    using Address for address payable;

    IMarketMaker private marketMaker;
    IPriceFeed private priceFeed;
    IERC20 private immutable USDC;
    IWETH private immutable WETH;
    IPositionManager private positionManager;

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
        address _marketMaker,
        address _priceFeed,
        address _usdc,
        address _weth,
        address _positionManager,
        address _roleStorage
    ) RoleValidation(_roleStorage) {
        marketMaker = IMarketMaker(_marketMaker);
        priceFeed = IPriceFeed(_priceFeed);
        USDC = IERC20(_usdc);
        WETH = IWETH(_weth);
        positionManager = IPositionManager(_positionManager);
    }

    receive() external payable {}

    function updateConfig(address _marketMaker, address _positionManager) external onlyAdmin {
        marketMaker = IMarketMaker(_marketMaker);
        positionManager = IPositionManager(_positionManager);
    }

    function updatePriceFeed(IPriceFeed _priceFeed) external onlyAdmin {
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
        Gas.validateExecutionFee(priceFeed, positionManager, market, _executionFee, msg.value, Gas.Action.DEPOSIT);

        if (msg.sender != _owner) revert Router_InvalidOwner();
        if (_amountIn == 0) revert Router_InvalidAmountIn();
        if (_shouldWrap) {
            if (_amountIn > msg.value - _executionFee) revert Router_InvalidAmountIn();
            if (_tokenIn != address(WETH)) revert Router_CantWrapUSDC();
            WETH.deposit{value: _amountIn}();
            WETH.safeTransfer(address(positionManager), _amountIn);
        } else {
            if (_tokenIn != address(USDC) && _tokenIn != address(WETH)) revert Router_InvalidTokenIn();
            IERC20(_tokenIn).safeTransferFrom(msg.sender, address(positionManager), _amountIn);
        }

        market.createRequest(_owner, _tokenIn, _amountIn, _executionFee, _shouldWrap, true);
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
        Gas.validateExecutionFee(priceFeed, positionManager, market, _executionFee, msg.value, Gas.Action.WITHDRAW);
        if (msg.sender != _owner) revert Router_InvalidOwner();
        if (_marketTokenAmountIn == 0) revert Router_InvalidAmountIn();
        if (_shouldUnwrap) {
            if (_tokenOut != address(WETH)) revert Router_InvalidTokenOut();
        } else {
            if (_tokenOut != address(USDC) && _tokenOut != address(WETH)) revert Router_InvalidTokenOut();
        }

        IMarketToken marketToken = market.MARKET_TOKEN();
        marketToken.safeTransferFrom(msg.sender, address(positionManager), _marketTokenAmountIn);

        market.createRequest(_owner, _tokenOut, _marketTokenAmountIn, _executionFee, _shouldUnwrap, false);
        _sendExecutionFee(_executionFee);

        // Request a Price Update for the Asset
        emit Router_PriceUpdateRequested(bytes32(0), block.number); // Only Need Long / Short Tokens
    }

    function createPositionRequest(Position.Input memory _trade) external payable nonReentrant {
        // Get the market to direct the user to
        address market = marketMaker.tokenToMarket(_trade.assetId);

        /**
         * 3 Cases:
         * 1. Position with no Conditionals -> Gas.Action.POSITION
         * 2. Position with Stop Loss or Take Profit -> Gas.Action.POSITION_WITH_LIMIT
         * 3. Position with Stop Loss and Take Profit -> Gas.Action.POSITION_WITH_LIMITS
         */
        if (_trade.conditionals.stopLossSet && _trade.conditionals.takeProfitSet) {
            Gas.validateExecutionFee(
                priceFeed,
                positionManager,
                IMarket(market),
                _trade.executionFee,
                msg.value,
                Gas.Action.POSITION_WITH_LIMITS
            );
        } else if (_trade.conditionals.stopLossSet || _trade.conditionals.takeProfitSet) {
            Gas.validateExecutionFee(
                priceFeed,
                positionManager,
                IMarket(market),
                _trade.executionFee,
                msg.value,
                Gas.Action.POSITION_WITH_LIMIT
            );
        } else {
            Gas.validateExecutionFee(
                priceFeed, positionManager, IMarket(market), _trade.executionFee, msg.value, Gas.Action.POSITION
            );
        }
        // If Long, Collateral must be (W)ETH, if Short, Colalteral must be USDC
        if (_trade.isLong) {
            if (_trade.collateralToken != address(WETH)) revert Router_InvalidTokenIn();
        } else {
            if (_trade.collateralToken != address(USDC)) revert Router_InvalidTokenIn();
        }

        // Handle Token Transfers
        if (_trade.isIncrease) _handleTokenTransfers(_trade);

        // Construct the state for Order Creation
        bytes32 positionKey = Position.validateInputParameters(_trade, market);

        ITradeStorage tradeStorage = ITradeStorage(IMarket(market).tradeStorage());

        Position.Data memory position = tradeStorage.getPosition(positionKey);

        // Set the Request Type
        Position.RequestType requestType = Position.getRequestType(_trade, position);

        // Construct the Request from the user input
        Position.Request memory request = Position.createRequest(_trade, msg.sender, requestType);

        // Store the Order Request
        tradeStorage.createOrderRequest(request);

        // Send Full Execution Fee to positionManager to Distribute
        _sendExecutionFee(_trade.executionFee);

        // Request a Price Update for the Asset
        emit Router_PriceUpdateRequested(_trade.assetId, block.number);
    }

    function _handleTokenTransfers(Position.Input memory _trade) private {
        if (_trade.reverseWrap) {
            if (_trade.collateralToken != address(WETH)) revert Router_InvalidCollateralToken();
            // Collateral Delta should always == msg.value - executionFee
            if (_trade.collateralDelta != msg.value - _trade.executionFee) revert Router_InvalidAmountInForWrap();
            WETH.deposit{value: _trade.collateralDelta}();
            WETH.safeTransfer(address(positionManager), _trade.collateralDelta);
        } else {
            // Attemps to transfer full collateralDelta -> Should always Revert if Transfer Fails
            // Router needs approval for Collateral Token, of amount >= Collateral Delta
            IERC20(_trade.collateralToken).safeTransferFrom(
                msg.sender, address(positionManager), _trade.collateralDelta
            );
        }
    }

    // Send Fee to positionManager
    function _sendExecutionFee(uint256 _executionFee) private {
        payable(address(positionManager)).sendValue(_executionFee);
    }
}
