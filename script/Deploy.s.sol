// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Script} from "forge-std/Script.sol";
import {HelperConfig, IHelperConfig} from "./HelperConfig.s.sol";
import {RoleStorage} from "../src/access/RoleStorage.sol";
import {MarketMaker} from "../src/markets/MarketMaker.sol";
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

contract Deploy is Script {
    IHelperConfig public helperConfig;

    struct Contracts {
        RoleStorage roleStorage;
        MarketMaker marketMaker;
        IPriceFeed priceFeed; // Deployed in Helper Config
        ReferralStorage referralStorage;
        PositionManager positionManager;
        Router router;
        FeeDistributor feeDistributor;
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
            MarketMaker(address(0)),
            priceFeed,
            ReferralStorage(payable(address(0))),
            PositionManager(payable(address(0))),
            Router(payable(address(0))),
            FeeDistributor(address(0)),
            msg.sender
        );

        /**
         * ============ Deploy Contracts ============
         */
        contracts.roleStorage = new RoleStorage();

        if (activeNetworkConfig.mockFeed) {
            contracts.priceFeed = new MockPriceFeed(
                10,
                1,
                keccak256(abi.encode("ETH")),
                keccak256(abi.encode("USDC")),
                activeNetworkConfig.wethAsset,
                activeNetworkConfig.usdcAsset
            );
        } else {
            contracts.priceFeed = new PriceFeed(
                0xDd24F84d36BF92C65F92307595335bdFab5Bbd21,
                keccak256(abi.encode("ETH")),
                keccak256(abi.encode("USDC")),
                activeNetworkConfig.wethAsset,
                activeNetworkConfig.usdcAsset,
                activeNetworkConfig.sequencerUptimeFeed,
                address(contracts.roleStorage)
            );
        }

        contracts.marketMaker =
            new MarketMaker(activeNetworkConfig.weth, activeNetworkConfig.usdc, address(contracts.roleStorage));

        contracts.referralStorage = new ReferralStorage(
            activeNetworkConfig.weth, activeNetworkConfig.usdc, activeNetworkConfig.weth, address(contracts.roleStorage)
        );

        contracts.positionManager = new PositionManager(
            address(contracts.marketMaker),
            address(contracts.referralStorage),
            address(contracts.priceFeed),
            activeNetworkConfig.weth,
            activeNetworkConfig.usdc,
            address(contracts.roleStorage)
        );

        contracts.router = new Router(
            address(contracts.marketMaker),
            address(contracts.priceFeed),
            activeNetworkConfig.usdc,
            activeNetworkConfig.weth,
            address(contracts.positionManager),
            address(contracts.roleStorage)
        );

        contracts.feeDistributor = new FeeDistributor();

        /**
         * ============ Set Up Contracts ============
         */
        IMarket.Config memory defaultMarketConfig = IMarket.Config({
            maxLeverage: 10000, // 100x
            reserveFactor: 0.2e18,
            // Skew Scale = Skew for Max Velocity
            funding: IMarket.FundingConfig({
                maxVelocity: 0.09e18, // 9% per day
                skewScale: 1_000_000e30, // 1 Mil USD
                fundingVelocityClamp: 0.00001e18 // 0.001% per day
            }),
            // Should never be 0
            // All are percentages between 1 (1e-30) and 1e30 (100%)
            impact: IMarket.ImpactConfig({
                positiveSkewScalar: 1e30,
                negativeSkewScalar: 1e30,
                positiveLiquidityScalar: 1e30,
                negativeLiquidityScalar: 1e30
            }),
            adl: IMarket.AdlConfig({maxPnlFactor: 0.4e18, targetPnlFactor: 0.2e18})
        });

        contracts.marketMaker.initialize(
            defaultMarketConfig,
            address(contracts.priceFeed),
            address(contracts.referralStorage),
            address(contracts.positionManager),
            address(contracts.feeDistributor),
            msg.sender,
            0.01 ether
        );

        contracts.positionManager.updateGasEstimates(180000 gwei, 180000 gwei, 180000 gwei, 180000 gwei);

        contracts.referralStorage.setTier(0, 0.05e18);
        contracts.referralStorage.setTier(1, 0.1e18);
        contracts.referralStorage.setTier(2, 0.15e18);

        // Set Up Roles
        contracts.roleStorage.grantRole(Roles.MARKET_MAKER, address(contracts.marketMaker));
        contracts.roleStorage.grantRole(Roles.POSITION_MANAGER, address(contracts.positionManager));
        contracts.roleStorage.grantRole(Roles.ROUTER, address(contracts.router));
        contracts.roleStorage.grantRole(Roles.DEFAULT_ADMIN_ROLE, contracts.owner);
        contracts.roleStorage.grantRole(Roles.STATE_KEEPER, contracts.owner);
        contracts.roleStorage.grantRole(Roles.ADL_KEEPER, contracts.owner);
        contracts.roleStorage.grantRole(Roles.KEEPER, contracts.owner);
        contracts.roleStorage.grantRole(Roles.LIQUIDATOR, contracts.owner);
        contracts.roleStorage.grantRole(Roles.MARKET_KEEPER, contracts.owner);

        vm.stopBroadcast();

        return contracts;
    }
}
