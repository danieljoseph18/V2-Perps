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

import {IMarketMaker} from "../markets/interfaces/IMarketMaker.sol";
import {ITradeStorage} from "./interfaces/ITradeStorage.sol";
import {IPriceOracle} from "../oracle/interfaces/IPriceOracle.sol";
import {IDataOracle} from "../oracle/interfaces/IDataOracle.sol";
import {ILiquidityVault} from "../liquidity/interfaces/ILiquidityVault.sol";
import {RoleValidation} from "../access/RoleValidation.sol";
import {TradeHelper} from "./TradeHelper.sol";
import {PriceImpact} from "../libraries/PriceImpact.sol";
import {MarketHelper} from "../markets/MarketHelper.sol";
import {ReentrancyGuard} from "@solmate/utils/ReentrancyGuard.sol";
import {PositionRequest} from "../structs/PositionRequest.sol";
import {Position} from "../structs/Position.sol";

/// @dev Needs Executor Role
contract Executor is RoleValidation, ReentrancyGuard {
    IMarketMaker public marketMaker;
    ITradeStorage public tradeStorage;
    ILiquidityVault public liquidityVault;
    IPriceOracle public priceOracle;
    IDataOracle public dataOracle;

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
        PositionRequest.Data memory request = tradeStorage.orders(_orderKey);
        require(request.user != address(0), "E: Request Key");
        require(_feeReceiver != address(0), "E: Fee Receiver");
        // Fetch and validate price
        uint256 signedBlockPrice = priceOracle.getSignedPrice(request.indexToken, request.requestBlock);
        require(signedBlockPrice != 0, "E: Invalid Price");
        if (_isLimitOrder) TradeHelper.checkLimitPrice(signedBlockPrice, request);

        // Execute Price Impact
        bytes32 marketKey = keccak256(abi.encode(request.indexToken));
        uint256 impactedPrice = PriceImpact.execute(
            marketKey, address(marketMaker), address(dataOracle), address(priceOracle), request, signedBlockPrice
        );
        // Update Market State
        int256 sizeDeltaUsd = _calculateSizeDeltaUsd(request, signedBlockPrice);
        _updateMarketState(marketKey, request, impactedPrice, sizeDeltaUsd);

        // Execute Trade
        if (request.requestType == PositionRequest.Type.CREATE_POSITION) {
            tradeStorage.createNewPosition(PositionRequest.Execution(request, impactedPrice, _feeReceiver));
        } else if (request.requestType == PositionRequest.Type.POSITION_DECREASE) {
            tradeStorage.decreaseExistingPosition(PositionRequest.Execution(request, impactedPrice, _feeReceiver));
        } else if (request.requestType == PositionRequest.Type.POSITION_INCREASE) {
            tradeStorage.increaseExistingPosition(PositionRequest.Execution(request, impactedPrice, _feeReceiver));
        } else if (request.requestType == PositionRequest.Type.COLLATERAL_DECREASE) {
            tradeStorage.executeCollateralDecrease(PositionRequest.Execution(request, impactedPrice, _feeReceiver));
        } else if (request.requestType == PositionRequest.Type.COLLATERAL_INCREASE) {
            tradeStorage.executeCollateralIncrease(PositionRequest.Execution(request, impactedPrice, _feeReceiver));
        } else {
            revert Executor_InvalidRequestType();
        }
    }

    function _calculateSizeDeltaUsd(PositionRequest.Data memory _request, uint256 _signedIndexPrice)
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
        bytes32 _marketKey,
        PositionRequest.Data memory _request,
        uint256 _impactedIndexPrice,
        int256 _sizeDeltaUsd
    ) internal {
        IMarketMaker(marketMaker).updateOpenInterest(
            _marketKey, _request.collateralDelta, _request.sizeDelta, _request.isLong, _request.isIncrease
        );
        IMarketMaker(marketMaker).updateFundingRate(_marketKey);
        IMarketMaker(marketMaker).updateBorrowingRate(_marketKey, _request.isLong);
        if (_sizeDeltaUsd != 0) {
            IMarketMaker(marketMaker).updateTotalWAEP(_marketKey, _impactedIndexPrice, _sizeDeltaUsd, _request.isLong);
        }
    }
}
