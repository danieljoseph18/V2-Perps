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

    string private constant LONG_TICKER = "ETH";
    string private constant SHORT_TICKER = "USDC";

    event DepositRequestCreated(IMarket market, address owner, address tokenIn, uint256 amountIn);
    event WithdrawalRequestCreated(IMarket market, address owner, address tokenOut, uint256 amountOut);
    event PositionRequestCreated(
        address market, string ticker, bool isLong, bool isIncrease, uint256 sizeDelta, uint256 collateralDelta
    );
    event PriceUpdateRequested(bytes32 requestId, string[] tickers, address requester);
    event PnlRequested(bytes32 requestId, IMarket market, address requester);

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

    /**
     * ========================================= Setter Functions =========================================
     */
    function updateConfig(address _marketMaker, address _positionManager) external onlyAdmin {
        marketMaker = IMarketMaker(_marketMaker);
        positionManager = IPositionManager(_positionManager);
    }

    function updatePriceFeed(IPriceFeed _priceFeed) external onlyAdmin {
        priceFeed = _priceFeed;
    }

    /**
     * ========================================= External Functions =========================================
     */

    // @audit - add price update request / cumulative pnl update request
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

        bytes32 priceRequestId = _requestPriceUpdate("");
        bytes32 pnlRequestId = _requestPnlUpdate(market);

        market.createRequest(
            _owner, _tokenIn, _amountIn, _executionFee, priceRequestId, pnlRequestId, _shouldWrap, true
        );
        _sendExecutionFee(_executionFee);

        emit DepositRequestCreated(market, _owner, _tokenIn, _amountIn);
    }

    // @audit - add price update request / cumulative pnl update request
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

        bytes32 priceRequestId = _requestPriceUpdate("");
        bytes32 pnlRequestId = _requestPnlUpdate(market);

        IMarketToken marketToken = market.MARKET_TOKEN();
        marketToken.safeTransferFrom(msg.sender, address(positionManager), _marketTokenAmountIn);

        market.createRequest(
            _owner, _tokenOut, _marketTokenAmountIn, _executionFee, priceRequestId, pnlRequestId, _shouldUnwrap, false
        );
        _sendExecutionFee(_executionFee);

        emit WithdrawalRequestCreated(market, _owner, _tokenOut, _marketTokenAmountIn);
    }

    // @audit - can we create a trailing stop loss?
    // @audit - don't need price request if it's a limit order, SL, or TP
    function createPositionRequest(Position.Input memory _trade) external payable nonReentrant {
        // Get the market to direct the user to
        address market = marketMaker.tokenToMarket(_trade.ticker);

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

        // Request Price Update for the Asset if Market Order
        // Limit Orders, Stop Loss, and Take Profit Order's prices will be updated at execution time
        bytes32 priceRequestId = _trade.isLimit ? bytes32(0) : _requestPriceUpdate(_trade.ticker);

        // Construct the state for Order Creation
        bytes32 positionKey = Position.validateInputParameters(_trade, market);

        ITradeStorage tradeStorage = ITradeStorage(IMarket(market).tradeStorage());

        Position.Data memory position = tradeStorage.getPosition(positionKey);

        // Set the Request Type
        Position.RequestType requestType = Position.getRequestType(_trade, position);

        // Construct the Request from the user input
        // @audit - need to add request id
        Position.Request memory request = Position.createRequest(_trade, msg.sender, requestType, priceRequestId);

        // Store the Order Request
        tradeStorage.createOrderRequest(request);

        // Send Full Execution Fee to positionManager to Distribute
        _sendExecutionFee(_trade.executionFee);

        emit PositionRequestCreated(
            market, _trade.ticker, _trade.isLong, _trade.isIncrease, _trade.sizeDelta, _trade.collateralDelta
        );
    }

    /**
     * This function is used to create a price update request before execution one of either:
     * - Limit Order
     * - Adl
     * - Liquidation
     *
     * As the user doesn't provide the request in real time in these cases.
     *
     * To prevent the case where a user requests pricing to execute an order,
     */
    // Key can be an orderKey if limit new position, position key if limit decrease, sl, tp, adl or liquidation
    // @audit - watch for vulnerability where users use stale requests to execute orders
    // @audit - probably need an expiry on the validity of price requests
    function requestExecutionPricing(IMarket market, bytes32 _key, bool _positionKey)
        external
        payable
        onlyKeeper
        returns (bytes32 priceRequestId)
    {
        ITradeStorage tradeStorage = ITradeStorage(market.tradeStorage());
        string memory ticker;
        // Fetch the Ticker of the Asset
        if (_positionKey) ticker = tradeStorage.getPosition(_key).ticker;
        else ticker = tradeStorage.getOrder(_key).input.ticker;
        // If ticker field was empty, revert
        if (bytes(ticker).length == 0) revert Router_InvalidAsset();
        // Request a Price Update
        priceRequestId = _requestPriceUpdate(ticker);
    }

    /**
     * ========================================= Internal Functions =========================================
     */
    function _requestPriceUpdate(string memory _ticker) private returns (bytes32 requestId) {
        // Convert the string to an array of length 1
        string[] memory tickers;
        if (bytes(_ticker).length == 0) {
            // Only prices for Long and Short Tokens
            tickers = new string[](2);
            tickers[0] = LONG_TICKER;
            tickers[1] = SHORT_TICKER;
        } else {
            // Prices for index token, long token, and short token
            tickers = new string[](3);
            tickers[0] = _ticker;
            tickers[1] = LONG_TICKER;
            tickers[2] = SHORT_TICKER;
        }
        // Request a Price Update for the Asset
        requestId = priceFeed.requestPriceUpdate(tickers, msg.sender);
        // Fire Event
        emit PriceUpdateRequested(requestId, tickers, msg.sender);
    }

    function _requestPnlUpdate(IMarket _market) private returns (bytes32 requestId) {
        requestId = priceFeed.requestCumulativeMarketPnl(_market, msg.sender);
        emit PnlRequested(requestId, _market, msg.sender);
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
