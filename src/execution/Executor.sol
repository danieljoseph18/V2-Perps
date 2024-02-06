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

import {IMarket} from "../markets/interfaces/IMarket.sol";
import {ITradeStorage} from "../positions/interfaces/ITradeStorage.sol";
import {IPriceOracle} from "../oracle/interfaces/IPriceOracle.sol";
import {IDataOracle} from "../oracle/interfaces/IDataOracle.sol";
import {ILiquidityVault} from "../liquidity/interfaces/ILiquidityVault.sol";
import {IMarketMaker} from "../markets/interfaces/IMarketMaker.sol";
import {RoleValidation} from "../access/RoleValidation.sol";
import {PriceImpact} from "../libraries/PriceImpact.sol";
import {ReentrancyGuard} from "@solmate/utils/ReentrancyGuard.sol";
import {Position} from "../positions/Position.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MarketUtils} from "../markets/MarketUtils.sol";

/// @dev Needs Executor Role
// All keeper interactions should come through this contract
contract Executor is RoleValidation, ReentrancyGuard {
    using SafeERC20 for IERC20;

    ITradeStorage public tradeStorage;
    ILiquidityVault public liquidityVault;
    IPriceOracle public priceOracle;
    IDataOracle public dataOracle;
    IMarketMaker public marketMaker;

    error Executor_InvalidRequestType();

    constructor(
        address _marketMaker,
        address _tradeStorage,
        address _priceOracle,
        address _liquidityVault,
        address _dataOracle,
        address _roleStorage
    ) RoleValidation(_roleStorage) {
        marketMaker = IMarketMaker(_marketMaker);
        tradeStorage = ITradeStorage(_tradeStorage);
        priceOracle = IPriceOracle(_priceOracle);
        liquidityVault = ILiquidityVault(_liquidityVault);
        dataOracle = IDataOracle(_dataOracle);
    }

    /////////////////////////
    // MARKET INTERACTIONS //
    /////////////////////////

    function executeDeposit(bytes32 _key) external nonReentrant onlyKeeper {
        require(_key != bytes32(0), "E: Invalid Key");
        try liquidityVault.executeDeposit(_key, msg.sender) {}
        catch {
            revert("E: Execute Deposit Failed");
        }
    }

    function executeWithdrawal(bytes32 _key) external nonReentrant onlyKeeper {
        require(_key != bytes32(0), "E: Invalid Key");
        try liquidityVault.executeWithdrawal(_key, msg.sender) {}
        catch {
            revert("E: Execute Withdrawal Failed");
        }
    }

    // Used to transfer intermediary tokens to the vault from deposits
    function transferDepositTokens(address _token, uint256 _amount) external onlyVault {
        IERC20(_token).safeTransfer(address(liquidityVault), _amount);
    }

    /////////////
    // TRADING //
    /////////////

    function executeTradeOrders(address _feeReceiver) external onlyKeeper {
        bytes32[] memory marketOrders = tradeStorage.getOrderKeys(false);
        uint32 len = uint32(marketOrders.length);
        for (uint256 i = 0; i < len;) {
            bytes32 _key = marketOrders[i];
            try this.executeTradeOrder(_key, _feeReceiver, false) {}
            catch {
                try tradeStorage.cancelOrderRequest(_key, false) {} catch {}
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Only Keeper
    // @audit - Need a step to validate the trade doesn't put the market over its
    // allocation (_validateAllocation)
    function executeTradeOrder(bytes32 _orderKey, address _feeReceiver, bool _isLimitOrder)
        external
        nonReentrant
        onlyKeeperOrSelf
    {
        // Fetch and validate request from key
        Position.RequestData memory request = tradeStorage.getOrder(_orderKey);
        require(request.user != address(0), "E: Request Key");
        require(_feeReceiver != address(0), "E: Fee Receiver");
        // Fetch and validate price
        uint256 signedBlockPrice = priceOracle.getSignedPrice(request.input.indexToken, request.requestBlock);
        require(signedBlockPrice != 0, "E: Invalid Price");
        if (_isLimitOrder) Position.checkLimitPrice(signedBlockPrice, request);

        // Execute Price Impact
        IMarket market = IMarket(marketMaker.tokenToMarkets(request.input.indexToken));
        uint256 indexBaseUnit = dataOracle.getBaseUnits(request.input.indexToken);
        uint256 impactedPrice = PriceImpact.execute(market, request, signedBlockPrice, indexBaseUnit);

        (uint256 longMarketTokenPrice, uint256 shortMarketTokenPrice) =
            MarketUtils.validateAndRetrievePrices(dataOracle, request.requestBlock);

        // Update Market State
        int256 sizeDeltaUsd = _calculateSizeDeltaUsd(request, signedBlockPrice, indexBaseUnit);
        _updateMarketState(
            market, request, impactedPrice, signedBlockPrice, longMarketTokenPrice, shortMarketTokenPrice, sizeDeltaUsd
        );

        uint256 collateralPrice = request.input.isLong ? longMarketTokenPrice : shortMarketTokenPrice;

        // Execute Trade
        if (request.requestType == Position.RequestType.CREATE_POSITION) {
            tradeStorage.createNewPosition(
                Position.RequestExecution(request, impactedPrice, collateralPrice, _feeReceiver, false)
            );
        } else if (request.requestType == Position.RequestType.POSITION_DECREASE) {
            tradeStorage.decreaseExistingPosition(
                Position.RequestExecution(request, impactedPrice, collateralPrice, _feeReceiver, false)
            );
        } else if (request.requestType == Position.RequestType.POSITION_INCREASE) {
            tradeStorage.increaseExistingPosition(
                Position.RequestExecution(request, impactedPrice, collateralPrice, _feeReceiver, false)
            );
        } else if (request.requestType == Position.RequestType.COLLATERAL_DECREASE) {
            tradeStorage.executeCollateralDecrease(
                Position.RequestExecution(request, impactedPrice, collateralPrice, _feeReceiver, false)
            );
        } else if (request.requestType == Position.RequestType.COLLATERAL_INCREASE) {
            tradeStorage.executeCollateralIncrease(
                Position.RequestExecution(request, impactedPrice, collateralPrice, _feeReceiver, false)
            );
        } else {
            revert Executor_InvalidRequestType();
        }
    }

    // need to store who flagged and liquidated
    // let the liquidator claim liquidation rewards from the tradestorage contract
    function liquidatePosition(bytes32 _positionKey) external onlyKeeper {
        // check if position is flagged for liquidation
        // uint256 collateralPrice = priceOracle.getCollateralPrice();
        // fetch data to execute liquidations
        // call _updateMarketState
        // liquidate the position
        // tradeStorage.liquidatePosition(_positionKey, collateralPrice);
    }

    ///////////////////////////////
    // INTERNAL HELPER FUNCTIONS //
    ///////////////////////////////

    function _calculateSizeDeltaUsd(
        Position.RequestData memory _request,
        uint256 _signedIndexPrice,
        uint256 _indexBaseUnit
    ) internal pure returns (int256 sizeDeltaUsd) {
        // Flip sign if decreasing position
        if (_request.input.isIncrease) {
            sizeDeltaUsd =
                int256(Position.getTradeValueUsd(_request.input.sizeDelta, _signedIndexPrice, _indexBaseUnit));
        } else {
            sizeDeltaUsd =
                -1 * int256(Position.getTradeValueUsd(_request.input.sizeDelta, _signedIndexPrice, _indexBaseUnit));
        }
    }

    function _updateMarketState(
        IMarket _market,
        Position.RequestData memory _request,
        uint256 _impactedIndexPrice,
        uint256 _signedIndexPrice,
        uint256 _longTokenPrice,
        uint256 _shortTokenPrice,
        int256 _sizeDeltaUsd
    ) internal {
        _market.updateOpenInterest(_request.input.sizeDelta, _request.input.isLong, _request.input.isIncrease);
        _market.updateFundingRate();
        _market.updateBorrowingRate(_signedIndexPrice, _longTokenPrice, _shortTokenPrice, _request.input.isLong);
        if (_sizeDeltaUsd != 0) {
            _market.updateTotalWAEP(_impactedIndexPrice, _sizeDeltaUsd, _request.input.isLong);
        }
    }
}
