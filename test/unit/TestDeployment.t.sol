// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {Test, console} from "forge-std/Test.sol";
import {DeployV2} from "../../script/DeployV2.s.sol";
import {RoleStorage} from "../../src/access/RoleStorage.sol";
import {GlobalMarketConfig} from "../../src/markets/GlobalMarketConfig.sol";
import {LiquidityVault} from "../../src/markets/LiquidityVault.sol";
import {MarketMaker} from "../../src/markets/MarketMaker.sol";
import {MarketToken} from "../../src/markets/MarketToken.sol";
import {StateUpdater} from "../../src/markets/StateUpdater.sol";
import {IMockPriceOracle} from "../mocks/interfaces/IMockPriceOracle.sol";
import {IMockUSDC} from "../mocks/interfaces/IMockUSDC.sol";
import {DataOracle} from "../../src/oracle/DataOracle.sol";
import {Executor} from "../../src/positions/Executor.sol";
import {Liquidator} from "../../src/positions/Liquidator.sol";
import {RequestRouter} from "../../src/positions/RequestRouter.sol";
import {TradeStorage} from "../../src/positions/TradeStorage.sol";
import {TradeVault} from "../../src/positions/TradeVault.sol";
import {USDE} from "../../src/token/USDE.sol";

contract TestDeployment is Test {
    RoleStorage roleStorage;
    GlobalMarketConfig globalMarketConfig;
    LiquidityVault liquidityVault;
    MarketMaker marketMaker;
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
    USDE usde;

    address public OWNER;

    function setUp() public {
        DeployV2 deploy = new DeployV2();
        DeployV2.Contracts memory contracts = deploy.run();
        roleStorage = contracts.roleStorage;
        globalMarketConfig = contracts.globalMarketConfig;
        liquidityVault = contracts.liquidityVault;
        marketMaker = contracts.marketMaker;
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
        usde = contracts.usde;
        OWNER = contracts.owner;
    }

    function testDeployment() public view {
        console.log(address(roleStorage));
        console.log(address(globalMarketConfig));
        console.log(address(liquidityVault));
        console.log(address(marketMaker));
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
        console.log(address(usde));
        console.log(OWNER);
    }
}
