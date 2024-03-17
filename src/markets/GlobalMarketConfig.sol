// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {ITradeStorage} from "../positions/interfaces/ITradeStorage.sol";
import {RoleValidation} from "../access/RoleValidation.sol";
import {IPriceFeed} from "../oracle/interfaces/IPriceFeed.sol";
import {IMarketMaker} from "./interfaces/IMarketMaker.sol";
import {IProcessor} from "../router/interfaces/IProcessor.sol";
import {IMarket} from "./interfaces/IMarket.sol";
import {Router} from "../router/Router.sol";

/// @dev Needs Configurator Role
contract GlobalMarketConfig is RoleValidation {
    ITradeStorage public tradeStorage;
    IMarketMaker public marketMaker;
    IProcessor public processor;
    Router public router;
    IPriceFeed public priceFeed;

    error GlobalMarketConfig_PriceFeedNotSet();
    error GlobalMarketConfig_MarketDoesNotExist();

    constructor(
        address _tradeStorage,
        address _marketMaker,
        address payable _processor,
        address payable _priceFeed,
        address payable _router,
        address _roleStorage
    ) RoleValidation(_roleStorage) {
        tradeStorage = ITradeStorage(_tradeStorage);
        marketMaker = IMarketMaker(_marketMaker);
        processor = IProcessor(_processor);
        router = Router(_router);
        priceFeed = IPriceFeed(_priceFeed);
    }

    function setTargetContracts(
        address _tradeStorage,
        address _marketMaker,
        address payable _processor,
        address payable _router,
        address _priceFeed
    ) external onlyModerator {
        tradeStorage = ITradeStorage(_tradeStorage);
        marketMaker = IMarketMaker(_marketMaker);
        processor = IProcessor(_processor);
        router = Router(_router);
        priceFeed = IPriceFeed(_priceFeed);
    }

    /**
     * ========================= Replace Contracts =========================
     */
    function updatePriceFeeds(IMarket market) external onlyModerator {
        if (address(priceFeed) == address(0)) revert GlobalMarketConfig_PriceFeedNotSet();
        market.updatePriceFeed(priceFeed);
        marketMaker.updatePriceFeed(priceFeed);
        processor.updatePriceFeed(priceFeed);
        router.updatePriceFeed(priceFeed);
    }

    /**
     * ========================= Market Config =========================
     */
    function setMarketConfig(IMarket market, IMarket.Config memory _config, bytes32 _assetId) external onlyModerator {
        if (address(market) == address(0)) revert GlobalMarketConfig_MarketDoesNotExist();
        market.updateConfig(_config, _assetId);
    }

    /**
     * ========================= Fees =========================
     */
    function updateLiquidityFees(
        IMarket market,
        address _poolOwner,
        address _feeDistributor,
        uint256 _feeScale,
        uint256 _feePercentageToOwner
    ) external onlyModerator {
        market.updateFees(_poolOwner, _feeDistributor, _feeScale, _feePercentageToOwner);
    }

    function setTradingFees(uint256 _liquidationFee, uint256 _tradingFee) external onlyModerator {
        tradeStorage.setFees(_liquidationFee, _tradingFee);
    }
}
