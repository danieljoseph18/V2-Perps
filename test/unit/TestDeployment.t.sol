// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {RoleStorage} from "../../src/access/RoleStorage.sol";
import {GlobalMarketConfig} from "../../src/markets/GlobalMarketConfig.sol";
import {Market, IMarket} from "../../../src/markets/Market.sol";
import {MarketMaker} from "../../src/markets/MarketMaker.sol";
import {IPriceFeed} from "../../src/oracle/interfaces/IPriceFeed.sol";
import {TradeStorage} from "../../src/positions/TradeStorage.sol";
import {ReferralStorage} from "../../src/referrals/ReferralStorage.sol";
import {PositionManager} from "../../src/router/PositionManager.sol";
import {Router} from "../../src/router/Router.sol";

contract TestDeployment is Test {
    RoleStorage roleStorage;
    GlobalMarketConfig globalMarketConfig;
    MarketMaker marketMaker;
    IPriceFeed priceFeed; // Deployed in Helper Config
    TradeStorage tradeStorage;
    ReferralStorage referralStorage;
    PositionManager positionManager;
    Router router;
    address owner;

    function setUp() public {
        Deploy deploy = new Deploy();
        Deploy.Contracts memory contracts = deploy.run();
        roleStorage = contracts.roleStorage;
        globalMarketConfig = contracts.globalMarketConfig;
        marketMaker = contracts.marketMaker;
        priceFeed = contracts.priceFeed;
        tradeStorage = contracts.tradeStorage;
        referralStorage = contracts.referralStorage;
        positionManager = contracts.positionManager;
        router = contracts.router;
        owner = contracts.owner;
    }

    function testDeployment() public {
        assertNotEq(address(roleStorage), address(0));
        assertNotEq(address(globalMarketConfig), address(0));
        assertNotEq(address(marketMaker), address(0));
        assertNotEq(address(priceFeed), address(0));
        assertNotEq(address(tradeStorage), address(0));
        assertNotEq(address(referralStorage), address(0));
        assertNotEq(address(positionManager), address(0));
        assertNotEq(address(router), address(0));
    }
}
