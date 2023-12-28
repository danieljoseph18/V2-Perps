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
    function executeTradeOrder(bytes32 _key, address _feeReceiver, bool _isLimit)
        external
        nonReentrant
        onlyKeeperOrContract
        returns (bool wasExecuted)
    {
        MarketStructs.Request memory request = tradeStorage.orders(_key);
        if (request.user == address(0)) revert Executor_InvalidRequestKey();
        if (_feeReceiver == address(0)) revert Executor_ZeroAddress();
        // Fetch and validate price
        uint256 signedBlockPrice = priceOracle.getSignedPrice(request.indexToken, request.requestBlock);
        if (signedBlockPrice == 0) revert Executor_InvalidExecutionPrice();
        if (_isLimit) TradeHelper.checkLimitPrice(signedBlockPrice, request);

        address market = MarketHelper.getMarketFromIndexToken(address(marketStorage), request.indexToken).market;
        uint256 price = ImpactCalculator.executePriceImpact(
            market, address(marketStorage), address(dataOracle), address(priceOracle), request, signedBlockPrice
        );
        int256 sizeDeltaUsd = _calculateSizeDeltaUsd(request, signedBlockPrice);

        _updateMarketState(market, request, price, sizeDeltaUsd);

        MarketStructs.Position memory position = tradeStorage.openPositions(_key);

        if (position.user == address(0)) {
            tradeStorage.createNewPosition(MarketStructs.ExecutionParams(request, price, _feeReceiver));
        } else if (request.sizeDelta == 0) {
            if (request.isIncrease) {
                tradeStorage.executeCollateralIncrease(MarketStructs.ExecutionParams(request, price, _feeReceiver));
            } else {
                tradeStorage.executeCollateralDecrease(MarketStructs.ExecutionParams(request, price, _feeReceiver));
            }
        } else {
            if (request.isIncrease) {
                tradeStorage.increaseExistingPosition(MarketStructs.ExecutionParams(request, price, _feeReceiver));
            } else {
                tradeStorage.decreaseExistingPosition(MarketStructs.ExecutionParams(request, price, _feeReceiver));
            }
        }

        wasExecuted = true;
    }

    function _calculateSizeDeltaUsd(MarketStructs.Request memory request, uint256 signedBlockPrice)
        internal
        view
        returns (int256)
    {
        uint256 sizeDeltaUsd =
            TradeHelper.getTradeValueUsd(address(dataOracle), request.indexToken, request.sizeDelta, signedBlockPrice);
        return request.isIncrease ? int256(sizeDeltaUsd) : -int256(sizeDeltaUsd);
    }

    function _updateMarketState(
        address market,
        MarketStructs.Request memory request,
        uint256 price,
        int256 sizeDeltaUsd
    ) internal {
        bytes32 marketKey = IMarket(market).getMarketKey();
        IMarketStorage(marketStorage).updateOpenInterest(
            marketKey, request.collateralDelta, request.sizeDelta, request.isLong, request.isIncrease
        );
        IMarket(market).updateFundingRate();
        IMarket(market).updateBorrowingRate(request.isLong);
        if (sizeDeltaUsd != 0) {
            IMarket(market).updateTotalWAEP(price, sizeDeltaUsd, request.isLong);
        }
    }
}
