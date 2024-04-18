// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {ITradeStorage} from "../positions/interfaces/ITradeStorage.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {IMarketFactory} from "../markets/interfaces/IMarketFactory.sol";
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
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @dev Needs Router role
// All user interactions should come through this contract
contract Router is ReentrancyGuard, RoleValidation {
    using SafeERC20 for IERC20;
    using SafeERC20 for IWETH;
    using SafeERC20 for IMarketToken;
    using Address for address payable;
    using Strings for uint256;

    IMarketFactory private marketFactory;
    IPriceFeed private priceFeed;
    IERC20 private immutable USDC;
    IWETH private immutable WETH;
    IPositionManager private positionManager;

    string private constant LONG_TICKER = "ETH";
    string private constant SHORT_TICKER = "USDC";

    event DepositRequestCreated(IMarket market, address owner, address tokenIn, uint256 amountIn);
    event WithdrawalRequestCreated(IMarket market, address owner, address tokenOut, uint256 amountOut);
    event PositionRequestCreated(
        IMarket market, string ticker, bool isLong, bool isIncrease, uint256 sizeDelta, uint256 collateralDelta
    );
    event PriceUpdateRequested(bytes32 requestKey, string[] tickers, address requester);
    event PnlRequested(bytes32 requestKey, IMarket market, address requester);

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
    error Router_InvalidPriceUpdateFee();

    constructor(
        address _marketFactory,
        address _priceFeed,
        address _usdc,
        address _weth,
        address _positionManager,
        address _roleStorage
    ) RoleValidation(_roleStorage) {
        marketFactory = IMarketFactory(_marketFactory);
        priceFeed = IPriceFeed(_priceFeed);
        USDC = IERC20(_usdc);
        WETH = IWETH(_weth);
        positionManager = IPositionManager(_positionManager);
    }

    receive() external payable {}

    /**
     * ========================================= Setter Functions =========================================
     */
    function updateConfig(address _marketFactory, address _positionManager) external onlyAdmin {
        marketFactory = IMarketFactory(_marketFactory);
        positionManager = IPositionManager(_positionManager);
    }

    function updatePriceFeed(IPriceFeed _priceFeed) external onlyAdmin {
        priceFeed = _priceFeed;
    }

    /**
     * ========================================= External Functions =========================================
     */
    function createDeposit(
        IMarket market,
        address _owner,
        address _tokenIn,
        uint256 _amountIn,
        uint256 _executionFee,
        bool _shouldWrap
    ) external payable nonReentrant {
        uint256 totalPriceUpdateFee = Gas.validateExecutionFee(
            priceFeed, positionManager, _executionFee, msg.value, Gas.Action.DEPOSIT, true, false
        );

        _executionFee -= totalPriceUpdateFee;

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

        uint256 priceFee = totalPriceUpdateFee / 2;
        bytes32 priceRequestKey = _requestPriceUpdate(priceFee, "");
        bytes32 pnlRequestKey = _requestPnlUpdate(market, priceFee);

        market.createRequest(
            _owner, _tokenIn, _amountIn, _executionFee, priceRequestKey, pnlRequestKey, _shouldWrap, true
        );
        _sendExecutionFee(_executionFee);

        emit DepositRequestCreated(market, _owner, _tokenIn, _amountIn);
    }

    function createWithdrawal(
        IMarket market,
        address _owner,
        address _tokenOut,
        uint256 _marketTokenAmountIn,
        uint256 _executionFee,
        bool _shouldUnwrap
    ) external payable nonReentrant {
        uint256 totalPriceUpdateFee = Gas.validateExecutionFee(
            priceFeed, positionManager, _executionFee, msg.value, Gas.Action.WITHDRAW, true, false
        );

        _executionFee -= totalPriceUpdateFee;

        if (msg.sender != _owner) revert Router_InvalidOwner();
        if (_marketTokenAmountIn == 0) revert Router_InvalidAmountIn();
        if (_shouldUnwrap) {
            if (_tokenOut != address(WETH)) revert Router_InvalidTokenOut();
        } else {
            if (_tokenOut != address(USDC) && _tokenOut != address(WETH)) revert Router_InvalidTokenOut();
        }

        uint256 priceFee = totalPriceUpdateFee / 2;
        bytes32 priceRequestKey = _requestPriceUpdate(priceFee, "");
        bytes32 pnlRequestKey = _requestPnlUpdate(market, priceFee);

        IMarketToken marketToken = market.MARKET_TOKEN();
        marketToken.safeTransferFrom(msg.sender, address(positionManager), _marketTokenAmountIn);

        market.createRequest(
            _owner, _tokenOut, _marketTokenAmountIn, _executionFee, priceRequestKey, pnlRequestKey, _shouldUnwrap, false
        );
        _sendExecutionFee(_executionFee);

        emit WithdrawalRequestCreated(market, _owner, _tokenOut, _marketTokenAmountIn);
    }

    function createPositionRequest(
        IMarket market,
        Position.Input memory _trade,
        Position.Conditionals calldata _conditionals
    ) external payable nonReentrant {
        /**
         * 3 Cases:
         * 1. Position with no Conditionals -> Gas.Action.POSITION
         * 2. Position with Stop Loss or Take Profit -> Gas.Action.POSITION_WITH_LIMIT
         * 3. Position with Stop Loss and Take Profit -> Gas.Action.POSITION_WITH_LIMITS
         */
        uint256 priceUpdateFee;
        if (_conditionals.stopLossSet && _conditionals.takeProfitSet) {
            priceUpdateFee = Gas.validateExecutionFee(
                priceFeed,
                positionManager,
                _trade.executionFee,
                msg.value,
                Gas.Action.POSITION_WITH_LIMITS,
                false,
                _trade.isLimit
            );
        } else if (_conditionals.stopLossSet || _conditionals.takeProfitSet) {
            priceUpdateFee = Gas.validateExecutionFee(
                priceFeed,
                positionManager,
                _trade.executionFee,
                msg.value,
                Gas.Action.POSITION_WITH_LIMIT,
                false,
                _trade.isLimit
            );
        } else {
            priceUpdateFee = Gas.validateExecutionFee(
                priceFeed, positionManager, _trade.executionFee, msg.value, Gas.Action.POSITION, false, _trade.isLimit
            );
        }

        _trade.executionFee -= uint64(priceUpdateFee);

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
        bytes32 priceRequestKey = _trade.isLimit ? bytes32(0) : _requestPriceUpdate(priceUpdateFee, _trade.ticker);

        // Construct the state for Order Creation
        bytes32 positionKey = Position.validateInputParameters(_trade, _conditionals, address(market));

        ITradeStorage tradeStorage = ITradeStorage(market.tradeStorage());

        Position.Data memory position = tradeStorage.getPosition(positionKey);

        // Set the Request Type
        Position.RequestType requestType = Position.getRequestType(_trade, position);

        // Construct the Request from the user input
        Position.Request memory request =
            Position.createRequest(_trade, _conditionals, msg.sender, requestType, priceRequestKey);

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
    function requestExecutionPricing(IMarket market, bytes32 _key, bool _isPositionKey)
        external
        payable
        returns (bytes32 priceRequestKey)
    {
        ITradeStorage tradeStorage = ITradeStorage(market.tradeStorage());
        string memory ticker;
        // Fetch the Ticker of the Asset
        if (_isPositionKey) ticker = tradeStorage.getPosition(_key).ticker;
        else ticker = tradeStorage.getOrder(_key).input.ticker;
        // If ticker field was empty, revert
        if (bytes(ticker).length == 0) revert Router_InvalidAsset();
        // Get the Price update fee
        uint256 priceUpdateFee = Oracle.estimateRequestCost(priceFeed);
        // Validate the Execution Fee
        if (msg.value < priceUpdateFee) revert Router_InvalidPriceUpdateFee();
        // Request a Price Update
        priceRequestKey = _requestPriceUpdate(msg.value, ticker);
    }

    /**
     * @dev Requests an update for all of the prices of the assets within a market.
     *
     * Used for requesting pricing before calling:
     * 1. market.addToken
     * 2. market.removeToken
     * 3. market.reallocate
     */
    function requestPricingForMarket(IMarket market) external payable returns (bytes32 priceRequestKey) {
        uint256 priceUpdateFee = Oracle.estimateRequestCost(priceFeed);
        if (msg.value < priceUpdateFee) revert Router_InvalidPriceUpdateFee();
        string[] memory args = Oracle.constructMultiPriceArgs(market);
        priceRequestKey = priceFeed.requestPriceUpdate{value: msg.value}(args, msg.sender);
    }

    /**
     * ========================================= Internal Functions =========================================
     */
    /// @dev - First argument of functions requests is always the block timestamp
    function _requestPriceUpdate(uint256 _fee, string memory _ticker) private returns (bytes32 requestKey) {
        // Convert the string to an array of length 1
        string[] memory args = Oracle.constructPriceArguments(_ticker);
        // Request a Price Update for the Asset
        requestKey = priceFeed.requestPriceUpdate{value: _fee}(args, msg.sender);
        // Fire Event
        emit PriceUpdateRequested(requestKey, args, msg.sender);
    }

    function _requestPnlUpdate(IMarket market, uint256 _fee) private returns (bytes32 requestKey) {
        requestKey = priceFeed.requestCumulativeMarketPnl{value: _fee}(market, msg.sender);
        emit PnlRequested(requestKey, market, msg.sender);
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
