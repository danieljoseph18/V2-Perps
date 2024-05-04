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

contract Deploy is Script {
    IHelperConfig public helperConfig;

    struct Contracts {
        MarketFactory marketFactory;
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

    function run() external returns (Contracts memory contracts) {
        helperConfig = new HelperConfig();
        IPriceFeed priceFeed;
        {
            (activeNetworkConfig) = helperConfig.getActiveNetworkConfig();
        }

        vm.startBroadcast();

        contracts = Contracts(
            MarketFactory(address(0)),
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

        contracts.referralStorage = new ReferralStorage(
            activeNetworkConfig.weth,
            activeNetworkConfig.usdc,
            activeNetworkConfig.weth,
            address(contracts.marketFactory)
        );

        contracts.rewardTracker =
            new GlobalRewardTracker(activeNetworkConfig.weth, activeNetworkConfig.usdc, "Staked BRRR", "sBRRR");

        contracts.positionManager = new PositionManager(
            address(contracts.marketFactory),
            address(contracts.rewardTracker),
            address(contracts.referralStorage),
            address(contracts.priceFeed),
            activeNetworkConfig.weth,
            activeNetworkConfig.usdc
        );

        contracts.router = new Router(
            address(contracts.marketFactory),
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
            // All are percentages between up to 100% (10000)
            positiveSkewScalar: 10000,
            negativeSkewScalar: 10000,
            positiveLiquidityScalar: 10000,
            negativeLiquidityScalar: 10000
        });

        contracts.marketFactory.initialize(
            defaultMarketConfig,
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

        /**
         * (
         *     uint256 _gasOverhead,
         *     uint32 _callbackGasLimit,
         *     uint256 _premiumFee,
         *     uint64 _settlementFee,
         *     address _nativeLinkPriceFeed,
         *     address _sequencerUptimeFeed,
         *     uint48 _timeToExpiration
         * )
         */
        // @audit - dummy values
        contracts.priceFeed.initialize(
            0.01 gwei, 300_000, 0.0001 ether, 0.0001 ether, address(0), address(0), 20 seconds
        );

        contracts.positionManager.updateGasEstimates(180000 gwei, 180000 gwei, 180000 gwei, 180000 gwei);

        contracts.referralStorage.setTier(0, 0.05e18);
        contracts.referralStorage.setTier(1, 0.1e18);
        contracts.referralStorage.setTier(2, 0.15e18);

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
