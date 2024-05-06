// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import {Deploy} from "script/Deploy.s.sol";
import {MarketFactory, IMarketFactory} from "src/factory/MarketFactory.sol";
import {IPriceFeed} from "src/oracle/interfaces/IPriceFeed.sol";
import {TradeStorage} from "src/positions/TradeStorage.sol";
import {ReferralStorage} from "src/referrals/ReferralStorage.sol";
import {PositionManager} from "src/router/PositionManager.sol";
import {Router} from "src/router/Router.sol";
import {Market} from "src/markets/Market.sol";
import {TradeEngine} from "src/positions/TradeEngine.sol";

contract TestDeployment is Test {
    MarketFactory marketFactory;
    IPriceFeed priceFeed; // Deployed in Helper Config
    ReferralStorage referralStorage;
    PositionManager positionManager;
    Market market;
    TradeEngine tradeEngine;
    TradeStorage tradeStorage;
    Router router;
    address owner;

    function setUp() public {
        Deploy deploy = new Deploy();
        Deploy.Contracts memory contracts = deploy.run();
        marketFactory = contracts.marketFactory;
        priceFeed = contracts.priceFeed;
        referralStorage = contracts.referralStorage;
        positionManager = contracts.positionManager;
        market = contracts.market;
        tradeEngine = contracts.tradeEngine;
        tradeStorage = contracts.tradeStorage;
        router = contracts.router;
        owner = contracts.owner;
    }

    function test_deployment() public {
        assertNotEq(address(marketFactory), address(0));
        assertNotEq(address(priceFeed), address(0));
        assertNotEq(address(referralStorage), address(0));
        assertNotEq(address(positionManager), address(0));
        assertNotEq(address(market), address(0));
        assertNotEq(address(tradeEngine), address(0));
        assertNotEq(address(tradeStorage), address(0));
        assertNotEq(address(router), address(0));
    }
}
