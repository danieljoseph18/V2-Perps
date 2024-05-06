// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import {Deploy} from "script/Deploy.s.sol";
import {IMarket, Market} from "src/markets/Market.sol";
import {IVault} from "src/markets/Vault.sol";
import {Pool} from "src/markets/Pool.sol";
import {MarketFactory, IMarketFactory} from "src/factory/MarketFactory.sol";
import {IPriceFeed} from "src/oracle/interfaces/IPriceFeed.sol";
import {TradeStorage, ITradeStorage} from "src/positions/TradeStorage.sol";
import {ReferralStorage} from "src/referrals/ReferralStorage.sol";
import {PositionManager} from "src/router/PositionManager.sol";
import {Router} from "src/router/Router.sol";
import {WETH} from "src/tokens/WETH.sol";
import {Oracle} from "src/oracle/Oracle.sol";
import {MockUSDC} from "../../mocks/MockUSDC.sol";
import {Position} from "src/positions/Position.sol";
import {MarketUtils} from "src/markets/MarketUtils.sol";
import {GlobalRewardTracker} from "src/rewards/GlobalRewardTracker.sol";
import {FeeDistributor} from "src/rewards/FeeDistributor.sol";
import {MockPriceFeed} from "../../mocks/MockPriceFeed.sol";
import {MathUtils} from "src/libraries/MathUtils.sol";
import {Units} from "src/libraries/Units.sol";
import {Referral} from "src/referrals/Referral.sol";
import {IERC20} from "src/tokens/interfaces/IERC20.sol";
import {PriceImpact} from "src/libraries/PriceImpact.sol";
import {Execution} from "src/positions/Execution.sol";
import {Funding} from "src/libraries/Funding.sol";
import {Borrowing} from "src/libraries/Borrowing.sol";
import {TradeEngine} from "src/positions/TradeEngine.sol";
import {MarketId} from "src/types/MarketId.sol";

contract TestMarketAllocations is Test {
    using MathUtils for uint256;
    using Units for uint256;

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
    address link;

    MarketId marketId;

    string ethTicker = "ETH";
    string usdcTicker = "USDC";
    string[] tickers;

    address USER = makeAddr("USER");
    address USER1 = makeAddr("USER1");
    address USER2 = makeAddr("USER2");

    uint8[] precisions;
    uint16[] variances;
    uint48[] timestamps;
    uint64[] meds;

    function setUp() public {
        Deploy deploy = new Deploy();
        Deploy.Contracts memory contracts = deploy.run();

        marketFactory = contracts.marketFactory;
        priceFeed = MockPriceFeed(address(contracts.priceFeed));
        referralStorage = contracts.referralStorage;
        positionManager = contracts.positionManager;
        router = contracts.router;
        market = contracts.market;
        tradeStorage = contracts.tradeStorage;
        tradeEngine = contracts.tradeEngine;
        feeDistributor = contracts.feeDistributor;
        OWNER = contracts.owner;
        (weth, usdc, link,,,,,,,) = deploy.activeNetworkConfig();
        tickers.push(ethTicker);
        tickers.push(usdcTicker);
        // Pass some time so block timestamp isn't 0
        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);
    }

    receive() external payable {}

    modifier setUpMarkets() {
        vm.deal(OWNER, 2_000_000 ether);
        MockUSDC(usdc).mint(OWNER, 1_000_000_000e6);
        vm.deal(USER, 2_000_000 ether);
        MockUSDC(usdc).mint(USER, 1_000_000_000e6);
        vm.deal(USER1, 2_000_000 ether);
        MockUSDC(usdc).mint(USER1, 1_000_000_000e6);
        vm.deal(USER2, 2_000_000 ether);
        MockUSDC(usdc).mint(USER2, 1_000_000_000e6);
        vm.prank(USER);
        WETH(weth).deposit{value: 1_000_000 ether}();
        vm.prank(USER1);
        WETH(weth).deposit{value: 1_000_000 ether}();
        vm.prank(USER2);
        WETH(weth).deposit{value: 1_000_000 ether}();
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
        tradeStorage = ITradeStorage(market.tradeStorage());
        rewardTracker = GlobalRewardTracker(address(vault.rewardTracker()));
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
        _;
    }

    modifier addTokenToMarket() {
        // 1. Call request asset pricing
        IMarketFactory.Input memory input = IMarketFactory.Input({
            isMultiAsset: true,
            indexTokenTicker: "SOL",
            marketTokenName: "SOL-BRRR",
            marketTokenSymbol: "SOL-BRRR",
            strategy: IPriceFeed.SecondaryStrategy({
                exists: false,
                feedType: IPriceFeed.FeedType.CHAINLINK,
                feedAddress: address(0),
                feedId: bytes32(0),
                merkleProof: new bytes32[](0)
            })
        });
        vm.prank(OWNER);
        marketFactory.requestAssetPricing{value: marketFactory.priceSupportFee()}(input);
        // 2. Call support asset
        bytes32 requestKey = keccak256(abi.encodePacked("SOL"));
        vm.startPrank(OWNER);
        // Request a price
        bytes32 priceRequestKey = keccak256(abi.encode("PRICE REQUEST"));
        // Call updatePrices and set a price for SOL
        tickers.push("SOL");
        precisions.push(0);
        variances.push(0);
        timestamps[0] = uint48(block.timestamp);
        timestamps[1] = uint48(block.timestamp);
        timestamps.push(uint48(block.timestamp));
        meds.push(100);
        bytes memory encodedPrices = priceFeed.encodePrices(tickers, precisions, variances, timestamps, meds);
        priceFeed.updatePrices(encodedPrices);
        marketFactory.supportAsset(requestKey);
        // 3. Add token to market
        Pool.Config memory config = Pool.Config({
            maxLeverage: 100,
            maintenanceMargin: 500,
            reserveFactor: 2500,
            maxFundingVelocity: 900,
            skewScale: 1_000_000,
            positiveLiquidityScalar: 1_0000,
            negativeLiquidityScalar: 1_0000
        });
        uint8[] memory allocations = new uint8[](2);
        allocations[0] = 50;
        allocations[1] = 50;
        bytes memory newAllocations = MarketUtils.encodeAllocations(allocations);

        // Add the Token to the Market
        Market(address(market)).addToken(marketId, config, "SOL", newAllocations, priceRequestKey);
        vm.stopPrank();
        _;
    }

    function test_adding_a_new_token_to_a_market() public setUpMarkets {
        // 1. Call request asset pricing
        IMarketFactory.Input memory input = IMarketFactory.Input({
            isMultiAsset: true,
            indexTokenTicker: "SOL",
            marketTokenName: "SOL-BRRR",
            marketTokenSymbol: "SOL-BRRR",
            strategy: IPriceFeed.SecondaryStrategy({
                exists: false,
                feedType: IPriceFeed.FeedType.CHAINLINK,
                feedAddress: address(0),
                feedId: bytes32(0),
                merkleProof: new bytes32[](0)
            })
        });
        vm.prank(OWNER);
        marketFactory.requestAssetPricing{value: marketFactory.priceSupportFee()}(input);
        // 2. Call support asset
        bytes32 requestKey = keccak256(abi.encodePacked("SOL"));
        uint8[] memory allocations = new uint8[](2);
        allocations[0] = 50;
        allocations[1] = 50;
        bytes memory newAllocations = MarketUtils.encodeAllocations(allocations);
        vm.startPrank(OWNER);
        // Request a price
        bytes32 priceRequestKey = keccak256(abi.encode("PRICE REQUEST"));
        // Call updatePrices and set a price for SOL
        tickers.push("SOL");
        precisions.push(0);
        variances.push(0);
        timestamps[0] = uint48(block.timestamp);
        timestamps[1] = uint48(block.timestamp);
        timestamps.push(uint48(block.timestamp));
        meds.push(100);
        bytes memory encodedPrices = priceFeed.encodePrices(tickers, precisions, variances, timestamps, meds);
        priceFeed.updatePrices(encodedPrices);

        marketFactory.supportAsset(requestKey);
        // 3. Add token to market
        Pool.Config memory config = Pool.Config({
            maxLeverage: 100,
            maintenanceMargin: 500,
            reserveFactor: 2500,
            maxFundingVelocity: 900,
            skewScale: 1_000_000,
            positiveLiquidityScalar: 1_0000,
            negativeLiquidityScalar: 1_0000
        });
        // Add the Token to the Market
        Market(address(market)).addToken(marketId, config, "SOL", newAllocations, priceRequestKey);
        vm.stopPrank();
    }

    function test_removing_a_token_from_a_market() public setUpMarkets addTokenToMarket {
        uint8[] memory allocations2 = new uint8[](1);
        allocations2[0] = 100;
        bytes memory newAllocations2 = MarketUtils.encodeAllocations(allocations2);
        vm.prank(OWNER);
        Market(address(market)).removeToken(marketId, "ETH", newAllocations2, keccak256(abi.encode("PRICE REQUEST")));

        // Fetch the tickers and ensure the token has been removed
        string[] memory fetchedTickers = market.getTickers(marketId);
        assertEq(fetchedTickers.length, 1);
        assertEq(fetchedTickers[0], "SOL");
    }

    function test_markets_require_at_least_one_token() public setUpMarkets addTokenToMarket {
        uint8[] memory allocations2 = new uint8[](1);
        allocations2[0] = 100;
        bytes memory newAllocations2 = MarketUtils.encodeAllocations(allocations2);
        vm.startPrank(OWNER);
        Market(address(market)).removeToken(marketId, "ETH", newAllocations2, keccak256(abi.encode("PRICE REQUEST")));

        vm.expectRevert();
        Market(address(market)).removeToken(marketId, "SOL", newAllocations2, keccak256(abi.encode("PRICE REQUEST")));
        vm.stopPrank();
    }

    function test_setting_allocations(uint256 _solAllocation) public setUpMarkets addTokenToMarket {
        _solAllocation = bound(_solAllocation, 1, 99);
        uint256 ethAllocation = 100 - _solAllocation;

        uint8[] memory allocations = new uint8[](2);
        allocations[0] = uint8(ethAllocation);
        allocations[1] = uint8(_solAllocation);

        bytes memory newAllocations = MarketUtils.encodeAllocations(allocations);

        vm.startPrank(OWNER);
        Market(address(market)).reallocate(marketId, newAllocations, keccak256(abi.encode("PRICE REQUEST")));
    }

    function test_invalid_allocations_always_revert(uint256 _solAllocation, uint256 _ethAllocation)
        public
        setUpMarkets
        addTokenToMarket
    {
        _solAllocation = bound(_solAllocation, 0, type(uint8).max);
        _ethAllocation = bound(_ethAllocation, 0, type(uint8).max);

        vm.assume(_solAllocation + _ethAllocation != 100);

        uint8[] memory allocations = new uint8[](2);
        allocations[0] = uint8(_ethAllocation);
        allocations[1] = uint8(_solAllocation);

        bytes memory newAllocations = MarketUtils.encodeAllocations(allocations);

        vm.prank(OWNER);
        vm.expectRevert();
        Market(address(market)).reallocate(marketId, newAllocations, keccak256(abi.encode("PRICE REQUEST")));
    }

    // Test a user can't add the same asset multiple times
    function test_users_cant_add_the_same_asset_twice(string memory _ticker) public setUpMarkets {
        vm.assume(bytes(_ticker).length < 15);
        // 1. Call request asset pricing
        IMarketFactory.Input memory input = IMarketFactory.Input({
            isMultiAsset: true,
            indexTokenTicker: _ticker,
            marketTokenName: string(abi.encodePacked(_ticker, "-BRRR")),
            marketTokenSymbol: string(abi.encodePacked(_ticker, "-BRRR")),
            strategy: IPriceFeed.SecondaryStrategy({
                exists: false,
                feedType: IPriceFeed.FeedType.CHAINLINK,
                feedAddress: address(0),
                feedId: bytes32(0),
                merkleProof: new bytes32[](0)
            })
        });
        vm.prank(OWNER);
        marketFactory.requestAssetPricing{value: marketFactory.priceSupportFee()}(input);
        // 2. Call support asset
        bytes32 requestKey = keccak256(abi.encodePacked(_ticker));
        vm.prank(OWNER);
        uint8[] memory allocations = new uint8[](2);
        allocations[0] = 50;
        allocations[1] = 50;
        bytes memory newAllocations = MarketUtils.encodeAllocations(allocations);
        vm.startPrank(OWNER);
        // Request a price
        bytes32 priceRequestKey = keccak256(abi.encode("PRICE REQUEST"));
        // Call updatePrices and set a price for SOL
        tickers.push(_ticker);
        precisions.push(0);
        variances.push(0);
        timestamps[0] = uint48(block.timestamp);
        timestamps[1] = uint48(block.timestamp);
        timestamps.push(uint48(block.timestamp));
        meds.push(100);
        bytes memory encodedPrices = priceFeed.encodePrices(tickers, precisions, variances, timestamps, meds);
        priceFeed.updatePrices(encodedPrices);
        marketFactory.supportAsset(requestKey);
        // 3. Add token to market
        Pool.Config memory config = Pool.Config({
            maxLeverage: 100,
            maintenanceMargin: 500,
            reserveFactor: 2500,
            maxFundingVelocity: 900,
            skewScale: 1_000_000,
            positiveLiquidityScalar: 1_0000,
            negativeLiquidityScalar: 1_0000
        });

        // Add the Token to the Market
        Market(address(market)).addToken(marketId, config, _ticker, newAllocations, priceRequestKey);
        vm.expectRevert();
        Market(address(market)).addToken(marketId, config, _ticker, newAllocations, priceRequestKey);
        vm.stopPrank();
    }

    function test_users_cant_use_expired_price_data(uint256 _timeToSkip) public setUpMarkets {
        _timeToSkip = bound(_timeToSkip, 3 minutes, type(uint40).max);
        // 1. Call request asset pricing
        IMarketFactory.Input memory input = IMarketFactory.Input({
            isMultiAsset: true,
            indexTokenTicker: "SOL",
            marketTokenName: "SOL-BRRR",
            marketTokenSymbol: "SOL-BRRR",
            strategy: IPriceFeed.SecondaryStrategy({
                exists: false,
                feedType: IPriceFeed.FeedType.CHAINLINK,
                feedAddress: address(0),
                feedId: bytes32(0),
                merkleProof: new bytes32[](0)
            })
        });
        vm.prank(OWNER);
        marketFactory.requestAssetPricing{value: marketFactory.priceSupportFee()}(input);
        // 2. Call support asset
        bytes32 requestKey = keccak256(abi.encodePacked("SOL"));
        vm.startPrank(OWNER);
        // Request a price
        bytes32 priceRequestKey = keccak256(abi.encode("PRICE REQUEST"));
        // Call updatePrices and set a price for SOL
        tickers.push("SOL");
        precisions.push(0);
        variances.push(0);
        timestamps[0] = uint48(block.timestamp);
        timestamps[1] = uint48(block.timestamp);
        timestamps.push(uint48(block.timestamp));
        meds.push(100);
        bytes memory encodedPrices = priceFeed.encodePrices(tickers, precisions, variances, timestamps, meds);
        priceFeed.updatePrices(encodedPrices);
        marketFactory.supportAsset(requestKey);
        // 3. Add token to market
        Pool.Config memory config = Pool.Config({
            maxLeverage: 100,
            maintenanceMargin: 500,
            reserveFactor: 2500,
            maxFundingVelocity: 900,
            skewScale: 1_000_000,
            positiveLiquidityScalar: 1_0000,
            negativeLiquidityScalar: 1_0000
        });
        uint8[] memory allocations = new uint8[](2);
        allocations[0] = 50;
        allocations[1] = 50;
        bytes memory newAllocations = MarketUtils.encodeAllocations(allocations);

        skip(_timeToSkip);

        // Add the Token to the Market
        vm.expectRevert();
        Market(address(market)).addToken(marketId, config, "SOL", newAllocations, priceRequestKey);
        vm.stopPrank();
    }

    function test_adding_up_to_100_tokens_to_a_market() public setUpMarkets {
        IMarketFactory.Input memory input = IMarketFactory.Input({
            isMultiAsset: true,
            indexTokenTicker: "SOL",
            marketTokenName: "SOL-BRRR",
            marketTokenSymbol: "SOL-BRRR",
            strategy: IPriceFeed.SecondaryStrategy({
                exists: false,
                feedType: IPriceFeed.FeedType.CHAINLINK,
                feedAddress: address(0),
                feedId: bytes32(0),
                merkleProof: new bytes32[](0)
            })
        });
        Pool.Config memory config = Pool.Config({
            maxLeverage: 100,
            maintenanceMargin: 500,
            reserveFactor: 2500,
            maxFundingVelocity: 900,
            skewScale: 1_000_000,
            positiveLiquidityScalar: 1_0000,
            negativeLiquidityScalar: 1_0000
        });

        for (uint256 i = 0; i < 99; i++) {
            string memory ticker = vm.toString(i);
            input.indexTokenTicker = ticker;
            vm.startPrank(OWNER);
            marketFactory.requestAssetPricing{value: marketFactory.priceSupportFee()}(input);
            bytes32 priceRequestKey = keccak256(abi.encode("PRICE REQUEST"));
            tickers.push(ticker);
            precisions.push(0);
            variances.push(0);
            timestamps.push(uint48(block.timestamp));
            meds.push(100);
            bytes memory encodedPrices = priceFeed.encodePrices(tickers, precisions, variances, timestamps, meds);
            priceFeed.updatePrices(encodedPrices);
            bytes32 requestKey = keccak256(abi.encodePacked(ticker));
            marketFactory.supportAsset(requestKey);
            uint8[] memory allocations = new uint8[](2 + i);
            uint256 remainingAllocation = 100;
            for (uint256 j = 0; j < allocations.length; j++) {
                if (j == allocations.length - 1) {
                    allocations[j] = uint8(remainingAllocation);
                } else {
                    allocations[j] = uint8(1);
                    remainingAllocation--;
                }
            }
            bytes memory newAllocations = MarketUtils.encodeAllocations(allocations);
            Market(address(market)).addToken(marketId, config, ticker, newAllocations, priceRequestKey);
            vm.stopPrank();
        }
    }
}
