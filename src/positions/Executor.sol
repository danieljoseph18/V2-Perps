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
pragma solidity 0.8.22;

import {IMarketStorage} from "../markets/interfaces/IMarketStorage.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {ITradeStorage} from "./interfaces/ITradeStorage.sol";
import {MarketStructs} from "../markets/MarketStructs.sol";
import {IPriceOracle} from "../oracle/interfaces/IPriceOracle.sol";
import {IDataOracle} from "../oracle/interfaces/IDataOracle.sol";
import {ILiquidityVault} from "../markets/interfaces/ILiquidityVault.sol";
import {RoleValidation} from "../access/RoleValidation.sol";
import {TradeHelper} from "./TradeHelper.sol";
import {ImpactCalculator} from "./ImpactCalculator.sol";
import {MarketHelper} from "../markets/MarketHelper.sol";
import {ReentrancyGuard} from "@solmate/utils/ReentrancyGuard.sol";

/// @dev Needs Executor Role
contract Executor is RoleValidation, ReentrancyGuard {
    error Executor_LimitNotHit();

    IMarketStorage public marketStorage;
    ITradeStorage public tradeStorage;
    ILiquidityVault public liquidityVault;
    IPriceOracle public priceOracle;
    IDataOracle public dataOracle;

    error Executor_InvalidRequestKey();
    error Executor_InvalidDecrease();
    error Executor_InvalidExecutionPrice();

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
        bytes32[] memory marketOrders = tradeStorage.getPendingMarketOrders();
        uint32 len = uint32(marketOrders.length);
        for (uint256 i = 0; i < len;) {
            bytes32 _key = marketOrders[i];
            try this.executeTradeOrder(_key, _feeReceiver, false) {}
            catch {
                try tradeStorage.cancelOrderRequest(_key, false) returns (bool _wasCancelled) {
                    if (!_wasCancelled) break;
                } catch {}
            }
            unchecked {
                ++i;
            }
        }
        tradeStorage.updateOrderStartIndex();
    }

    /// @dev Only Keeper
    function executeTradeOrder(bytes32 _key, address _feeReceiver, bool _isLimit)
        external
        nonReentrant
        onlyKeeperOrContract
        returns (bool wasExecuted)
    {
        MarketStructs.PositionRequest memory positionRequest = tradeStorage.orders(_isLimit, _key);
        if (positionRequest.user == address(0)) revert Executor_InvalidRequestKey();
        address market = MarketHelper.getMarketFromIndexToken(address(marketStorage), positionRequest.indexToken).market;
        uint256 signedBlockPrice = priceOracle.getSignedPrice(market, positionRequest.requestBlock);
        if (signedBlockPrice == 0) revert Executor_InvalidExecutionPrice();
        if (_isLimit) TradeHelper.checkLimitPrice(signedBlockPrice, positionRequest);

        uint256 price = ImpactCalculator.executePriceImpact(
            market, address(marketStorage), address(dataOracle), address(priceOracle), positionRequest, signedBlockPrice
        );
        int256 sizeDeltaUsd = _calculateSizeDeltaUsd(positionRequest, signedBlockPrice);

        if (!positionRequest.isIncrease) {
            if (tradeStorage.openPositions(_key).positionSize < positionRequest.sizeDelta) {
                revert Executor_InvalidDecrease();
            }
        }

        _updateMarketState(market, positionRequest, price, sizeDeltaUsd);

        tradeStorage.executeTrade(MarketStructs.ExecutionParams(positionRequest, price, _feeReceiver));

        wasExecuted = true;
    }

    function _calculateSizeDeltaUsd(MarketStructs.PositionRequest memory positionRequest, uint256 signedBlockPrice)
        internal
        view
        returns (int256)
    {
        uint256 sizeDeltaUsd = TradeHelper.getTradeValueUsd(
            address(dataOracle), positionRequest.indexToken, positionRequest.sizeDelta, signedBlockPrice
        );
        return positionRequest.isIncrease ? int256(sizeDeltaUsd) : -int256(sizeDeltaUsd);
    }

    function _updateMarketState(
        address market,
        MarketStructs.PositionRequest memory positionRequest,
        uint256 price,
        int256 sizeDeltaUsd
    ) internal {
        bytes32 marketKey = IMarket(market).getMarketKey();
        IMarketStorage(marketStorage).updateOpenInterest(
            marketKey,
            positionRequest.collateralDelta,
            positionRequest.sizeDelta,
            positionRequest.isLong,
            positionRequest.isIncrease
        );
        IMarket(market).updateFundingRate();
        IMarket(market).updateBorrowingRate(positionRequest.isLong);
        if (sizeDeltaUsd != 0) {
            IMarket(market).updateTotalWAEP(price, sizeDeltaUsd, positionRequest.isLong);
        }
    }
}
