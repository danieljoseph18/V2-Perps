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

import {LiquidityVault} from "../liquidity/LiquidityVault.sol";
import {TradeStorage} from "../positions/TradeStorage.sol";
import {RoleValidation} from "../access/RoleValidation.sol";
import {PriceFeed} from "../oracle/PriceFeed.sol";
import {MarketMaker} from "./MarketMaker.sol";
import {Processor} from "../router/Processor.sol";
import {Market, IMarket} from "./Market.sol";
import {Router} from "../router/Router.sol";
import {Processor} from "../router/Processor.sol";
import {Router} from "../router/Router.sol";

/// @dev Needs Configurator Role
contract GlobalMarketConfig is RoleValidation {
    LiquidityVault public liquidityVault;
    TradeStorage public tradeStorage;
    MarketMaker public marketMaker;
    Processor public processor;
    Router public router;
    PriceFeed public priceFeed;

    constructor(
        address payable _liquidityVault,
        address _tradeStorage,
        address _marketMaker,
        address payable _processor,
        address payable _priceFeed,
        address payable _router,
        address _roleStorage
    ) RoleValidation(_roleStorage) {
        liquidityVault = LiquidityVault(_liquidityVault);
        tradeStorage = TradeStorage(_tradeStorage);
        marketMaker = MarketMaker(_marketMaker);
        processor = Processor(_processor);
        router = Router(_router);
        priceFeed = PriceFeed(_priceFeed);
    }

    function setTargetContracts(
        address payable _liquidityVault,
        address _tradeStorage,
        address _marketMaker,
        address payable _processor,
        address payable _router,
        address _priceFeed
    ) external onlyModerator {
        liquidityVault = LiquidityVault(_liquidityVault);
        tradeStorage = TradeStorage(_tradeStorage);
        marketMaker = MarketMaker(_marketMaker);
        processor = Processor(_processor);
        router = Router(_router);
        priceFeed = PriceFeed(_priceFeed);
    }

    /**
     * ========================= Replace Contracts =========================
     */
    function updatePriceFeeds() external onlyModerator {
        require(address(priceFeed) != address(0), "PriceFeed not set");
        liquidityVault.updatePriceFeed(priceFeed);
        tradeStorage.updatePriceFeed(priceFeed);
        marketMaker.updatePriceFeed(priceFeed);
        processor.updatePriceFeed(priceFeed);
        router.updatePriceFeed(priceFeed);
    }

    /**
     * ========================= Market Config =========================
     */
    function setMarketConfig(IMarket market, IMarket.Config memory _config) external onlyModerator {
        require(address(market) != address(0), "Market does not exist");
        market.updateConfig(_config);
    }

    /**
     * ========================= Fees =========================
     */
    function updateLiquidityFees(uint256 _minExecutionFee, uint256 _feeScale) external onlyModerator {
        liquidityVault.updateFees(_minExecutionFee, _feeScale);
    }

    function setTradingFees(uint256 _liquidationFee, uint256 _tradingFee) external onlyModerator {
        tradeStorage.setFees(_liquidationFee, _tradingFee);
    }
}
