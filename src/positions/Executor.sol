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
import {IMarketStorage} from "../markets/interfaces/IMarketStorage.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {ITradeStorage} from "./interfaces/ITradeStorage.sol";
import {IPriceOracle} from "../oracle/interfaces/IPriceOracle.sol";
import {IDataOracle} from "../oracle/interfaces/IDataOracle.sol";
import {ILiquidityVault} from "../markets/interfaces/ILiquidityVault.sol";
import {RoleValidation} from "../access/RoleValidation.sol";
import {TradeHelper} from "./TradeHelper.sol";
import {PriceImpact} from "../libraries/PriceImpact.sol";
import {MarketHelper} from "../markets/MarketHelper.sol";
import {ReentrancyGuard} from "@solmate/utils/ReentrancyGuard.sol";

/// @dev Needs Executor Role
contract Executor is RoleValidation, ReentrancyGuard {
    error Executor_LimitNotHit();
    error Executor_InvalidIncrease();
    error Executor_ZeroAddress();

    IMarketStorage public marketStorage;
    ITradeStorage public tradeStorage;
    ILiquidityVault public liquidityVault;
    IPriceOracle public priceOracle;
    IDataOracle public dataOracle;

    error Executor_InvalidRequestKey();
    error Executor_InvalidDecrease();
    error Executor_InvalidExecutionPrice();
    error Executor_InvalidRequestType();

    constructor(
        address _marketStorage,
        address _tradeStorage,
        address _priceOracle,
        address _liquidityVault,
        address _dataOracle,
        address _roleStorage
    ) RoleValidation(_roleStorage) {
        marketStorage = IMarketStorage(_marketStorage);
        tradeStorage = ITradeStorage(_tradeStorage);
        priceOracle = IPriceOracle(_priceOracle);
        liquidityVault = ILiquidityVault(_liquidityVault);
        dataOracle = IDataOracle(_dataOracle);
    }

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
    function executeTradeOrder(bytes32 _orderKey, address _feeReceiver, bool _isLimitOrder)
        external
        nonReentrant
        onlyKeeperOrSelf
    {
        // Fetch and validate request from key
        Types.Request memory request = tradeStorage.orders(_orderKey);
        if (request.user == address(0)) revert Executor_InvalidRequestKey();
        if (_feeReceiver == address(0)) revert Executor_ZeroAddress();
        // Fetch and validate price
        uint256 signedBlockPrice = priceOracle.getSignedPrice(request.indexToken, request.requestBlock);
        if (signedBlockPrice == 0) revert Executor_InvalidExecutionPrice();
        if (_isLimitOrder) TradeHelper.checkLimitPrice(signedBlockPrice, request);

        // Execute Price Impact
        address market = MarketHelper.getMarketFromIndexToken(address(marketStorage), request.indexToken).market;
        uint256 impactedPrice = PriceImpact.execute(
            market, address(marketStorage), address(dataOracle), address(priceOracle), request, signedBlockPrice
        );
        // Update Market State
        int256 sizeDeltaUsd = _calculateSizeDeltaUsd(request, signedBlockPrice);
        _updateMarketState(market, request, impactedPrice, sizeDeltaUsd);

        // Execute Trade
        if (request.requestType == Types.RequestType.CREATE_POSITION) {
            tradeStorage.createNewPosition(Types.ExecutionParams(request, impactedPrice, _feeReceiver));
        } else if (request.requestType == Types.RequestType.POSITION_DECREASE) {
            tradeStorage.decreaseExistingPosition(Types.ExecutionParams(request, impactedPrice, _feeReceiver));
        } else if (request.requestType == Types.RequestType.POSITION_INCREASE) {
            tradeStorage.increaseExistingPosition(Types.ExecutionParams(request, impactedPrice, _feeReceiver));
        } else if (request.requestType == Types.RequestType.COLLATERAL_DECREASE) {
            tradeStorage.executeCollateralDecrease(Types.ExecutionParams(request, impactedPrice, _feeReceiver));
        } else if (request.requestType == Types.RequestType.COLLATERAL_INCREASE) {
            tradeStorage.executeCollateralIncrease(Types.ExecutionParams(request, impactedPrice, _feeReceiver));
        } else {
            revert Executor_InvalidRequestType();
        }
    }

    function _calculateSizeDeltaUsd(Types.Request memory _request, uint256 _signedIndexPrice)
        internal
        view
        returns (int256 sizeDeltaUsd)
    {
        // Flip sign if decreasing position
        if (_request.isIncrease) {
            sizeDeltaUsd = int256(
                TradeHelper.getTradeValueUsd(
                    address(dataOracle), _request.indexToken, _request.sizeDelta, _signedIndexPrice
                )
            );
        } else {
            sizeDeltaUsd = -1
                * int256(
                    TradeHelper.getTradeValueUsd(
                        address(dataOracle), _request.indexToken, _request.sizeDelta, _signedIndexPrice
                    )
                );
        }
    }

    function _updateMarketState(
        address _market,
        Types.Request memory _request,
        uint256 _impactedIndexPrice,
        int256 _sizeDeltaUsd
    ) internal {
        IMarket market = IMarket(_market);
        bytes32 marketKey = market.getMarketKey();
        IMarketStorage(marketStorage).updateOpenInterest(
            marketKey, _request.collateralDelta, _request.sizeDelta, _request.isLong, _request.isIncrease
        );
        market.updateFundingRate();
        market.updateBorrowingRate(_request.isLong);
        if (_sizeDeltaUsd != 0) {
            market.updateTotalWAEP(_impactedIndexPrice, _sizeDeltaUsd, _request.isLong);
        }
    }
}
