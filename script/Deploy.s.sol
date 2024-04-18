// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Script} from "forge-std/Script.sol";
import {HelperConfig, IHelperConfig} from "./HelperConfig.s.sol";
import {RoleStorage} from "../src/access/RoleStorage.sol";
import {MarketFactory} from "../src/markets/MarketFactory.sol";
import {PriceFeed, IPriceFeed} from "../src/oracle/PriceFeed.sol";
import {MockPriceFeed} from "../test/mocks/MockPriceFeed.sol";
import {TradeStorage} from "../src/positions/TradeStorage.sol";
import {ReferralStorage} from "../src/referrals/ReferralStorage.sol";
import {PositionManager} from "../src/router/PositionManager.sol";
import {Router} from "../src/router/Router.sol";
import {IMarket} from "../src/markets/interfaces/IMarket.sol";
import {Roles} from "../src/access/Roles.sol";
import {Oracle} from "../src/oracle/Oracle.sol";
import {FeeDistributor} from "../src/rewards/FeeDistributor.sol";
import {TransferStakedTokens} from "../src/rewards/TransferStakedTokens.sol";

contract Deploy is Script {
    IHelperConfig public helperConfig;

    struct Contracts {
        RoleStorage roleStorage;
        MarketFactory marketFactory;
        IPriceFeed priceFeed; // Deployed in Helper Config
        ReferralStorage referralStorage;
        PositionManager positionManager;
        Router router;
        FeeDistributor feeDistributor;
        TransferStakedTokens transferStakedTokens;
        address owner;
    }

    IHelperConfig.NetworkConfig public activeNetworkConfig;

    function run() external returns (Contracts memory contracts) {
        helperConfig = new HelperConfig();
        IPriceFeed priceFeed;
        {
            (activeNetworkConfig) = helperConfig.getActiveNetworkConfig();
        }

        vm.startBroadcast();

        contracts = Contracts(
            RoleStorage(address(0)),
            MarketFactory(address(0)),
            priceFeed,
            ReferralStorage(payable(address(0))),
            PositionManager(payable(address(0))),
            Router(payable(address(0))),
            FeeDistributor(address(0)),
            TransferStakedTokens(address(0)),
            msg.sender
        );

        /**
         * ============ Deploy Contracts ============
         */
        contracts.roleStorage = new RoleStorage();

        contracts.marketFactory =
            new MarketFactory(activeNetworkConfig.weth, activeNetworkConfig.usdc, address(contracts.roleStorage));

        if (activeNetworkConfig.mockFeed) {
            // Deploy a Mock Price Feed contract
            contracts.priceFeed = new MockPriceFeed(
                address(contracts.marketFactory),
                activeNetworkConfig.weth,
                activeNetworkConfig.link,
                activeNetworkConfig.uniV3SwapRouter,
                activeNetworkConfig.uniV3Factory,
                activeNetworkConfig.subId,
                activeNetworkConfig.donId,
                activeNetworkConfig.chainlinkRouter
            );
        } else {
            // Deploy a Price Feed Contract
            contracts.priceFeed = new PriceFeed(
                address(contracts.marketFactory),
                activeNetworkConfig.weth,
                activeNetworkConfig.link,
                activeNetworkConfig.uniV3SwapRouter,
                activeNetworkConfig.uniV3Factory,
                activeNetworkConfig.subId,
                activeNetworkConfig.donId,
                activeNetworkConfig.chainlinkRouter,
                address(contracts.roleStorage)
            );
        }

        contracts.referralStorage = new ReferralStorage(
            activeNetworkConfig.weth, activeNetworkConfig.usdc, activeNetworkConfig.weth, address(contracts.roleStorage)
        );

        contracts.positionManager = new PositionManager(
            address(contracts.marketFactory),
            address(contracts.referralStorage),
            address(contracts.priceFeed),
            activeNetworkConfig.weth,
            activeNetworkConfig.usdc,
            address(contracts.roleStorage)
        );

        contracts.router = new Router(
            address(contracts.marketFactory),
            address(contracts.priceFeed),
            activeNetworkConfig.usdc,
            activeNetworkConfig.weth,
            address(contracts.positionManager),
            address(contracts.roleStorage)
        );

        contracts.feeDistributor = new FeeDistributor(
            address(contracts.marketFactory),
            activeNetworkConfig.weth,
            activeNetworkConfig.usdc,
            address(contracts.roleStorage)
        );

        contracts.transferStakedTokens = new TransferStakedTokens();

        /**
         * ============ Set Up Contracts ============
         */
        IMarket.Config memory defaultMarketConfig = IMarket.Config({
            maxLeverage: 10000, // 100x
            reserveFactor: 0.2e18,
            maintenanceMargin: 0.005e18, // 0.5%
            // Skew Scale = Skew for Max Velocity
            funding: IMarket.FundingConfig({
                maxVelocity: 0.09e18, // 9% per day
                skewScale: 1_000_000e30 // 1 Mil USD
            }),
            // Should never be 0
            // All are percentages between 1 (1e-30) and 1e30 (100%)
            impact: IMarket.ImpactConfig({
                positiveSkewScalar: 1e30,
                negativeSkewScalar: 1e30,
                positiveLiquidityScalar: 1e30,
                negativeLiquidityScalar: 1e30
            })
        });

        contracts.marketFactory.initialize(
            defaultMarketConfig,
            address(contracts.priceFeed),
            address(contracts.referralStorage),
            address(contracts.positionManager),
            address(contracts.feeDistributor),
            msg.sender,
            0.01 ether,
            0.005 ether
        );

        contracts.positionManager.updateGasEstimates(180000 gwei, 180000 gwei, 180000 gwei, 180000 gwei);

        contracts.referralStorage.setTier(0, 0.05e18);
        contracts.referralStorage.setTier(1, 0.1e18);
        contracts.referralStorage.setTier(2, 0.15e18);

        // Set Up Roles
        contracts.roleStorage.grantRole(Roles.MARKET_FACTORY, address(contracts.marketFactory));
        contracts.roleStorage.grantRole(Roles.POSITION_MANAGER, address(contracts.positionManager));
        contracts.roleStorage.grantRole(Roles.ROUTER, address(contracts.router));
        contracts.roleStorage.grantRole(Roles.DEFAULT_ADMIN_ROLE, contracts.owner);

        vm.stopBroadcast();

        return contracts;
    }
}
