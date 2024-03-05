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

import {IVault} from "./interfaces/IVault.sol";
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
    function updatePriceFeeds(IVault vault) external onlyModerator {
        require(address(priceFeed) != address(0), "PriceFeed not set");
        vault.updatePriceFeed(priceFeed);
        marketMaker.updatePriceFeed(priceFeed);
        processor.updatePriceFeed(priceFeed);
        router.updatePriceFeed(priceFeed);
    }

    /**
     * ========================= Market Config =========================
     */
    function setMarketConfig(IMarket market, IMarket.Config memory _config, address _indexToken)
        external
        onlyModerator
    {
        require(address(market) != address(0), "Market does not exist");
        market.updateConfig(_config, _indexToken);
    }

    /**
     * ========================= Fees =========================
     */
    function updateLiquidityFees(
        IVault vault,
        address _poolOwner,
        address _feeDistributor,
        uint256 _feeScale,
        uint256 _feePercentageToOwner
    ) external onlyModerator {
        vault.updateFees(_poolOwner, _feeDistributor, _feeScale, _feePercentageToOwner);
    }

    function setTradingFees(uint256 _liquidationFee, uint256 _tradingFee) external onlyModerator {
        tradeStorage.setFees(_liquidationFee, _tradingFee);
    }
}
