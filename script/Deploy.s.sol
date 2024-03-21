// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Script} from "forge-std/Script.sol";
import {HelperConfig} from "./HelperConfig.s.sol";
import {RoleStorage} from "../src/access/RoleStorage.sol";
import {Vault} from "../src/markets/Vault.sol";
import {MarketMaker} from "../src/markets/MarketMaker.sol";
import {IPriceFeed} from "../src/oracle/interfaces/IPriceFeed.sol";
import {TradeStorage} from "../src/positions/TradeStorage.sol";
import {ReferralStorage} from "../src/referrals/ReferralStorage.sol";
import {PositionManager} from "../src/router/PositionManager.sol";
import {Router} from "../src/router/Router.sol";
import {IMarket} from "../src/markets/interfaces/IMarket.sol";
import {Roles} from "../src/access/Roles.sol";
import {Oracle} from "../src/oracle/Oracle.sol";

contract Deploy is Script {
    HelperConfig public helperConfig;

    struct Contracts {
        RoleStorage roleStorage;
        MarketMaker marketMaker;
        IPriceFeed priceFeed; // Deployed in Helper Config
        ReferralStorage referralStorage;
        PositionManager positionManager;
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
            MarketMaker(address(0)),
            priceFeed,
            ReferralStorage(payable(address(0))),
            PositionManager(payable(address(0))),
            Router(payable(address(0))),
            msg.sender
        );

        /**
         * ============ Deploy Contracts ============
         */
        contracts.roleStorage = new RoleStorage();

        contracts.marketMaker = new MarketMaker(address(contracts.roleStorage));

        contracts.referralStorage = new ReferralStorage(weth, usdc, weth, address(contracts.roleStorage));

        contracts.positionManager = new PositionManager(
            address(contracts.marketMaker),
            address(contracts.referralStorage),
            address(contracts.priceFeed),
            weth,
            usdc,
            address(contracts.roleStorage)
        );

        contracts.router = new Router(
            address(contracts.marketMaker),
            address(contracts.priceFeed),
            usdc,
            weth,
            address(contracts.positionManager),
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
        contracts.marketMaker.initialize(
            defaultMarketConfig, address(contracts.priceFeed), address(contracts.referralStorage)
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

        vm.stopBroadcast();

        return contracts;
    }
}
