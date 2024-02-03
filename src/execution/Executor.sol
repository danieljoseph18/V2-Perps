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

/// @dev Needs Executor Role
// All keeper interactions should come through this contract
contract Executor is RoleValidation, ReentrancyGuard {
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
        try liquidityVault.executeDeposit(_key) {}
        catch {
            revert("E: Execute Deposit Failed");
        }
    }

    function executeWithdrawal(bytes32 _key) external nonReentrant onlyKeeper {
        require(_key != bytes32(0), "E: Invalid Key");
        try liquidityVault.executeWithdrawal(_key) {}
        catch {
            revert("E: Execute Withdrawal Failed");
        }
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
        uint256 signedBlockPrice = priceOracle.getSignedPrice(request.indexToken, request.requestBlock);
        require(signedBlockPrice != 0, "E: Invalid Price");
        if (_isLimitOrder) Position.checkLimitPrice(signedBlockPrice, request);

        // Execute Price Impact
        IMarket market = IMarket(marketMaker.tokenToMarkets(request.indexToken));
        uint256 baseUnit = dataOracle.getBaseUnits(request.indexToken);
        uint256 impactedPrice = PriceImpact.execute(market, request, signedBlockPrice, baseUnit);

        (bool isValid,,,, uint256 longMarketTokenPrice, uint256 shortMarketTokenPrice) =
            dataOracle.blockData(request.requestBlock);
        require(isValid, "E: Invalid Block Data");
        // Update Market State
        int256 sizeDeltaUsd = _calculateSizeDeltaUsd(request, signedBlockPrice);
        _updateMarketState(
            market, request, impactedPrice, signedBlockPrice, longMarketTokenPrice, shortMarketTokenPrice, sizeDeltaUsd
        );

        // Execute Trade
        if (request.requestType == Position.RequestType.CREATE_POSITION) {
            tradeStorage.createNewPosition(Position.RequestExecution(request, impactedPrice, _feeReceiver));
        } else if (request.requestType == Position.RequestType.POSITION_DECREASE) {
            tradeStorage.decreaseExistingPosition(Position.RequestExecution(request, impactedPrice, _feeReceiver));
        } else if (request.requestType == Position.RequestType.POSITION_INCREASE) {
            tradeStorage.increaseExistingPosition(Position.RequestExecution(request, impactedPrice, _feeReceiver));
        } else if (request.requestType == Position.RequestType.COLLATERAL_DECREASE) {
            tradeStorage.executeCollateralDecrease(Position.RequestExecution(request, impactedPrice, _feeReceiver));
        } else if (request.requestType == Position.RequestType.COLLATERAL_INCREASE) {
            tradeStorage.executeCollateralIncrease(Position.RequestExecution(request, impactedPrice, _feeReceiver));
        } else {
            revert Executor_InvalidRequestType();
        }
    }

    function _calculateSizeDeltaUsd(Position.RequestData memory _request, uint256 _signedIndexPrice)
        internal
        view
        returns (int256 sizeDeltaUsd)
    {
        // Flip sign if decreasing position
        if (_request.isIncrease) {
            sizeDeltaUsd = int256(
                Position.getTradeValueUsd(dataOracle, _request.indexToken, _request.sizeDelta, _signedIndexPrice)
            );
        } else {
            sizeDeltaUsd = -1
                * int256(Position.getTradeValueUsd(dataOracle, _request.indexToken, _request.sizeDelta, _signedIndexPrice));
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
        _market.updateOpenInterest(_request.sizeDelta, _request.isLong, _request.isIncrease);
        _market.updateFundingRate();
        _market.updateBorrowingRate(_signedIndexPrice, _longTokenPrice, _shortTokenPrice, _request.isLong);
        if (_sizeDeltaUsd != 0) {
            _market.updateTotalWAEP(_impactedIndexPrice, _sizeDeltaUsd, _request.isLong);
        }
    }
}
