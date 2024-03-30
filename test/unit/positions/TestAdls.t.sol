// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Test, console, console2, stdStorage, StdStorage} from "forge-std/Test.sol";
import {Deploy} from "../../../script/Deploy.s.sol";
import {RoleStorage} from "../../../src/access/RoleStorage.sol";
import {Market, IMarket} from "../../../src/markets/Market.sol";
import {MarketMaker, IMarketMaker} from "../../../src/markets/MarketMaker.sol";
import {IPriceFeed} from "../../../src/oracle/interfaces/IPriceFeed.sol";
import {TradeStorage, ITradeStorage} from "../../../src/positions/TradeStorage.sol";
import {ReferralStorage} from "../../../src/referrals/ReferralStorage.sol";
import {PositionManager} from "../../../src/router/PositionManager.sol";
import {Router} from "../../../src/router/Router.sol";
import {WETH} from "../../../src/tokens/WETH.sol";
import {Oracle} from "../../../src/oracle/Oracle.sol";
import {MockUSDC} from "../../mocks/MockUSDC.sol";
import {Position} from "../../../src/positions/Position.sol";
import {Gas} from "../../../src/libraries/Gas.sol";
import {Funding} from "../../../src/libraries/Funding.sol";
import {PriceImpact} from "../../../src/libraries/PriceImpact.sol";
import {Borrowing} from "../../../src/libraries/Borrowing.sol";
import {mulDiv} from "@prb/math/Common.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {MockPriceFeed} from "../../mocks/MockPriceFeed.sol";
import {MarketUtils} from "../../../src/markets/MarketUtils.sol";

contract TestADLs is Test {
    using SignedMath for int256;
    using stdStorage for StdStorage;

    RoleStorage roleStorage;

    MarketMaker marketMaker;
    IPriceFeed priceFeed; // Deployed in Helper Config
    ITradeStorage tradeStorage;
    ReferralStorage referralStorage;
    PositionManager positionManager;
    Router router;
    address OWNER;
    Market market;
    address feeDistributor;

    address weth;
    address usdc;
    bytes32 ethPriceId;
    bytes32 usdcPriceId;

    bytes[] tokenUpdateData;
    uint256[] allocations;

    address USER = makeAddr("USER");
    address RANDOM1 = makeAddr("RANDOM1");
    address RANDOM2 = makeAddr("RANDOM2");
    address RANDOM3 = makeAddr("RANDOM3");

    bytes32[] assetIds;
    uint256[] compactedPrices;

    Oracle.PriceUpdateData ethPriceData;

    bytes32 ethAssetId = keccak256(abi.encode("ETH"));
    bytes32 usdcAssetId = keccak256(abi.encode("USDC"));

    function setUp() public {
        Deploy deploy = new Deploy();
        Deploy.Contracts memory contracts = deploy.run();
        roleStorage = contracts.roleStorage;

        marketMaker = contracts.marketMaker;
        priceFeed = contracts.priceFeed;
        referralStorage = contracts.referralStorage;
        positionManager = contracts.positionManager;
        router = contracts.router;
        feeDistributor = address(contracts.feeDistributor);
        OWNER = contracts.owner;
        (weth, usdc, ethPriceId, usdcPriceId,,,,) = deploy.activeNetworkConfig();
        // Pass some time so block timestamp isn't 0
        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);
        // Set Update Data
        bytes memory wethUpdateData = priceFeed.createPriceFeedUpdateData(
            ethPriceId, 250000, 50, -2, 250000, 50, uint64(block.timestamp), uint64(block.timestamp)
        );
        bytes memory usdcUpdateData = priceFeed.createPriceFeedUpdateData(
            usdcPriceId, 1, 0, 0, 1, 0, uint64(block.timestamp), uint64(block.timestamp)
        );
        tokenUpdateData.push(wethUpdateData);
        tokenUpdateData.push(usdcUpdateData);
        assetIds.push(ethAssetId);
        assetIds.push(usdcAssetId);

        ethPriceData =
            Oracle.PriceUpdateData({assetIds: assetIds, pythData: tokenUpdateData, compactedPrices: compactedPrices});
    }

    receive() external payable {}

    modifier setUpMarkets() {
        vm.deal(OWNER, 1_000_000 ether);
        MockUSDC(usdc).mint(OWNER, 1_000_000_000e6);
        vm.deal(USER, 1_000_000 ether);
        MockUSDC(usdc).mint(USER, 1_000_000_000e6);
        vm.startPrank(OWNER);
        WETH(weth).deposit{value: 50 ether}();
        Oracle.Asset memory wethData = Oracle.Asset({
            chainlinkPriceFeed: address(0),
            priceId: ethPriceId,
            baseUnit: 1e18,
            heartbeatDuration: 1 minutes,
            maxPriceDeviation: 0.01e18,
            primaryStrategy: Oracle.PrimaryStrategy.PYTH,
            secondaryStrategy: Oracle.SecondaryStrategy.NONE,
            pool: Oracle.UniswapPool({token0: weth, token1: usdc, poolAddress: address(0), poolType: Oracle.PoolType.V3})
        });
        IMarketMaker.MarketRequest memory request = IMarketMaker.MarketRequest({
            owner: OWNER,
            indexTokenTicker: "ETH",
            marketTokenName: "BRRR",
            marketTokenSymbol: "BRRR",
            asset: wethData
        });
        marketMaker.requestNewMarket{value: 0.01 ether}(request);
        // Set primary prices for ref price
        priceFeed.setPrimaryPrices{value: 0.01 ether}(assetIds, tokenUpdateData, compactedPrices);
        // Clear them
        priceFeed.clearPrimaryPrices();
        marketMaker.executeNewMarket(marketMaker.getMarketRequestKey(request.owner, request.indexTokenTicker));
        vm.stopPrank();
        market = Market(payable(marketMaker.tokenToMarket(ethAssetId)));
        tradeStorage = ITradeStorage(market.tradeStorage());
        // Call the deposit function with sufficient gas
        vm.prank(OWNER);
        router.createDeposit{value: 20_000.01 ether + 1 gwei}(market, OWNER, weth, 20_000 ether, 0.01 ether, true);
        vm.prank(OWNER);
        positionManager.executeDeposit{value: 0.01 ether}(market, market.getRequestAtIndex(0).key, ethPriceData);

        vm.startPrank(OWNER);
        MockUSDC(usdc).approve(address(router), type(uint256).max);
        router.createDeposit{value: 0.01 ether + 1 gwei}(market, OWNER, usdc, 50_000_000e6, 0.01 ether, false);
        positionManager.executeDeposit{value: 0.01 ether}(market, market.getRequestAtIndex(0).key, ethPriceData);
        vm.stopPrank();
        vm.startPrank(OWNER);
        allocations.push(10000 << 240);
        assertEq(MarketUtils.getAllocation(market, ethAssetId), 10000);
        vm.stopPrank();
        _;
    }

    function testPositionsInPoolsWithLargePnlToPoolRatiosCanBeAdled() public setUpMarkets {
        vm.deal(RANDOM1, 1_000_000 ether);
        MockUSDC(usdc).mint(RANDOM1, 1_000_000_000e6);
        vm.deal(RANDOM2, 1_000_000 ether);
        MockUSDC(usdc).mint(RANDOM2, 1_000_000_000e6);
        vm.deal(RANDOM3, 1_000_000 ether);
        MockUSDC(usdc).mint(RANDOM3, 1_000_000_000e6);
        // open several positions on the market
        Position.Input memory input = Position.Input({
            assetId: ethAssetId,
            collateralToken: usdc,
            collateralDelta: 125_000e6,
            sizeDelta: 3_500_000e30,
            limitPrice: 0,
            maxSlippage: 0.9999e30,
            executionFee: 0.01 ether,
            isLong: false,
            isLimit: false,
            isIncrease: true,
            reverseWrap: false,
            conditionals: Position.Conditionals({
                stopLossSet: false,
                takeProfitSet: false,
                stopLossPrice: 0,
                takeProfitPrice: 0,
                stopLossPercentage: 0,
                takeProfitPercentage: 0
            })
        });
        vm.startPrank(OWNER);
        MockUSDC(usdc).approve(address(router), type(uint256).max);
        router.createPositionRequest{value: 0.01 ether}(input);
        vm.stopPrank();
        vm.startPrank(USER);
        MockUSDC(usdc).approve(address(router), type(uint256).max);
        router.createPositionRequest{value: 0.01 ether}(input);
        vm.stopPrank();
        vm.startPrank(RANDOM1);
        MockUSDC(usdc).approve(address(router), type(uint256).max);
        router.createPositionRequest{value: 0.01 ether}(input);
        vm.stopPrank();
        vm.startPrank(RANDOM2);
        MockUSDC(usdc).approve(address(router), type(uint256).max);
        router.createPositionRequest{value: 0.01 ether}(input);
        vm.stopPrank();
        vm.startPrank(RANDOM3);
        MockUSDC(usdc).approve(address(router), type(uint256).max);
        router.createPositionRequest{value: 0.01 ether}(input);
        vm.stopPrank();
        // Execute the Position
        bytes32 orderKey = tradeStorage.getOrderAtIndex(0, false);
        vm.prank(OWNER);
        positionManager.executePosition{value: 0.0001 ether}(market, orderKey, OWNER, ethPriceData);
        orderKey = tradeStorage.getOrderAtIndex(0, false);
        positionManager.executePosition{value: 0.0001 ether}(market, orderKey, USER, ethPriceData);
        orderKey = tradeStorage.getOrderAtIndex(0, false);
        positionManager.executePosition{value: 0.0001 ether}(market, orderKey, RANDOM1, ethPriceData);
        orderKey = tradeStorage.getOrderAtIndex(0, false);
        positionManager.executePosition{value: 0.0001 ether}(market, orderKey, RANDOM2, ethPriceData);
        orderKey = tradeStorage.getOrderAtIndex(0, false);
        positionManager.executePosition{value: 0.0001 ether}(market, orderKey, RANDOM3, ethPriceData);

        vm.warp(block.timestamp + 10);
        vm.roll(block.number + 1);
        // move the price so that the pnl to pool ratio is large
        bytes memory wethUpdateData = priceFeed.createPriceFeedUpdateData(
            ethPriceId, 10000, 50, -2, 10000, 50, uint64(block.timestamp), uint64(block.timestamp)
        );
        tokenUpdateData[0] = wethUpdateData;
        ethPriceData.pythData = tokenUpdateData;
        // get one of the position keys
        bytes32[] memory positionKeys = tradeStorage.getOpenPositionKeys(false);
        // adl it
        vm.prank(OWNER);
        positionManager.executeAdl{value: 0.01 ether}(market, ethAssetId, 5000e30, positionKeys[0], ethPriceData);
        // validate their size has been reduced
        Position.Data memory position = tradeStorage.getPosition(positionKeys[0]);
        assertEq(position.positionSize, 3_495_000e30);
    }
}
