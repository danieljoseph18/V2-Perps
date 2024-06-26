// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Script} from "forge-std/Script.sol";
import {HelperConfig, IHelperConfig} from "./HelperConfig.s.sol";
import {MarketFactory} from "../src/factory/MarketFactory.sol";
import {PriceFeed, IPriceFeed} from "../src/oracle/PriceFeed.sol";
import {MockPriceFeed} from "../test/mocks/MockPriceFeed.sol";
import {TradeStorage} from "../src/positions/TradeStorage.sol";
import {ReferralStorage} from "../src/referrals/ReferralStorage.sol";
import {PositionManager} from "../src/router/PositionManager.sol";
import {Router} from "../src/router/Router.sol";
import {IMarket} from "../src/markets/interfaces/IMarket.sol";
import {Oracle} from "../src/oracle/Oracle.sol";
import {FeeDistributor} from "../src/rewards/FeeDistributor.sol";
import {GlobalRewardTracker} from "../src/rewards/GlobalRewardTracker.sol";
import {Pool} from "../src/markets/Pool.sol";
import {OwnableRoles} from "../src/auth/OwnableRoles.sol";
import {TradeEngine} from "../src/positions/TradeEngine.sol";
import {Market} from "../src/markets/Market.sol";

contract Deploy is Script {
    IHelperConfig public helperConfig;

    struct Contracts {
        MarketFactory marketFactory;
        Market market;
        TradeStorage tradeStorage;
        TradeEngine tradeEngine;
        IPriceFeed priceFeed; // Deployed in Helper Config
        ReferralStorage referralStorage;
        PositionManager positionManager;
        Router router;
        FeeDistributor feeDistributor;
        GlobalRewardTracker rewardTracker;
        address owner;
    }

    IHelperConfig.NetworkConfig public activeNetworkConfig;

    uint256 internal constant _ROLE_0 = 1 << 0;
    uint256 internal constant _ROLE_1 = 1 << 1;
    uint256 internal constant _ROLE_2 = 1 << 2;
    uint256 internal constant _ROLE_3 = 1 << 3;
    uint256 internal constant _ROLE_4 = 1 << 4;
    uint256 internal constant _ROLE_5 = 1 << 5;
    uint256 internal constant _ROLE_6 = 1 << 6;

    function run() external returns (Contracts memory contracts) {
        helperConfig = new HelperConfig();
        IPriceFeed priceFeed;
        {
            (activeNetworkConfig) = helperConfig.getActiveNetworkConfig();
        }

        vm.startBroadcast();

        contracts = Contracts(
            MarketFactory(address(0)),
            Market(address(0)),
            TradeStorage(address(0)),
            TradeEngine(address(0)),
            priceFeed,
            ReferralStorage(payable(address(0))),
            PositionManager(payable(address(0))),
            Router(payable(address(0))),
            FeeDistributor(address(0)),
            GlobalRewardTracker(address(0)),
            msg.sender
        );

        /**
         * ============ Deploy Contracts ============
         */
        contracts.marketFactory = new MarketFactory(activeNetworkConfig.weth, activeNetworkConfig.usdc);

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
                activeNetworkConfig.chainlinkRouter
            );
        }

        contracts.market = new Market(activeNetworkConfig.weth, activeNetworkConfig.usdc);

        contracts.referralStorage =
            new ReferralStorage(activeNetworkConfig.weth, activeNetworkConfig.usdc, address(contracts.marketFactory));

        contracts.tradeStorage = new TradeStorage(
            address(contracts.market), address(contracts.referralStorage), address(contracts.priceFeed)
        );

        contracts.tradeEngine = new TradeEngine(address(contracts.tradeStorage), address(contracts.market));

        contracts.rewardTracker =
            new GlobalRewardTracker(activeNetworkConfig.weth, activeNetworkConfig.usdc, "Staked BRRR", "sBRRR");

        contracts.positionManager = new PositionManager(
            address(contracts.marketFactory),
            address(contracts.market),
            address(contracts.rewardTracker),
            address(contracts.referralStorage),
            address(contracts.priceFeed),
            address(contracts.tradeEngine),
            activeNetworkConfig.weth,
            activeNetworkConfig.usdc
        );

        contracts.router = new Router(
            address(contracts.marketFactory),
            address(contracts.market),
            address(contracts.priceFeed),
            activeNetworkConfig.usdc,
            activeNetworkConfig.weth,
            address(contracts.positionManager),
            address(contracts.rewardTracker)
        );

        contracts.feeDistributor = new FeeDistributor(
            address(contracts.marketFactory),
            address(contracts.rewardTracker),
            activeNetworkConfig.weth,
            activeNetworkConfig.usdc
        );

        /**
         * ============ Set Up Contracts ============
         */
        Pool.Config memory defaultMarketConfig = Pool.Config({
            maxLeverage: 100, // 100x
            maintenanceMargin: 50, // 0.5%
            reserveFactor: 2000, // 20%
            // Skew Scale = Skew for Max Velocity
            maxFundingVelocity: 900, // 9% per day
            skewScale: 1_000_000, // 1 Mil USD
            // Should never be 0
            // Percentages up to 100% (10000)
            positiveLiquidityScalar: 10000,
            negativeLiquidityScalar: 10000
        });

        contracts.marketFactory.initialize(
            defaultMarketConfig,
            address(contracts.market),
            address(contracts.tradeStorage),
            address(contracts.tradeEngine),
            address(contracts.priceFeed),
            address(contracts.referralStorage),
            address(contracts.positionManager),
            address(contracts.router),
            address(contracts.feeDistributor),
            msg.sender,
            0.01 ether,
            0.005 ether
        );

        contracts.marketFactory.setRewardTracker(address(contracts.rewardTracker));

        // @audit - dummy values
        contracts.priceFeed.initialize(
            0.0001 gwei, 300_000, 0.0001 gwei, 0.0001 gwei, address(0), address(0), 30 seconds
        );

        contracts.market.initialize(
            address(contracts.tradeStorage), address(contracts.priceFeed), address(contracts.marketFactory)
        );
        contracts.market.grantRoles(address(contracts.positionManager), _ROLE_1);
        contracts.market.grantRoles(address(contracts.router), _ROLE_3);
        contracts.market.grantRoles(address(contracts.tradeEngine), _ROLE_6);

        contracts.tradeStorage.initialize(address(contracts.tradeEngine), address(contracts.marketFactory));
        contracts.tradeStorage.grantRoles(address(contracts.positionManager), _ROLE_1);
        contracts.tradeStorage.grantRoles(address(contracts.router), _ROLE_3);

        contracts.tradeEngine.initialize(
            address(contracts.priceFeed),
            address(contracts.referralStorage),
            address(contracts.positionManager),
            2e30,
            0.05e18,
            0.1e18,
            0.001e18,
            0.1e18
        );
        contracts.tradeEngine.grantRoles(address(contracts.tradeStorage), _ROLE_4);

        contracts.positionManager.updateGasEstimates(180000 gwei, 180000 gwei, 180000 gwei, 180000 gwei);

        contracts.referralStorage.setTier(0, 0.05e18);
        contracts.referralStorage.setTier(1, 0.1e18);
        contracts.referralStorage.setTier(2, 0.15e18);
        contracts.referralStorage.grantRoles(address(contracts.tradeEngine), _ROLE_6);

        contracts.rewardTracker.grantRoles(address(contracts.marketFactory), _ROLE_0);
        contracts.rewardTracker.initialize(address(contracts.feeDistributor));
        contracts.rewardTracker.setHandler(address(contracts.positionManager), true);
        contracts.rewardTracker.setHandler(address(contracts.router), true);

        contracts.feeDistributor.grantRoles(address(contracts.marketFactory), _ROLE_0);

        // Transfer ownership to caller --> for testing
        contracts.marketFactory.transferOwnership(msg.sender);
        if (!activeNetworkConfig.mockFeed) OwnableRoles(address(contracts.priceFeed)).transferOwnership(msg.sender);
        contracts.referralStorage.transferOwnership(msg.sender);
        contracts.positionManager.transferOwnership(msg.sender);
        contracts.router.transferOwnership(msg.sender);
        contracts.feeDistributor.transferOwnership(msg.sender);
        contracts.rewardTracker.transferOwnership(msg.sender);

        vm.stopBroadcast();

        return contracts;
    }
}
