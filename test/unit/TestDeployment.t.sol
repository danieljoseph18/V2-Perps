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

contract TestDeployment is Test {
    MarketFactory marketFactory;
    IPriceFeed priceFeed; // Deployed in Helper Config
    ReferralStorage referralStorage;
    PositionManager positionManager;
    Router router;
    address owner;

    function setUp() public {
        Deploy deploy = new Deploy();
        Deploy.Contracts memory contracts = deploy.run();
        marketFactory = contracts.marketFactory;
        priceFeed = contracts.priceFeed;
        referralStorage = contracts.referralStorage;
        positionManager = contracts.positionManager;
        router = contracts.router;
        owner = contracts.owner;
    }

    function test_deployment() public {
        assertNotEq(address(marketFactory), address(0));
        assertNotEq(address(priceFeed), address(0));
        assertNotEq(address(referralStorage), address(0));
        assertNotEq(address(positionManager), address(0));
        assertNotEq(address(router), address(0));
    }
}
