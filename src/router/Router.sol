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
import {ILiquidityVault} from "../liquidity/interfaces/ILiquidityVault.sol";
import {IMarketMaker} from "../markets/interfaces/IMarketMaker.sol";
import {PriceImpact} from "../libraries/PriceImpact.sol";
import {ReentrancyGuard} from "@solmate/utils/ReentrancyGuard.sol";
import {Market} from "../markets/Market.sol";
import {Position} from "../positions/Position.sol";
import {Deposit} from "../liquidity/Deposit.sol";
import {Withdrawal} from "../liquidity/Withdrawal.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {IWETH} from "../tokens/interfaces/IWETH.sol";
import {RoleValidation} from "../access/RoleValidation.sol";
import {IPriceFeed} from "../oracle/interfaces/IPriceFeed.sol";
import {Oracle} from "../oracle/Oracle.sol";

/// @dev Needs Router role
// All user interactions should come through this contract
contract Router is ReentrancyGuard, RoleValidation {
    using SafeERC20 for IERC20;
    using SafeERC20 for IWETH;

    ITradeStorage tradeStorage;
    ILiquidityVault liquidityVault;
    IMarketMaker marketMaker;
    IPriceFeed priceFeed;
    IERC20 immutable USDC;
    IWETH immutable WETH;
    address processor;

    uint256 constant PRECISION = 1e18;
    uint256 constant COLLATERAL_MULTIPLIER = 1e12;
    uint256 constant MIN_SLIPPAGE = 0.0001e18; // 0.01%
    uint256 constant MAX_SLIPPAGE = 0.9999e18; // 99.99%

    constructor(
        address _tradeStorage,
        address _liquidityVault,
        address _marketMaker,
        address _priceFeed,
        address _usdc,
        address _weth,
        address _processor,
        address _roleStorage
    ) RoleValidation(_roleStorage) {
        tradeStorage = ITradeStorage(_tradeStorage);
        liquidityVault = ILiquidityVault(_liquidityVault);
        marketMaker = IMarketMaker(_marketMaker);
        priceFeed = IPriceFeed(_priceFeed);
        USDC = IERC20(_usdc);
        WETH = IWETH(_weth);
        processor = _processor;
    }

    /* 
        - User needs to pay for trade execution and pricing 
        - Execution Fee - how can we estimate this? Or do we hardcode?
        - Price Fee - if pyth,  the user needs to send an update fee while requesting price
        If secondary, the user needs to send a fee for updating the price
    */

    modifier requestOraclePricing(address _token) {
        Oracle.Asset memory asset = priceFeed.getAsset(_token);
        require(asset.isValid, "Router: Invalid Asset");
        // get fee
        if (asset.priceProvider == Oracle.PriceProvider.PYTH) {
            // request pyth price
        } else {
            // request secondary price
        }
        // check fee
        // request price
        _;
    }

    modifier validExecutionFee(bool _isTrade) {
        if (_isTrade) {
            require(msg.value == tradeStorage.executionFee(), "Router: Execution Fee");
        } else {
            require(msg.value >= liquidityVault.executionFee(), "Router: Execution Fee");
        }
        _;
    }

    /////////////
    // Setters //
    /////////////

    function updateConfig(address _tradeStorage, address _liquidityVault, address _marketMaker, address _processor)
        external
        onlyAdmin
    {
        require(msg.sender == processor, "Router: Invalid processor");
        tradeStorage = ITradeStorage(_tradeStorage);
        liquidityVault = ILiquidityVault(_liquidityVault);
        marketMaker = IMarketMaker(_marketMaker);
        processor = _processor;
    }

    /////////////////////////
    // MARKET INTERACTIONS //
    /////////////////////////

    // @audit - need to request signed price here
    function createDeposit(Deposit.Params memory _params) external payable nonReentrant validExecutionFee(false) {
        require(msg.sender == _params.owner, "Router: Invalid Owner");
        require(_params.maxSlippage >= MIN_SLIPPAGE && _params.maxSlippage <= MAX_SLIPPAGE, "Router: Slippage");
        if (_params.shouldWrap) {
            require(_params.amountIn == msg.value - _params.executionFee, "Router: Invalid Amount In");
            require(_params.tokenIn == address(WETH), "Router: Invalid Token In");
            WETH.deposit{value: _params.amountIn}();
            WETH.safeTransfer(address(processor), _params.amountIn);
        } else {
            require(_params.tokenIn == address(USDC) || _params.tokenIn == address(WETH), "Router: Invalid Token In");
            IERC20(_params.tokenIn).safeTransferFrom(_params.owner, address(processor), _params.amountIn);
        }
        liquidityVault.createDeposit(_params);
        _sendExecutionFee(false);
    }

    function cancelDeposit(bytes32 _key) external nonReentrant {
        require(_key != bytes32(0));
        liquidityVault.cancelDeposit(_key, msg.sender);
    }

    // @audit - need to request signed price here
    function createWithdrawal(Withdrawal.Params memory _params)
        external
        payable
        validExecutionFee(false)
        nonReentrant
    {
        require(msg.sender == _params.owner, "Router: Invalid Owner");
        require(_params.maxSlippage >= MIN_SLIPPAGE && _params.maxSlippage <= MAX_SLIPPAGE, "Router: Slippage");
        if (_params.shouldUnwrap) {
            require(_params.tokenOut == address(WETH), "Router: Invalid Token Out");
        } else {
            require(_params.tokenOut == address(USDC) || _params.tokenOut == address(WETH), "Router: Invalid Token Out");
        }
        IERC20(address(liquidityVault)).safeTransferFrom(_params.owner, address(processor), _params.marketTokenAmountIn);
        liquidityVault.createWithdrawal(_params);
        _sendExecutionFee(false);
    }

    function cancelWithdrawal(bytes32 _key) external nonReentrant {
        require(_key != bytes32(0));
        liquidityVault.cancelWithdrawal(_key, msg.sender);
    }

    /////////////
    // TRADING //
    /////////////

    /// @dev collateralDelta always in USDC
    // @audit - Update function so:
    // If Long -> User collateral is ETH
    // If Short -> User collateral is USDC
    // @audit - need to request signed price here
    function createTradeRequest(Position.Input calldata _trade) external payable nonReentrant validExecutionFee(true) {
        require(_trade.maxSlippage >= MIN_SLIPPAGE && _trade.maxSlippage <= MAX_SLIPPAGE, "Router: Slippage");
        require(_trade.collateralDelta != 0, "Router: Collateral Delta");
        require(
            _trade.collateralToken == address(USDC) || _trade.collateralToken == address(WETH),
            "Router: Collateral Token"
        );
        // Check if Market exists
        address market = marketMaker.tokenToMarkets(_trade.indexToken);
        require(market != address(0), "Router: Market Doesn't Exist");
        // Create a Pointer to the Position
        bytes32 positionKey = keccak256(abi.encode(_trade.indexToken, msg.sender, _trade.isLong));
        Position.Data memory position = tradeStorage.getPosition(positionKey);
        // Get Reference Price
        uint256 refPrice = Oracle.getReferencePrice(priceFeed, _trade.indexToken);
        // Validate Conditionals
        Position.validateConditionals(_trade.conditionals, refPrice);
        // Calculate Request Type
        Position.RequestType requestType = Position.getRequestType(_trade, position, _trade.collateralDelta);
        // Construct Request
        Position.Request memory request = Position.createRequest(_trade, market, msg.sender, requestType);
        // Send Constructed Request to Storage
        tradeStorage.createOrderRequest(request);
        // Handle Transfer of Tokens to Designated Areas
        _handleTokenTransfers(_trade);
        // Send Fee for Execution to Vault to be sent to whoever executes the request
        _sendExecutionFee(true);
    }

    // @audit - need to check X blocks have passed
    function cancelOrderRequest(bytes32 _key, bool _isLimit) external payable nonReentrant {
        // Fetch the Request
        Position.Request memory request = tradeStorage.getOrder(_key);
        // Check it exists
        require(request.user != address(0), "Router: Request Doesn't Exist");
        // Check the caller is the position owner
        require(msg.sender == request.user, "Router: Not Position Owner");
        // Cancel the Request
        ITradeStorage(tradeStorage).cancelOrderRequest(_key, _isLimit);
    }

    // Stop Loss or Take Profit
    // @audit - review, is necesssary?
    function createEditOrder(
        bytes32 _positionKey,
        uint256 _executionPrice,
        uint256 _percentage,
        uint256 _maxSlippage,
        bool _isStopLoss
    ) external payable nonReentrant validExecutionFee(true) {
        Position.Data memory position = tradeStorage.getPosition(_positionKey);
        require(position.user == msg.sender, "Router: Invalid Position Owner");
        require(_percentage > 0 && _percentage < PRECISION, "Router: Invalid Percentage");
        // create a decrease position request limit order for the specified percentage
        Position.Request memory request =
            Position.createEditOrder(position, _executionPrice, _percentage, _maxSlippage, msg.value, _isStopLoss);
        // Send Constructed Request to Storage
        tradeStorage.createOrderRequest(request);
        // Send Fee for Execution to Vault to be sent to whoever executes the request
        _sendExecutionFee(true);
    }

    // Function for simultaneously creating a SL and a TP order
    // @audit - review, is necesssary?
    function createMultiEditOrder(
        bytes32 _positionKey,
        uint256 _stopLossPrice,
        uint256 _takeProfitPrice,
        uint256 _stopLossPercentage,
        uint256 _takeProfitPercentage,
        uint256 _maxSlippage
    ) external payable nonReentrant {
        // @audit - if Keeper call, keeper should not pay execution fee
        require(msg.value == 2 * tradeStorage.executionFee(), "Router: Execution Fee");
        Position.Data memory position = tradeStorage.getPosition(_positionKey);
        require(position.user == msg.sender, "Router: Invalid Position Owner");
        require(_stopLossPercentage > 0 && _stopLossPercentage < PRECISION, "Router: Invalid SL Percentage");
        require(_takeProfitPercentage > 0 && _takeProfitPercentage < PRECISION, "Router: Invalid TP Percentage");
        // create a decrease position request limit order for the specified percentage
        Position.Request memory stopLoss =
            Position.createEditOrder(position, _stopLossPrice, _stopLossPercentage, _maxSlippage, msg.value, true);
        Position.Request memory takeProfit =
            Position.createEditOrder(position, _takeProfitPrice, _takeProfitPercentage, _maxSlippage, msg.value, false);

        // Send Constructed Request to Storage
        tradeStorage.createOrderRequest(stopLoss);
        tradeStorage.createOrderRequest(takeProfit);
        // Send Fee for Execution to Vault to be sent to whoever executes the request
        _sendExecutionFee(true);
    }

    ////////////////////////
    // INTERNAL FUNCTIONS //
    ////////////////////////

    // @audit - need to update collateral balance wherever collateral is stored
    // @audit - decrease requests won't have any transfer in
    function _handleTokenTransfers(Position.Input calldata _trade) private {
        if (_trade.shouldWrap) {
            require(_trade.collateralToken == address(WETH), "Router: Invalid Collateral Token");
            require(_trade.collateralDelta == msg.value - _trade.executionFee, "Router: Invalid Collateral Delta");
            WETH.deposit{value: _trade.collateralDelta}();
            WETH.safeTransfer(address(processor), _trade.collateralDelta);
        } else {
            IERC20(_trade.collateralToken).safeTransferFrom(msg.sender, address(processor), _trade.collateralDelta);
        }
    }

    function _sendExecutionFee(bool _isTrade) private {
        uint256 executionFee;
        if (_isTrade) {
            executionFee = tradeStorage.executionFee();
        } else {
            executionFee = liquidityVault.executionFee();
        }
        (bool success,) = address(liquidityVault).call{value: executionFee}("");
        require(success, "Router: Fee Transfer Failed");
    }
}
