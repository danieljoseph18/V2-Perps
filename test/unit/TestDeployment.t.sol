// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.22;

import {Test, console} from "forge-std/Test.sol";
import {DeployV2} from "../../script/DeployV2.s.sol";
import {RoleStorage} from "../../src/access/RoleStorage.sol";
import {GlobalMarketConfig} from "../../src/markets/GlobalMarketConfig.sol";
import {LiquidityVault} from "../../src/markets/LiquidityVault.sol";
import {MarketFactory} from "../../src/markets/MarketFactory.sol";
import {MarketStorage} from "../../src/markets/MarketStorage.sol";
import {MarketToken} from "../../src/markets/MarketToken.sol";
import {StateUpdater} from "../../src/markets/StateUpdater.sol";
import {IMockPriceOracle} from "../../src/mocks/interfaces/IMockPriceOracle.sol";
import {IMockUSDC} from "../../src/mocks/interfaces/IMockUSDC.sol";
import {DataOracle} from "../../src/oracle/DataOracle.sol";
import {Executor} from "../../src/positions/Executor.sol";
import {Liquidator} from "../../src/positions/Liquidator.sol";
import {RequestRouter} from "../../src/positions/RequestRouter.sol";
import {TradeStorage} from "../../src/positions/TradeStorage.sol";
import {TradeVault} from "../../src/positions/TradeVault.sol";
import {WUSDC} from "../../src/token/WUSDC.sol";

contract TestDeployment is Test {
    RoleStorage roleStorage;
    GlobalMarketConfig globalMarketConfig;
    LiquidityVault liquidityVault;
    MarketFactory marketFactory;
    MarketStorage marketStorage;
    MarketToken marketToken;
    StateUpdater stateUpdater;
    IMockPriceOracle priceOracle;
    IMockUSDC usdc;
    DataOracle dataOracle;
    Executor executor;
    Liquidator liquidator;
    RequestRouter requestRouter;
    TradeStorage tradeStorage;
    TradeVault tradeVault;
    WUSDC wusdc;

    address public OWNER;

    function setUp() public {
        DeployV2 deploy = new DeployV2();
        DeployV2.Contracts memory contracts = deploy.run();
        roleStorage = contracts.roleStorage;
        globalMarketConfig = contracts.globalMarketConfig;
        liquidityVault = contracts.liquidityVault;
        marketFactory = contracts.marketFactory;
        marketStorage = contracts.marketStorage;
        marketToken = contracts.marketToken;
        stateUpdater = contracts.stateUpdater;
        priceOracle = contracts.priceOracle;
        usdc = contracts.usdc;
        dataOracle = contracts.dataOracle;
        executor = contracts.executor;
        liquidator = contracts.liquidator;
        requestRouter = contracts.requestRouter;
        tradeStorage = contracts.tradeStorage;
        tradeVault = contracts.tradeVault;
        wusdc = contracts.wusdc;
        OWNER = contracts.owner;
    }

    function testDeployment() public view {
        console.log(address(roleStorage));
        console.log(address(globalMarketConfig));
        console.log(address(liquidityVault));
        console.log(address(marketFactory));
        console.log(address(marketStorage));
        console.log(address(marketToken));
        console.log(address(stateUpdater));
        console.log(address(priceOracle));
        console.log(address(usdc));
        console.log(address(dataOracle));
        console.log(address(executor));
        console.log(address(liquidator));
        console.log(address(requestRouter));
        console.log(address(tradeStorage));
        console.log(address(tradeVault));
        console.log(address(wusdc));
        console.log(OWNER);
    }
}
