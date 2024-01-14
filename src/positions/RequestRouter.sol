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

import {ITradeStorage} from "./interfaces/ITradeStorage.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ILiquidityVault} from "../markets/interfaces/ILiquidityVault.sol";
import {IMarketMaker} from "../markets/interfaces/IMarketMaker.sol";
import {ITradeVault} from "./interfaces/ITradeVault.sol";
import {PriceImpact} from "../libraries/PriceImpact.sol";
import {TradeHelper} from "./TradeHelper.sol";
import {MarketHelper} from "../markets/MarketHelper.sol";
import {IUSDE} from "../token/interfaces/IUSDE.sol";
import {ReentrancyGuard} from "@solmate/utils/ReentrancyGuard.sol";
import {Market} from "../structs/Market.sol";
import {Request} from "../structs/Request.sol";
import {Position} from "../structs/Position.sol";

/// @dev Needs Router role
contract RequestRouter is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeERC20 for IUSDE;

    ITradeStorage tradeStorage;
    ILiquidityVault liquidityVault;
    IMarketMaker marketMaker;
    ITradeVault tradeVault;
    IUSDE immutable USDE;

    uint256 constant PRECISION = 1e18;
    uint256 constant COLLATERAL_MULTIPLIER = 1e12;
    uint256 constant MIN_SLIPPAGE = 0.0003e18; // 0.03%
    uint256 constant MAX_SLIPPAGE = 0.99e18; // 99%

    constructor(
        address _tradeStorage,
        address _liquidityVault,
        address _marketMaker,
        address _tradeVault,
        address _usde
    ) {
        tradeStorage = ITradeStorage(_tradeStorage);
        liquidityVault = ILiquidityVault(_liquidityVault);
        marketMaker = IMarketMaker(_marketMaker);
        tradeVault = ITradeVault(_tradeVault);
        USDE = IUSDE(_usde);
    }

    modifier validExecutionFee() {
        require(msg.value == tradeStorage.executionFee(), "RR: Execution Fee");
        _;
    }

    /// @dev collateralDelta always in USDC
    function createTradeRequest(Request.Input calldata _trade) external payable nonReentrant validExecutionFee {
        require(_trade.maxSlippage >= MIN_SLIPPAGE && _trade.maxSlippage <= MAX_SLIPPAGE, "RR: Slippage");
        require(_trade.collateralDeltaUSDC != 0, "RR: Collateral Delta");

        // Check if Market exists
        bytes32 marketKey = keccak256(abi.encode(_trade.indexToken));
        Market.Data memory market = marketMaker.markets(marketKey);
        require(market.exists, "RR: Market Doesn't Exist");
        // Create a Pointer to the Position
        bytes32 positionKey = keccak256(abi.encode(_trade.indexToken, msg.sender, _trade.isLong));
        Position.Data memory position = tradeStorage.openPositions(positionKey);

        // Calculate the Collateral Delta in USDE
        uint256 collateralDeltaUSDE;
        if (_trade.isIncrease) {
            // Check Position doesn't exceed Market Allocation
            _validateAllocation(marketKey, _trade.sizeDelta);
            // Send USDC to correct location and return amount in USDE
            collateralDeltaUSDE = _handleTokenTransfers(_trade.collateralDeltaUSDC, marketKey, _trade.isLong, true);
        } else {
            // Convert USDC to USDE
            collateralDeltaUSDE = _trade.collateralDeltaUSDC * COLLATERAL_MULTIPLIER;
        }
        // Calculate Request Type
        Request.Type requestType = _getRequestType(_trade, position, collateralDeltaUSDE);
        // Send Fee for Execution to Vault to be sent to whoever executes the request
        _sendExecutionFeeToVault();
        // Construct Request
        Request.Data memory request = TradeHelper.createRequest(_trade, msg.sender, collateralDeltaUSDE, requestType);
        // Send Constructed Request to Storage
        tradeStorage.createOrderRequest(request);
    }

    function cancelOrderRequest(bytes32 _key, bool _isLimit) external payable nonReentrant {
        // Fetch the Request
        Request.Data memory request = tradeStorage.orders(_key);
        // Check it exists
        require(request.user != address(0), "RR: Request Doesn't Exist");
        // Check the caller is the position owner
        require(msg.sender == request.user, "RR: Not Position Owner");
        // Cancel the Request
        ITradeStorage(tradeStorage).cancelOrderRequest(_key, _isLimit);
    }

    /// @notice Calculate and return the requestType
    function _getRequestType(
        Request.Input calldata _trade,
        Position.Data memory _position,
        uint256 _collateralDeltaUSDE
    ) private pure returns (Request.Type requestType) {
        // Case 1: Position doesn't exist (Create Position)
        if (_position.user == address(0)) {
            require(_trade.isIncrease, "RR: Invalid Decrease");
            require(_trade.sizeDelta != 0, "RR: Size Delta");
            requestType = Request.Type.CREATE_POSITION;
        } else if (_trade.sizeDelta == 0) {
            // Case 2: Position exists but sizeDelta is 0 (Collateral Increase / Decrease)
            if (_trade.isIncrease) {
                requestType = Request.Type.COLLATERAL_INCREASE;
            } else {
                require(_position.collateralAmount >= _collateralDeltaUSDE, "RR: CD > CA");
                requestType = Request.Type.COLLATERAL_DECREASE;
            }
        } else {
            // Case 3: Position exists and sizeDelta is not 0 (Position Increase / Decrease)
            require(_trade.sizeDelta != 0, "RR: Size Delta");
            if (_trade.isIncrease) {
                requestType = Request.Type.POSITION_INCREASE;
            } else {
                require(_position.positionSize >= _trade.sizeDelta, "RR: PS < SD");
                require(_position.collateralAmount >= _collateralDeltaUSDE, "RR: CD > CA");
                requestType = Request.Type.POSITION_DECREASE;
            }
        }
    }

    function _handleTokenTransfers(uint256 _amountInUSDC, bytes32 _marketKey, bool _isLong, bool _isIncrease)
        private
        returns (uint256 amountOutUSDE)
    {
        IERC20 usdc = USDE.USDC();
        usdc.safeTransferFrom(msg.sender, address(this), _amountInUSDC);
        usdc.safeIncreaseAllowance(address(USDE), _amountInUSDC);
        amountOutUSDE = USDE.deposit(_amountInUSDC);
        tradeVault.updateCollateralBalance(_marketKey, amountOutUSDE, _isLong, _isIncrease);
        USDE.safeTransfer(address(tradeVault), amountOutUSDE);
    }

    function _sendExecutionFeeToVault() private {
        uint256 executionFee = tradeStorage.executionFee();
        (bool success,) = address(tradeVault).call{value: executionFee}("");
        require(success, "RR: Fee Transfer Failed");
    }

    /// @dev -> Needs conversion into USD
    function _validateAllocation(bytes32 _marketKey, uint256 _sizeDelta) private view {
        Market.Data memory market = marketMaker.markets(_marketKey);
        uint256 totalOI = MarketHelper.getTotalIndexOpenInterest(address(marketMaker), market.indexToken);
        require(totalOI + _sizeDelta <= market.pricing.maxOpenInterestUSD, "RR: Max Alloc");
    }
}
