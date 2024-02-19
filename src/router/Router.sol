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
    uint256 private constant COLLATERAL_MULTIPLIER = 1e12;
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

    modifier validExecutionFee(Gas.Action _action) {
        uint256 expGasLimit = Gas.getLimitForAction(processor, _action);
        require(msg.value >= Gas.getMinExecutionFee(processor, expGasLimit), "Router: Execution Fee");
        _;
    }

    /////////////
    // Setters //
    /////////////

    function updateConfig(address _tradeStorage, address _liquidityVault, address _marketMaker, address _processor)
        external
        onlyAdmin
    {
        tradeStorage = ITradeStorage(_tradeStorage);
        liquidityVault = ILiquidityVault(_liquidityVault);
        marketMaker = IMarketMaker(_marketMaker);
        processor = IProcessor(_processor);
    }

    /////////////////////////
    // MARKET INTERACTIONS //
    /////////////////////////

    // @audit - need to request signed price here
    function createDeposit(Deposit.Input memory _input, bytes[] memory _priceUpdateData)
        external
        payable
        nonReentrant
        validExecutionFee(Gas.Action.DEPOSIT)
    {
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

    // @audit - need to request signed price here
    function createWithdrawal(Withdrawal.Input memory _input, bytes[] memory _priceUpdateData)
        external
        payable
        validExecutionFee(Gas.Action.WITHDRAW)
        nonReentrant
    {
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

    /////////////
    // TRADING //
    /////////////

    // @audit - need to request signed price here
    function createPositionRequest(Position.Input calldata _trade, bytes[] memory _priceUpdateData)
        external
        payable
        nonReentrant
        validExecutionFee(Gas.Action.POSITION)
    {
        require(_trade.maxSlippage >= MIN_SLIPPAGE && _trade.maxSlippage <= MAX_SLIPPAGE, "Router: Slippage");
        require(_trade.collateralDelta != 0, "Router: Collateral Delta");

        uint256 collateralRefPrice;
        if (_trade.isLong) {
            require(_trade.collateralToken == address(WETH), "Router: Invalid Collateral Token");
            (collateralRefPrice,) = Oracle.getLastMarketTokenPrices(priceFeed, true);
        } else {
            require(_trade.collateralToken == address(USDC), "Router: Invalid Collateral Token");
            (, collateralRefPrice) = Oracle.getLastMarketTokenPrices(priceFeed, false);
        }

        require(collateralRefPrice > 0, "Router: Invalid Collateral Ref Price");

        address market = marketMaker.tokenToMarkets(_trade.indexToken);
        require(market != address(0), "Router: Market Doesn't Exist");

        bytes32 positionKey = keccak256(abi.encode(_trade.indexToken, msg.sender, _trade.isLong));

        uint256 indexRefPrice = Oracle.getReferencePrice(priceFeed, priceFeed.getAsset(_trade.indexToken));
        require(indexRefPrice > 0, "Router: Invalid Index Ref Price");

        uint256 indexBaseUnit = Oracle.getBaseUnit(priceFeed, _trade.indexToken);
        uint256 sizeDeltaUsd = mulDiv(_trade.sizeDelta, indexRefPrice, indexBaseUnit);

        if (sizeDeltaUsd > 0) {
            uint256 collateralBaseUnit = Oracle.getBaseUnit(priceFeed, _trade.collateralToken);
            uint256 collateralDeltaUsd = mulDiv(_trade.collateralDelta, collateralRefPrice, collateralBaseUnit);
            Position.checkLeverage(IMarket(market), sizeDeltaUsd, collateralDeltaUsd);
        }

        if (_trade.isLimit) {
            if (_trade.isLong) {
                require(_trade.limitPrice > indexRefPrice, "Router: mark price > limit price");
            } else {
                require(_trade.limitPrice < indexRefPrice, "Router: mark price < limit price");
            }
        }

        Position.validateConditionals(_trade.conditionals, indexRefPrice, _trade.isLong);

        Position.RequestType requestType =
            Position.getRequestType(_trade, tradeStorage.getPosition(positionKey), _trade.collateralDelta);

        Position.Request memory request = Position.createRequest(_trade, market, msg.sender, requestType);

        tradeStorage.createOrderRequest(request);

        _requestOraclePricing(_trade.indexToken, _priceUpdateData);

        _handleTokenTransfers(_trade);

        _sendExecutionFee(_trade.executionFee);
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

    ////////////////////////
    // INTERNAL FUNCTIONS //
    ////////////////////////

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
    function _handleTokenTransfers(Position.Input calldata _trade) private {
        if (_trade.shouldWrap) {
            require(_trade.collateralToken == address(WETH), "Router: Invalid Collateral Token");
            require(_trade.collateralDelta <= msg.value - _trade.executionFee, "Router: Invalid Collateral Delta");
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
