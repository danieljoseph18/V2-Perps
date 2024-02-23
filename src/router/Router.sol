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
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {Position} from "../positions/Position.sol";
import {Deposit} from "../liquidity/Deposit.sol";
import {Withdrawal} from "../liquidity/Withdrawal.sol";
import {IWETH} from "../tokens/interfaces/IWETH.sol";
import {RoleValidation} from "../access/RoleValidation.sol";
import {IPriceFeed} from "../oracle/interfaces/IPriceFeed.sol";
import {Oracle} from "../oracle/Oracle.sol";
import {Gas} from "../libraries/Gas.sol";
import {IProcessor} from "./interfaces/IProcessor.sol";
import {mulDiv} from "@prb/math/Common.sol";
import {Order} from "../positions/Order.sol";

/// @dev Needs Router role
// All user interactions should come through this contract
contract Router is ReentrancyGuard, RoleValidation {
    using SafeERC20 for IERC20;
    using SafeERC20 for IWETH;

    ITradeStorage private tradeStorage;
    ILiquidityVault private liquidityVault;
    IMarketMaker private marketMaker;
    IPriceFeed private priceFeed;
    IERC20 private immutable USDC;
    IWETH private immutable WETH;
    IProcessor private processor;

    uint256 private constant PRECISION = 1e18;
    uint256 private constant MIN_SLIPPAGE = 0.0001e18; // 0.01%
    uint256 private constant MAX_SLIPPAGE = 0.9999e18; // 99.99%

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
        processor = IProcessor(_processor);
    }

    receive() external payable {}

    function updateConfig(address _tradeStorage, address _liquidityVault, address _marketMaker, address _processor)
        external
        onlyAdmin
    {
        tradeStorage = ITradeStorage(_tradeStorage);
        liquidityVault = ILiquidityVault(_liquidityVault);
        marketMaker = IMarketMaker(_marketMaker);
        processor = IProcessor(_processor);
    }

    function updatePriceFeed(IPriceFeed _priceFeed) external onlyConfigurator {
        priceFeed = _priceFeed;
    }

    function createDeposit(Deposit.Input memory _input, bytes[] memory _priceUpdateData)
        external
        payable
        nonReentrant
    {
        Gas.validateExecutionFee(processor, _input.executionFee, msg.value, Gas.Action.DEPOSIT);

        require(msg.sender == _input.owner, "Router: Invalid Owner");
        require(_input.amountIn > 0, "Router: Invalid Amount In");
        if (_input.shouldWrap) {
            require(_input.amountIn <= msg.value - _input.executionFee, "Router: Invalid Amount In");
            require(_input.tokenIn == address(WETH), "Router: Can't Wrap USDC");
            WETH.deposit{value: _input.amountIn}();
            WETH.safeTransfer(address(processor), _input.amountIn);
        } else {
            require(_input.tokenIn == address(USDC) || _input.tokenIn == address(WETH), "Router: Invalid Token In");
            IERC20(_input.tokenIn).safeTransferFrom(_input.owner, address(processor), _input.amountIn);
        }
        liquidityVault.createDeposit(_input);
        _requestOraclePricing(_input.tokenIn, _priceUpdateData);
        _sendExecutionFee(_input.executionFee);
    }

    function cancelDeposit(bytes32 _key) external nonReentrant {
        require(_key != bytes32(0));
        liquidityVault.cancelDeposit(_key, msg.sender);
    }

    function createWithdrawal(Withdrawal.Input memory _input, bytes[] memory _priceUpdateData)
        external
        payable
        nonReentrant
    {
        Gas.validateExecutionFee(processor, _input.executionFee, msg.value, Gas.Action.WITHDRAW);
        require(msg.sender == _input.owner, "Router: Invalid Owner");
        require(_input.marketTokenAmountIn > 0, "Router: Invalid Amount In");
        if (_input.shouldUnwrap) {
            require(_input.tokenOut == address(WETH), "Router: Invalid Token Out");
        } else {
            require(_input.tokenOut == address(USDC) || _input.tokenOut == address(WETH), "Router: Invalid Token Out");
        }
        IERC20(address(liquidityVault)).safeTransferFrom(_input.owner, address(processor), _input.marketTokenAmountIn);
        liquidityVault.createWithdrawal(_input);
        _requestOraclePricing(_input.tokenOut, _priceUpdateData);
        _sendExecutionFee(_input.executionFee);
    }

    function cancelWithdrawal(bytes32 _key) external nonReentrant {
        require(_key != bytes32(0));
        liquidityVault.cancelWithdrawal(_key, msg.sender);
    }

    function createPositionRequest(Position.Input memory _trade, bytes[] memory _priceUpdateData)
        external
        payable
        nonReentrant
    {
        Gas.validateExecutionFee(processor, _trade.executionFee, msg.value, Gas.Action.POSITION);

        Order.CreateCache memory cache = Order.validateInitialParameters(marketMaker, tradeStorage, priceFeed, _trade);

        Position.Data memory position = tradeStorage.getPosition(cache.positionKey);

        cache.requestType = Position.getRequestType(_trade, position);

        Order.validateParamsForType(_trade, cache, position.collateralAmount, position.positionSize);

        Position.Request memory request = Position.createRequest(_trade, cache.market, msg.sender, cache.requestType);

        tradeStorage.createOrderRequest(request);

        _requestOraclePricing(_trade.indexToken, _priceUpdateData);

        if (_trade.isIncrease) _handleTokenTransfers(_trade);

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

    // How can we estimate the update fee and add it to the execution fee?
    function _requestOraclePricing(address _token, bytes[] memory _priceUpdateData) private {
        Oracle.Asset memory asset = priceFeed.getAsset(_token);
        require(asset.isValid, "Router: Invalid Asset");
        if (asset.priceProvider == Oracle.PriceProvider.PYTH) {
            uint256 fee = priceFeed.getPrimaryUpdateFee(_priceUpdateData);
            priceFeed.signPriceData{value: fee}(_token, _priceUpdateData);
        } else {
            uint256 fee = priceFeed.secondaryPriceFee();
            (bool success,) = address(priceFeed).call{value: fee}("");
            require(success, "Router: Price Fee Transfer");
        }
    }

    // @audit - need to update collateral balance wherever collateral is stored
    // @audit - decrease requests won't have any transfer in
    function _handleTokenTransfers(Position.Input memory _trade) private {
        if (_trade.shouldWrap) {
            require(_trade.collateralToken == address(WETH), "Router: Invalid Collateral Token");
            require(_trade.collateralDelta <= msg.value - _trade.executionFee, "Router: Invalid Amount In");
            WETH.deposit{value: _trade.collateralDelta}();
            WETH.safeTransfer(address(processor), _trade.collateralDelta);
        } else {
            IERC20(_trade.collateralToken).safeTransferFrom(msg.sender, address(processor), _trade.collateralDelta);
        }
    }

    // Send Fee to Processor
    function _sendExecutionFee(uint256 _executionFee) private {
        (bool success,) = payable(address(processor)).call{value: _executionFee}("");
        require(success, "Router: Execution Fee Transfer");
    }
}
