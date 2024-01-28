// // SPDX-License-Identifier: BUSL-1.1
// pragma solidity 0.8.23;

// import {Script} from "forge-std/Script.sol";
// import {HelperConfig} from "./HelperConfig.s.sol";
// import {RoleStorage} from "../src/access/RoleStorage.sol";
// import {GlobalMarketConfig} from "../src/markets/GlobalMarketConfig.sol";
// import {LiquidityVault} from "../src/markets/LiquidityVault.sol";
// import {MarketMaker} from "../src/markets/MarketMaker.sol";
// import {MarketToken} from "../src/markets/MarketToken.sol";
// import {StateUpdater} from "../src/markets/StateUpdater.sol";
// import {IMockPriceOracle} from "../test/mocks/interfaces/IMockPriceOracle.sol";
// import {IMockUSDC} from "../test/mocks/interfaces/IMockUSDC.sol";
// import {DataOracle} from "../src/oracle/DataOracle.sol";
// import {Executor} from "../src/positions/Executor.sol";
// import {Liquidator} from "../src/positions/Liquidator.sol";
// import {RequestRouter} from "../src/positions/RequestRouter.sol";
// import {TradeStorage} from "../src/positions/TradeStorage.sol";
// import {TradeVault} from "../src/positions/TradeVault.sol";
// import {USDE} from "../src/token/USDE.sol";
// import {Roles} from "../src/access/Roles.sol";

// contract DeployV2 is Script {
//     HelperConfig public helperConfig;

//     struct Contracts {
//         RoleStorage roleStorage;
//         GlobalMarketConfig globalMarketConfig;
//         LiquidityVault liquidityVault;
//         MarketMaker marketMaker;
//         MarketToken marketToken;
//         StateUpdater stateUpdater;
//         IMockPriceOracle priceOracle;
//         IMockUSDC usdc;
//         DataOracle dataOracle;
//         Executor executor;
//         Liquidator liquidator;
//         RequestRouter requestRouter;
//         TradeStorage tradeStorage;
//         TradeVault tradeVault;
//         USDE usde;
//         address owner;
//     }

//     address public priceOracle;
//     address public usdc;
//     uint256 public deployerKey;

//     function run() external returns (Contracts memory contracts) {
//         helperConfig = new HelperConfig();

//         (priceOracle, usdc, deployerKey) = helperConfig.activeNetworkConfig();

//         vm.startBroadcast(deployerKey);

//         contracts = Contracts(
//             RoleStorage(address(0)),
//             GlobalMarketConfig(address(0)),
//             LiquidityVault(payable(address(0))),
//             MarketMaker(address(0)),
//             MarketToken(address(0)),
//             StateUpdater(address(0)),
//             IMockPriceOracle(priceOracle),
//             IMockUSDC(usdc),
//             DataOracle(address(0)),
//             Executor(address(0)),
//             Liquidator(address(0)),
//             RequestRouter(address(0)),
//             TradeStorage(address(0)),
//             TradeVault(payable(address(0))),
//             USDE(address(0)),
//             msg.sender
//         );

//         /**
//          * ============ Deploy Contracts ============
//          */
//         contracts.usde = new USDE(usdc);

//         contracts.roleStorage = new RoleStorage();

//         contracts.marketToken = new MarketToken("BRRR-LP", "BRRR-LP", address(contracts.roleStorage));

//         contracts.liquidityVault =
//             new LiquidityVault(address(contracts.usde), address(contracts.marketToken), address(contracts.roleStorage));

//         contracts.marketMaker = new MarketMaker(address(contracts.liquidityVault), address(contracts.roleStorage));

//         contracts.dataOracle = new DataOracle(
//             address(contracts.marketMaker), address(contracts.priceOracle), address(contracts.roleStorage)
//         );

//         contracts.tradeVault =
//             new TradeVault(address(contracts.usde), address(contracts.liquidityVault), address(contracts.roleStorage));

//         contracts.tradeStorage = new TradeStorage(
//             address(contracts.marketMaker),
//             address(contracts.liquidityVault),
//             address(contracts.tradeVault),
//             priceOracle,
//             address(contracts.dataOracle),
//             address(contracts.roleStorage)
//         );

//         contracts.executor = new Executor(
//             address(contracts.marketMaker),
//             address(contracts.tradeStorage),
//             priceOracle,
//             address(contracts.liquidityVault),
//             address(contracts.dataOracle),
//             address(contracts.roleStorage)
//         );

//         contracts.liquidator = new Liquidator(
//             address(contracts.tradeStorage),
//             address(contracts.marketMaker),
//             address(contracts.priceOracle),
//             address(contracts.roleStorage)
//         );

//         contracts.requestRouter = new RequestRouter(
//             address(contracts.tradeStorage),
//             address(contracts.liquidityVault),
//             address(contracts.marketMaker),
//             address(contracts.tradeVault),
//             address(contracts.usde)
//         );

//         contracts.stateUpdater = new StateUpdater(
//             address(contracts.liquidityVault),
//             address(contracts.marketMaker),
//             address(contracts.tradeStorage),
//             address(contracts.roleStorage)
//         );

//         contracts.globalMarketConfig = new GlobalMarketConfig(
//             address(contracts.liquidityVault), address(contracts.tradeStorage), address(contracts.roleStorage)
//         );

//         /**
//          * ============ Set Up Contracts ============
//          */
//         contracts.marketMaker.initialise(address(contracts.dataOracle), address(contracts.priceOracle));
//         contracts.liquidityVault.initialise(address(contracts.dataOracle), address(contracts.priceOracle), 0.0003e18);
//         contracts.tradeStorage.initialise(5e18, 0.001e18, 0.001 ether, 10e18);

//         // Set Up Roles
//         contracts.roleStorage.grantRole(Roles.VAULT, address(contracts.liquidityVault));
//         contracts.roleStorage.grantRole(Roles.CONFIGURATOR, address(contracts.globalMarketConfig));
//         contracts.roleStorage.grantRole(Roles.MARKET_MAKER, address(contracts.marketMaker));
//         contracts.roleStorage.grantRole(Roles.STATE_UPDATER, address(contracts.stateUpdater));
//         contracts.roleStorage.grantRole(Roles.STATE_KEEPER, msg.sender);
//         contracts.roleStorage.grantRole(Roles.EXECUTOR, address(contracts.executor));
//         contracts.roleStorage.grantRole(Roles.LIQUIDATOR, address(contracts.liquidator));
//         contracts.roleStorage.grantRole(Roles.TRADE_STORAGE, address(contracts.tradeStorage));
//         contracts.roleStorage.grantRole(Roles.ROUTER, address(contracts.requestRouter));
//         contracts.roleStorage.grantRole(Roles.DEFAULT_ADMIN_ROLE, contracts.owner);
//         contracts.roleStorage.grantRole(Roles.STATE_KEEPER, contracts.owner);
//         contracts.roleStorage.grantRole(Roles.KEEPER, contracts.owner);
//         contracts.roleStorage.grantRole(Roles.FEE_ACCUMULATOR, address(contracts.tradeStorage));
//         contracts.roleStorage.grantRole(Roles.FEE_ACCUMULATOR, address(contracts.tradeVault));
//         contracts.roleStorage.grantRole(Roles.FEE_ACCUMULATOR, address(contracts.requestRouter));

//         vm.stopBroadcast();

//         return contracts;
//     }
// }
