// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import {PositionHandler} from "./handlers/PositionHandler.sol";
import {Deploy} from "script/Deploy.s.sol";
import {MarketFactory, IMarketFactory} from "src/factory/MarketFactory.sol";
import {MockPriceFeed, IPriceFeed} from "test/mocks/MockPriceFeed.sol";
import {ITradeStorage} from "src/positions/interfaces/ITradeStorage.sol";
import {ReferralStorage} from "src/referrals/ReferralStorage.sol";
import {PositionManager} from "src/router/PositionManager.sol";
import {TradeEngine} from "src/positions/TradeEngine.sol";
import {Router} from "src/router/Router.sol";
import {IMarket} from "src/markets/interfaces/IMarket.sol";
import {IVault} from "src/markets/interfaces/IVault.sol";
import {FeeDistributor} from "src/rewards/FeeDistributor.sol";
import {GlobalRewardTracker} from "src/rewards/GlobalRewardTracker.sol";
import {MarketId} from "src/types/MarketId.sol";
import {MockUSDC} from "test/mocks/MockUSDC.sol";
import {WETH} from "src/tokens/WETH.sol";

contract TestPositions is Test {
    PositionHandler handler;

    MarketFactory marketFactory;
    MockPriceFeed priceFeed; // Deployed in Helper Config
    ITradeStorage tradeStorage;
    ReferralStorage referralStorage;
    PositionManager positionManager;
    TradeEngine tradeEngine;
    Router router;
    address OWNER;
    IMarket market;
    IVault vault;
    FeeDistributor feeDistributor;
    GlobalRewardTracker rewardTracker;

    address weth;
    address usdc;

    MarketId marketId;

    string ethTicker = "ETH";
    string usdcTicker = "USDC";
    string[] tickers;

    address user0 = vm.addr(uint256(keccak256("User0")));
    address user1 = vm.addr(uint256(keccak256("User1")));
    address user2 = vm.addr(uint256(keccak256("User2")));
    address user3 = vm.addr(uint256(keccak256("User3")));
    address user4 = vm.addr(uint256(keccak256("User4")));
    address user5 = vm.addr(uint256(keccak256("User5")));
    address[] users = [user0, user1, user2, user3, user4, user5];

    uint8[] precisions;
    uint16[] variances;
    uint48[] timestamps;
    uint64[] meds;

    receive() external payable {}

    function setUp() public {
        Deploy deploy = new Deploy();
        Deploy.Contracts memory contracts = deploy.run();

        (weth, usdc,,,,,,,,) = deploy.activeNetworkConfig();

        marketFactory = contracts.marketFactory;
        vm.label(address(marketFactory), "marketFactory");

        priceFeed = MockPriceFeed(address(contracts.priceFeed));
        vm.label(address(priceFeed), "priceFeed");

        referralStorage = contracts.referralStorage;
        vm.label(address(referralStorage), "referralStorage");

        positionManager = contracts.positionManager;
        vm.label(address(positionManager), "positionManager");

        router = contracts.router;
        vm.label(address(router), "router");

        market = contracts.market;
        vm.label(address(market), "market");

        tradeStorage = contracts.tradeStorage;
        vm.label(address(tradeStorage), "tradeStorage");

        tradeEngine = contracts.tradeEngine;
        vm.label(address(tradeEngine), "tradeEngine");

        feeDistributor = contracts.feeDistributor;
        vm.label(address(feeDistributor), "feeDistributor");

        OWNER = contracts.owner;
        (weth, usdc,,,,,,,,) = deploy.activeNetworkConfig();
        tickers.push(ethTicker);
        tickers.push(usdcTicker);
        // Pass some time so block timestamp isn't 0
        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);

        vm.deal(OWNER, 2_000_000 ether);
        MockUSDC(usdc).mint(OWNER, 1_000_000_000e6);

        vm.startPrank(OWNER);
        WETH(weth).deposit{value: 1_000_000 ether}();
        IMarketFactory.Input memory input = IMarketFactory.Input({
            isMultiAsset: true,
            indexTokenTicker: "ETH",
            marketTokenName: "BRRR",
            marketTokenSymbol: "BRRR",
            strategy: IPriceFeed.SecondaryStrategy({
                exists: false,
                feedType: IPriceFeed.FeedType.CHAINLINK,
                feedAddress: address(0),
                feedId: bytes32(0),
                merkleProof: new bytes32[](0)
            })
        });
        marketFactory.createNewMarket{value: 0.01 ether}(input);
        // Set Prices
        precisions.push(0);
        precisions.push(0);
        variances.push(0);
        variances.push(0);
        timestamps.push(uint48(block.timestamp));
        timestamps.push(uint48(block.timestamp));
        meds.push(3000);
        meds.push(1);
        bytes memory encodedPrices = priceFeed.encodePrices(tickers, precisions, variances, timestamps, meds);
        priceFeed.updatePrices(encodedPrices);
        marketId = marketFactory.executeMarketRequest(marketFactory.getRequestKeys()[0]);
        bytes memory encodedPnl = priceFeed.encodePnl(0, address(market), uint48(block.timestamp), 0);
        priceFeed.updatePnl(encodedPnl);
        vm.stopPrank();
        vault = market.getVault(marketId);
        vm.label(address(vault), "vault");
        tradeStorage = ITradeStorage(market.tradeStorage());
        vm.label(address(tradeStorage), "tradeStorage");
        rewardTracker = GlobalRewardTracker(address(vault.rewardTracker()));
        vm.label(address(rewardTracker), "rewardTracker");
        // Call the deposit function with sufficient gas
        vm.prank(OWNER);
        router.createDeposit{value: 20_000.01 ether + 1 gwei}(marketId, OWNER, weth, 20_000 ether, 0.01 ether, 0, true);
        vm.prank(OWNER);
        positionManager.executeDeposit{value: 0.01 ether}(marketId, market.getRequestAtIndex(marketId, 0).key);

        vm.startPrank(OWNER);
        MockUSDC(usdc).approve(address(router), type(uint256).max);
        router.createDeposit{value: 0.01 ether + 1 gwei}(marketId, OWNER, usdc, 50_000_000e6, 0.01 ether, 0, false);
        positionManager.executeDeposit{value: 0.01 ether}(marketId, market.getRequestAtIndex(marketId, 0).key);
        vm.stopPrank();

        // Set up the handler and set it as the target
        handler = new PositionHandler(
            weth,
            usdc,
            payable(address(router)),
            payable(address(positionManager)),
            address(tradeStorage),
            address(market),
            payable(address(vault)),
            address(priceFeed),
            marketId
        );
        vm.label(address(handler), "handler");
        targetContract(address(handler));
    }

    /// @dev - Test that opening and closing positions over time in a market works as expected
    function invariant_test_positions() public {}
}
