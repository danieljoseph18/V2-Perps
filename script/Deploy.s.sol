// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Script} from "forge-std/Script.sol";
import {HelperConfig} from "./HelperConfig.s.sol";
import {RoleStorage} from "../src/access/RoleStorage.sol";
import {GlobalMarketConfig} from "../src/markets/GlobalMarketConfig.sol";
import {Vault} from "../src/markets/Vault.sol";
import {MarketMaker} from "../src/markets/MarketMaker.sol";
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
        MarketMaker marketMaker;
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
            MarketMaker(address(0)),
            priceFeed,
            TradeStorage(address(0)),
            ReferralStorage(payable(address(0))),
            Processor(payable(address(0))),
            Router(payable(address(0))),
            msg.sender
        );

        /**
         * ============ Deploy Contracts ============
         */
        contracts.roleStorage = new RoleStorage();

        contracts.marketMaker = new MarketMaker(address(contracts.roleStorage));

        contracts.referralStorage = new ReferralStorage(weth, usdc, weth, address(contracts.roleStorage));

        contracts.tradeStorage = new TradeStorage(contracts.referralStorage, address(contracts.roleStorage));

        contracts.processor = new Processor(
            address(contracts.marketMaker),
            address(contracts.tradeStorage),
            address(contracts.referralStorage),
            address(contracts.priceFeed),
            weth,
            usdc,
            address(contracts.roleStorage)
        );

        contracts.router = new Router(
            address(contracts.tradeStorage),
            address(contracts.marketMaker),
            address(contracts.priceFeed),
            usdc,
            weth,
            address(contracts.processor),
            address(contracts.roleStorage)
        );

        contracts.globalMarketConfig = new GlobalMarketConfig(
            address(contracts.tradeStorage),
            address(contracts.marketMaker),
            payable(address(contracts.processor)),
            payable(address(contracts.router)),
            payable(address(contracts.priceFeed)),
            address(contracts.roleStorage)
        );

        /**
         * ============ Set Up Contracts ============
         */
        IMarket.Config memory defaultMarketConfig = IMarket.Config({
            maxLeverage: 10000, // 100x
            reserveFactor: 0.3e18,
            // Skew Scale = Skew for Max Velocity
            funding: IMarket.FundingConfig({
                maxVelocity: 0.09e18, // 9% per day
                skewScale: 1_000_000e30, // 1 Mil USD
                fundingVelocityClamp: 0.00001e18 // 0.001% per day
            }),
            borrowing: IMarket.BorrowingConfig({
                factor: 0.000000035e18, // 0.0000035% per second
                exponent: 1
            }),
            // Should never be 0
            impact: IMarket.ImpactConfig({
                positiveSkewScalar: 1e18,
                negativeSkewScalar: 1e18,
                positiveLiquidityScalar: 1e18,
                negativeLiquidityScalar: 1e18
            }),
            adl: IMarket.AdlConfig({maxPnlFactor: 0.4e18, targetPnlFactor: 0.2e18, flaggedLong: false, flaggedShort: false})
        });
        contracts.marketMaker.initialise(
            defaultMarketConfig, address(contracts.priceFeed), address(contracts.processor)
        );

        contracts.tradeStorage.initialise(5e30, 0.001e18, 180000 gwei, 2e30, 10);

        contracts.processor.updateGasLimits(180000 gwei, 180000 gwei, 180000 gwei, 180000 gwei);

        contracts.referralStorage.setTier(0, 0.05e18);
        contracts.referralStorage.setTier(1, 0.1e18);
        contracts.referralStorage.setTier(2, 0.15e18);

        // Set Up Roles
        contracts.roleStorage.grantRole(Roles.CONFIGURATOR, address(contracts.globalMarketConfig));
        contracts.roleStorage.grantRole(Roles.MARKET_MAKER, address(contracts.marketMaker));
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
