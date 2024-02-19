// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {Script} from "forge-std/Script.sol";
import {HelperConfig} from "./HelperConfig.s.sol";
import {RoleStorage} from "../src/access/RoleStorage.sol";
import {GlobalMarketConfig} from "../src/markets/GlobalMarketConfig.sol";
import {LiquidityVault} from "../src/liquidity/LiquidityVault.sol";
import {MarketMaker} from "../src/markets/MarketMaker.sol";
import {StateUpdater} from "../src/markets/StateUpdater.sol";
import {IPriceFeed} from "../src/oracle/interfaces/IPriceFeed.sol";
import {TradeStorage} from "../src/positions/TradeStorage.sol";
import {ReferralStorage} from "../src/referrals/ReferralStorage.sol";
import {Processor} from "../src/router/Processor.sol";
import {Router} from "../src/router/Router.sol";
import {IMarket} from "../src/markets/interfaces/IMarket.sol";
import {Roles} from "../src/access/Roles.sol";
import {Oracle} from "../src/oracle/Oracle.sol";

contract Deploy is Script {
    HelperConfig public helperConfig;

    struct Contracts {
        RoleStorage roleStorage;
        GlobalMarketConfig globalMarketConfig;
        LiquidityVault liquidityVault;
        MarketMaker marketMaker;
        StateUpdater stateUpdater;
        IPriceFeed priceFeed; // Deployed in Helper Config
        TradeStorage tradeStorage;
        ReferralStorage referralStorage;
        Processor processor;
        Router router;
        address owner;
    }

    address public usdc;
    address public weth;
    bytes32 public ethPriceId;
    bytes32 public usdcPriceId;

    function run() external returns (Contracts memory contracts) {
        helperConfig = new HelperConfig();
        IPriceFeed priceFeed;
        (priceFeed, weth, usdc, ethPriceId, usdcPriceId) = helperConfig.activeNetworkConfig();

        vm.startBroadcast();

        contracts = Contracts(
            RoleStorage(address(0)),
            GlobalMarketConfig(address(0)),
            LiquidityVault(payable(address(0))),
            MarketMaker(address(0)),
            StateUpdater(address(0)),
            priceFeed,
            TradeStorage(address(0)),
            ReferralStorage(address(0)),
            Processor(payable(address(0))),
            Router(payable(address(0))),
            msg.sender
        );

        /**
         * ============ Deploy Contracts ============
         */
        contracts.roleStorage = new RoleStorage();

        contracts.liquidityVault =
            new LiquidityVault(weth, usdc, 1e18, 1e6, "BRRR-LP", "BRRR", address(contracts.roleStorage));

        contracts.marketMaker = new MarketMaker(address(contracts.roleStorage));

        contracts.tradeStorage = new TradeStorage(
            address(contracts.liquidityVault), address(contracts.priceFeed), address(contracts.roleStorage)
        );

        contracts.stateUpdater = new StateUpdater(address(contracts.roleStorage));

        contracts.referralStorage = new ReferralStorage(weth, usdc, address(contracts.roleStorage));

        contracts.globalMarketConfig = new GlobalMarketConfig(
            address(contracts.liquidityVault), address(contracts.tradeStorage), address(contracts.roleStorage)
        );

        contracts.processor = new Processor(
            address(contracts.marketMaker),
            address(contracts.tradeStorage),
            address(contracts.liquidityVault),
            address(contracts.referralStorage),
            address(contracts.priceFeed),
            address(contracts.roleStorage)
        );

        contracts.router = new Router(
            address(contracts.tradeStorage),
            address(contracts.liquidityVault),
            address(contracts.marketMaker),
            address(contracts.priceFeed),
            usdc,
            weth,
            address(contracts.processor),
            address(contracts.roleStorage)
        );

        /**
         * ============ Set Up Contracts ============
         */
        contracts.liquidityVault.initialise(
            address(contracts.priceFeed), address(contracts.processor), 1 minutes, 180000 gwei, 0.03e18
        );

        IMarket.Config memory defaultMarketConfig = IMarket.Config({
            maxLeverage: 10000, // 100x
            feeForSmallerSide: true,
            reserveFactor: 0.3e18,
            funding: IMarket.FundingConfig({
                maxVelocity: 0.0003e18, // 0.03%
                maxRate: 0.03e18, // 3%
                minRate: -0.03e18, // -3%
                skewScale: 1_000_000e18 // 1 Mil USD
            }),
            borrowing: IMarket.BorrowingConfig({
                factor: 0.000000035e18, // 0.0000035% per second
                exponent: 1
            }),
            impact: IMarket.ImpactConfig({positiveFactor: 0.000001e18, negativeFactor: 0.000002e18, exponent: 2}),
            adl: IMarket.AdlConfig({maxPnlFactor: 0.4e18, targetPnlFactor: 0.2e18, flaggedLong: false, flaggedShort: false})
        });
        contracts.marketMaker.initialise(
            defaultMarketConfig, address(contracts.priceFeed), address(contracts.liquidityVault)
        );

        contracts.tradeStorage.initialise(5e18, 0.001e18, 180000 gwei, 2e18);

        contracts.processor.updateGasLimits(180000 gwei, 180000 gwei, 180000 gwei, 180000 gwei);

        // Set Up Roles
        contracts.roleStorage.grantRole(Roles.VAULT, address(contracts.liquidityVault));
        contracts.roleStorage.grantRole(Roles.CONFIGURATOR, address(contracts.globalMarketConfig));
        contracts.roleStorage.grantRole(Roles.MARKET_MAKER, address(contracts.marketMaker));
        contracts.roleStorage.grantRole(Roles.STATE_UPDATER, address(contracts.stateUpdater));
        contracts.roleStorage.grantRole(Roles.PROCESSOR, address(contracts.processor));
        contracts.roleStorage.grantRole(Roles.TRADE_STORAGE, address(contracts.tradeStorage));
        contracts.roleStorage.grantRole(Roles.ROUTER, address(contracts.router));
        contracts.roleStorage.grantRole(Roles.DEFAULT_ADMIN_ROLE, contracts.owner);
        contracts.roleStorage.grantRole(Roles.STATE_KEEPER, contracts.owner);
        contracts.roleStorage.grantRole(Roles.ADL_KEEPER, contracts.owner);
        contracts.roleStorage.grantRole(Roles.KEEPER, contracts.owner);
        contracts.roleStorage.grantRole(Roles.LIQUIDATOR, contracts.owner);
        contracts.roleStorage.grantRole(Roles.FEE_ACCUMULATOR, address(contracts.tradeStorage));
        contracts.roleStorage.grantRole(Roles.FEE_ACCUMULATOR, address(contracts.processor));

        vm.stopBroadcast();

        return contracts;
    }
}
