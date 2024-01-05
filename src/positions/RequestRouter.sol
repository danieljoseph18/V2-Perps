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

import {Types} from "../libraries/Types.sol";
import {ITradeStorage} from "./interfaces/ITradeStorage.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ILiquidityVault} from "../markets/interfaces/ILiquidityVault.sol";
import {IMarketStorage} from "../markets/interfaces/IMarketStorage.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {ITradeVault} from "./interfaces/ITradeVault.sol";
import {PriceImpact} from "../libraries/PriceImpact.sol";
import {TradeHelper} from "./TradeHelper.sol";
import {MarketHelper} from "../markets/MarketHelper.sol";
import {IUSDE} from "../token/interfaces/IUSDE.sol";
import {ReentrancyGuard} from "@solmate/utils/ReentrancyGuard.sol";

/// @dev Needs Router role
contract RequestRouter is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeERC20 for IUSDE;

    ITradeStorage tradeStorage;
    ILiquidityVault liquidityVault;
    IMarketStorage marketStorage;
    ITradeVault tradeVault;
    IUSDE immutable USDE;

    uint256 constant PRECISION = 1e18;
    uint256 constant COLLATERAL_MULTIPLIER = 1e12;
    uint256 constant MIN_SLIPPAGE = 0.0003e18; // 0.03%
    uint256 constant MAX_SLIPPAGE = 0.99e18; // 99%

    constructor(
        address _tradeStorage,
        address _liquidityVault,
        address _marketStorage,
        address _tradeVault,
        address _usde
    ) {
        tradeStorage = ITradeStorage(_tradeStorage);
        liquidityVault = ILiquidityVault(_liquidityVault);
        marketStorage = IMarketStorage(_marketStorage);
        tradeVault = ITradeVault(_tradeVault);
        USDE = IUSDE(_usde);
    }

    modifier validExecutionFee() {
        require(msg.value == tradeStorage.executionFee(), "RR: Execution Fee");
        _;
    }

    /// @dev collateralDelta always in USDC
    function createTradeRequest(Types.Trade calldata _trade) external payable nonReentrant validExecutionFee {
        require(_trade.maxSlippage >= MIN_SLIPPAGE && _trade.maxSlippage <= MAX_SLIPPAGE, "RR: Slippage");
        require(_trade.collateralDeltaUSDC != 0, "RR: Collateral Delta");

        // Check if Market exists
        bytes32 marketKey = keccak256(abi.encode(_trade.indexToken));
        Types.Market memory market = marketStorage.markets(marketKey);
        require(market.exists, "RR: Market Doesn't Exist");
        // Create a Pointer to the Position
        bytes32 positionKey = keccak256(abi.encode(_trade.indexToken, msg.sender, _trade.isLong));
        Types.Position memory position = tradeStorage.openPositions(positionKey);

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
        Types.RequestType requestType = _getRequestType(_trade, position, collateralDeltaUSDE);
        // Send Fee for Execution to Vault to be sent to whoever executes the request
        _sendExecutionFeeToVault();
        // Construct Request
        Types.Request memory request = TradeHelper.createRequest(_trade, msg.sender, collateralDeltaUSDE, requestType);
        // Send Constructed Request to Storage
        tradeStorage.createOrderRequest(request);
    }

    function cancelOrderRequest(bytes32 _key, bool _isLimit) external payable nonReentrant {
        // Fetch the Request
        Types.Request memory request = tradeStorage.orders(_key);
        // Check it exists
        require(request.user != address(0), "RR: Request Doesn't Exist");
        // Check the caller is the position owner
        require(msg.sender == request.user, "RR: Not Position Owner");
        // Cancel the Request
        ITradeStorage(tradeStorage).cancelOrderRequest(_key, _isLimit);
    }

    /// @notice Calculate and return the requestType
    function _getRequestType(Types.Trade calldata _trade, Types.Position memory _position, uint256 _collateralDeltaUSDE)
        private
        pure
        returns (Types.RequestType requestType)
    {
        // Case 1: Position doesn't exist (Create Position)
        if (_position.user == address(0)) {
            require(_trade.isIncrease, "RR: Invalid Decrease");
            require(_trade.sizeDelta != 0, "RR: Size Delta");
            requestType = Types.RequestType.CREATE_POSITION;
        } else if (_trade.sizeDelta == 0) {
            // Case 2: Position exists but sizeDelta is 0 (Collateral Increase / Decrease)
            if (_trade.isIncrease) {
                requestType = Types.RequestType.COLLATERAL_INCREASE;
            } else {
                require(_position.collateralAmount >= _collateralDeltaUSDE, "RR: CD > CA");
                requestType = Types.RequestType.COLLATERAL_DECREASE;
            }
        } else {
            // Case 3: Position exists and sizeDelta is not 0 (Position Increase / Decrease)
            require(_trade.sizeDelta != 0, "RR: Size Delta");
            if (_trade.isIncrease) {
                requestType = Types.RequestType.POSITION_INCREASE;
            } else {
                require(_position.positionSize >= _trade.sizeDelta, "RR: PS < SD");
                require(_position.collateralAmount >= _collateralDeltaUSDE, "RR: CD > CA");
                requestType = Types.RequestType.POSITION_DECREASE;
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

    function _validateAllocation(bytes32 _marketKey, uint256 _sizeDelta) private view {
        Types.Market memory market = marketStorage.markets(_marketKey);
        uint256 totalOI = MarketHelper.getTotalIndexOpenInterest(address(marketStorage), market.indexToken);
        require(totalOI + _sizeDelta <= marketStorage.maxOpenInterests(_marketKey), "RR: Max Alloc");
    }
}
