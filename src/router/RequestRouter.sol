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
import {ITradeVault} from "../positions/interfaces/ITradeVault.sol";
import {PriceImpact} from "../libraries/PriceImpact.sol";
import {ReentrancyGuard} from "@solmate/utils/ReentrancyGuard.sol";
import {Market} from "../markets/Market.sol";
import {Position} from "../positions/Position.sol";
import {Deposit} from "../liquidity/Deposit.sol";
import {Withdrawal} from "../liquidity/Withdrawal.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";

/// @dev Needs Router role
// All user interactions should come through this contract
contract RequestRouter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    ITradeStorage tradeStorage;
    ILiquidityVault liquidityVault;
    IMarketMaker marketMaker;
    ITradeVault tradeVault;
    IERC20 immutable USDC;

    uint256 constant PRECISION = 1e18;
    uint256 constant COLLATERAL_MULTIPLIER = 1e12;
    uint256 constant MIN_SLIPPAGE = 0.0003e18; // 0.03%
    uint256 constant MAX_SLIPPAGE = 0.99e18; // 99%

    constructor(
        address _tradeStorage,
        address _liquidityVault,
        address _marketMaker,
        address _tradeVault,
        address _usdc
    ) {
        tradeStorage = ITradeStorage(_tradeStorage);
        liquidityVault = ILiquidityVault(_liquidityVault);
        marketMaker = IMarketMaker(_marketMaker);
        tradeVault = ITradeVault(_tradeVault);
        USDC = IERC20(_usdc);
    }

    modifier validExecutionFee(bool _isTrade) {
        if (_isTrade) {
            require(msg.value == tradeStorage.executionFee(), "RR: Execution Fee");
        } else {
            require(msg.value == liquidityVault.executionFee(), "RR: Execution Fee");
        }
        _;
    }

    /////////////////////////
    // MARKET INTERACTIONS //
    /////////////////////////

    function createDeposit(Deposit.Params memory _params) external payable nonReentrant {
        require(msg.sender == _params.owner, "RR: Invalid Owner");
        liquidityVault.createDeposit{value: msg.value}(_params);
    }

    function cancelDeposit(bytes32 _key) external nonReentrant {
        require(_key != bytes32(0));
        liquidityVault.cancelDeposit(_key);
    }

    function createWithdrawal(Withdrawal.Params memory _params) external payable nonReentrant {
        require(msg.sender == _params.owner, "RR: Invalid Owner");
        liquidityVault.createWithdrawal(_params);
    }

    function cancelWithdrawal(bytes32 _key) external nonReentrant {
        require(_key != bytes32(0));
        liquidityVault.cancelWithdrawal(_key);
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
        require(_trade.collateralDeltaUSDC != 0, "RR: Collateral Delta");

        // Check if Market exists
        address market = marketMaker.tokenToMarkets(_trade.indexToken);
        require(market != address(0), "RR: Market Doesn't Exist");
        // Create a Pointer to the Position
        bytes32 positionKey = keccak256(abi.encode(_trade.indexToken, msg.sender, _trade.isLong));
        Position.Data memory position = tradeStorage.getPosition(positionKey);

        // Handle Transfer of Tokens to Designated Areas
        _handleTokenTransfers(market, _trade.collateralDeltaUSDC, _trade.isLong, _trade.isIncrease);
        // Calculate Request Type
        Position.RequestType requestType = Position.getRequestType(_trade, position, _trade.collateralDeltaUSDC);
        // Send Fee for Execution to Vault to be sent to whoever executes the request
        _sendExecutionFeeToVault();
        // Construct Request
        Position.RequestData memory request =
            Position.createRequest(_trade, msg.sender, _trade.collateralDeltaUSDC, requestType);
        // Send Constructed Request to Storage
        tradeStorage.createOrderRequest(request);
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

    function _handleTokenTransfers(address _market, uint256 _amountInUSDC, bool _isLong, bool _isIncrease) private {
        tradeVault.updateCollateralBalance(_market, _amountInUSDC, _isLong, _isIncrease);
        USDC.safeTransferFrom(msg.sender, address(tradeVault), _amountInUSDC);
    }

    function _sendExecutionFeeToVault() private {
        uint256 executionFee = tradeStorage.executionFee();
        (bool success,) = address(tradeVault).call{value: executionFee}("");
        require(success, "RR: Fee Transfer Failed");
    }
}
