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

/// @dev Needs Router role
// All user interactions should come through this contract
contract RequestRouter is ReentrancyGuard, RoleValidation {
    using SafeERC20 for IERC20;
    using SafeERC20 for IWETH;

    ITradeStorage tradeStorage;
    ILiquidityVault liquidityVault;
    IMarketMaker marketMaker;
    IERC20 immutable USDC;
    IWETH immutable WETH;
    address executor;

    uint256 constant PRECISION = 1e18;
    uint256 constant COLLATERAL_MULTIPLIER = 1e12;
    uint256 constant MIN_SLIPPAGE = 0.0001e18; // 0.01%
    uint256 constant MAX_SLIPPAGE = 0.9999e18; // 99.99%

    constructor(
        address _tradeStorage,
        address _liquidityVault,
        address _marketMaker,
        address _usdc,
        address _weth,
        address _executor,
        address _roleStorage
    ) RoleValidation(_roleStorage) {
        tradeStorage = ITradeStorage(_tradeStorage);
        liquidityVault = ILiquidityVault(_liquidityVault);
        marketMaker = IMarketMaker(_marketMaker);
        USDC = IERC20(_usdc);
        WETH = IWETH(_weth);
        executor = _executor;
    }

    modifier validExecutionFee(bool _isTrade) {
        if (_isTrade) {
            require(msg.value == tradeStorage.executionFee(), "RR: Execution Fee");
        } else {
            require(msg.value >= liquidityVault.executionFee(), "RR: Execution Fee");
        }
        _;
    }

    /////////////
    // Setters //
    /////////////

    function updateConfig(address _tradeStorage, address _liquidityVault, address _marketMaker, address _executor)
        external
        onlyAdmin
    {
        require(msg.sender == executor, "RR: Invalid Executor");
        tradeStorage = ITradeStorage(_tradeStorage);
        liquidityVault = ILiquidityVault(_liquidityVault);
        marketMaker = IMarketMaker(_marketMaker);
        executor = _executor;
    }

    /////////////////////////
    // MARKET INTERACTIONS //
    /////////////////////////

    function createDeposit(Deposit.Params memory _params) external payable nonReentrant validExecutionFee(false) {
        require(msg.sender == _params.owner, "RR: Invalid Owner");
        require(_params.maxSlippage >= MIN_SLIPPAGE && _params.maxSlippage <= MAX_SLIPPAGE, "RR: Slippage");
        if (_params.shouldWrap) {
            require(_params.amountIn == msg.value - _params.executionFee, "RR: Invalid Amount In");
            require(_params.tokenIn == address(WETH), "RR: Invalid Token In");
            WETH.deposit{value: _params.amountIn}();
            WETH.safeTransfer(address(executor), _params.amountIn);
        } else {
            require(_params.tokenIn == address(USDC) || _params.tokenIn == address(WETH), "RR: Invalid Token In");
            IERC20(_params.tokenIn).safeTransferFrom(_params.owner, address(executor), _params.amountIn);
        }
        liquidityVault.createDeposit(_params);
        _sendExecutionFee(false);
    }

    function cancelDeposit(bytes32 _key) external nonReentrant {
        require(_key != bytes32(0));
        liquidityVault.cancelDeposit(_key, msg.sender);
    }

    function createWithdrawal(Withdrawal.Params memory _params)
        external
        payable
        validExecutionFee(false)
        nonReentrant
    {
        require(msg.sender == _params.owner, "RR: Invalid Owner");
        require(_params.maxSlippage >= MIN_SLIPPAGE && _params.maxSlippage <= MAX_SLIPPAGE, "RR: Slippage");
        if (_params.shouldUnwrap) {
            require(_params.tokenOut == address(WETH), "RR: Invalid Token Out");
        } else {
            require(_params.tokenOut == address(USDC) || _params.tokenOut == address(WETH), "RR: Invalid Token Out");
        }
        IERC20(address(liquidityVault)).safeTransferFrom(_params.owner, address(executor), _params.marketTokenAmountIn);
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
    function createTradeRequest(Position.RequestInput calldata _trade)
        external
        payable
        nonReentrant
        validExecutionFee(true)
    {
        require(_trade.maxSlippage >= MIN_SLIPPAGE && _trade.maxSlippage <= MAX_SLIPPAGE, "RR: Slippage");
        require(_trade.collateralDelta != 0, "RR: Collateral Delta");
        require(
            _trade.collateralToken == address(USDC) || _trade.collateralToken == address(WETH), "RR: Collateral Token"
        );
        // Check if Market exists
        address market = marketMaker.tokenToMarkets(_trade.indexToken);
        require(market != address(0), "RR: Market Doesn't Exist");
        // Create a Pointer to the Position
        bytes32 positionKey = keccak256(abi.encode(_trade.indexToken, msg.sender, _trade.isLong));
        Position.Data memory position = tradeStorage.getPosition(positionKey);
        // Handle Transfer of Tokens to Designated Areas
        _handleTokenTransfers(_trade);
        // Calculate Request Type
        Position.RequestType requestType = Position.getRequestType(_trade, position, _trade.collateralDelta);
        // Construct Request
        Position.RequestData memory request = Position.createRequest(_trade, market, msg.sender, requestType);
        // Send Constructed Request to Storage
        tradeStorage.createOrderRequest(request);
        // Send Fee for Execution to Vault to be sent to whoever executes the request
        _sendExecutionFee(true);
    }

    // @audit - need to check X blocks have passed
    function cancelOrderRequest(bytes32 _key, bool _isLimit) external payable nonReentrant {
        // Fetch the Request
        Position.RequestData memory request = tradeStorage.getOrder(_key);
        // Check it exists
        require(request.user != address(0), "RR: Request Doesn't Exist");
        // Check the caller is the position owner
        require(msg.sender == request.user, "RR: Not Position Owner");
        // Cancel the Request
        ITradeStorage(tradeStorage).cancelOrderRequest(_key, _isLimit);
    }

    ////////////////////////
    // INTERNAL FUNCTIONS //
    ////////////////////////

    // @audit - need to update collateral balance wherever collateral is stored
    function _handleTokenTransfers(Position.RequestInput calldata _trade) private {
        if (_trade.shouldWrap) {
            require(_trade.collateralToken == address(WETH), "RR: Invalid Collateral Token");
            require(_trade.collateralDelta == msg.value - _trade.executionFee, "RR: Invalid Collateral Delta");
            WETH.deposit{value: _trade.collateralDelta}();
            WETH.safeTransfer(address(executor), _trade.collateralDelta);
        } else {
            IERC20(_trade.collateralToken).safeTransferFrom(msg.sender, address(executor), _trade.collateralDelta);
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
        require(success, "RR: Fee Transfer Failed");
    }
}
