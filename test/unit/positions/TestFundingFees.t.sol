// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.21;

import {Test, console} from "forge-std/Test.sol";
import {DeployV2} from "../../../script/DeployV2.s.sol";
import {RoleStorage} from "../../../src/access/RoleStorage.sol";
import {GlobalMarketConfig} from "../../../src/markets/GlobalMarketConfig.sol";
import {LiquidityVault} from "../../../src/markets/LiquidityVault.sol";
import {MarketFactory} from "../../../src/markets/MarketFactory.sol";
import {MarketStorage} from "../../../src/markets/MarketStorage.sol";
import {MarketToken} from "../../../src/markets/MarketToken.sol";
import {StateUpdater} from "../../../src/markets/StateUpdater.sol";
import {IMockPriceOracle} from "../../../src/mocks/interfaces/IMockPriceOracle.sol";
import {IMockUSDC} from "../../../src/mocks/interfaces/IMockUSDC.sol";
import {DataOracle} from "../../../src/oracle/DataOracle.sol";
import {Executor} from "../../../src/positions/Executor.sol";
import {Liquidator} from "../../../src/positions/Liquidator.sol";
import {RequestRouter} from "../../../src/positions/RequestRouter.sol";
import {TradeStorage} from "../../../src/positions/TradeStorage.sol";
import {TradeVault} from "../../../src/positions/TradeVault.sol";
import {WUSDC} from "../../../src/token/WUSDC.sol";
import {Roles} from "../../../src/access/Roles.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Market} from "../../../src/markets/Market.sol";
import {MarketStructs} from "../../../src/markets/MarketStructs.sol";
import {TradeHelper} from "../../../src/positions/TradeHelper.sol";
import {MarketHelper} from "../../../src/markets/MarketHelper.sol";
import {ImpactCalculator} from "../../../src/positions/ImpactCalculator.sol";
import {BorrowingCalculator} from "../../../src/positions/BorrowingCalculator.sol";
import {FundingCalculator} from "../../../src/positions/FundingCalculator.sol";
import {ITradeStorage} from "../../../src/positions/interfaces/ITradeStorage.sol";

contract TestFunding is Test {
    RoleStorage roleStorage;
    GlobalMarketConfig globalMarketConfig;
    LiquidityVault liquidityVault;
    MarketFactory marketFactory;
    MarketStorage marketStorage;
    MarketToken marketToken;
    StateUpdater stateUpdater;
    IMockPriceOracle priceOracle;
    IMockUSDC usdc;
    DataOracle dataOracle;
    Executor executor;
    Liquidator liquidator;
    RequestRouter requestRouter;
    TradeStorage tradeStorage;
    TradeVault tradeVault;
    WUSDC wusdc;
    MarketToken indexToken;

    address public OWNER;
    address public USER = makeAddr("user");

    uint256 public constant LARGE_AMOUNT = 1e18;
    uint256 public constant DEPOSIT_AMOUNT = 100_000_000_000000;
    uint256 public constant INDEX_ALLOCATION = 1e24;
    uint256 public constant CONVERSION_RATE = 1e12;

    function setUp() public {
        DeployV2 deploy = new DeployV2();
        DeployV2.Contracts memory contracts = deploy.run();
        roleStorage = contracts.roleStorage;
        globalMarketConfig = contracts.globalMarketConfig;
        liquidityVault = contracts.liquidityVault;
        marketFactory = contracts.marketFactory;
        marketStorage = contracts.marketStorage;
        marketToken = contracts.marketToken;
        stateUpdater = contracts.stateUpdater;
        priceOracle = contracts.priceOracle;
        usdc = contracts.usdc;
        dataOracle = contracts.dataOracle;
        executor = contracts.executor;
        liquidator = contracts.liquidator;
        requestRouter = contracts.requestRouter;
        tradeStorage = contracts.tradeStorage;
        tradeVault = contracts.tradeVault;
        wusdc = contracts.wusdc;
        OWNER = contracts.owner;
    }

    receive() external payable {}

    modifier facilitateTrading() {
        vm.deal(OWNER, LARGE_AMOUNT);
        vm.deal(USER, LARGE_AMOUNT);
        // add liquidity
        usdc.mint(OWNER, LARGE_AMOUNT);
        usdc.mint(USER, LARGE_AMOUNT);
        vm.startPrank(OWNER);
        usdc.approve(address(liquidityVault), LARGE_AMOUNT);
        liquidityVault.addLiquidity(DEPOSIT_AMOUNT);
        // create a new index token to trade
        indexToken = new MarketToken("Bitcoin", "BTC", address(roleStorage));
        // create a new market and provide an allocation
        address _market = marketFactory.createMarket(address(indexToken), makeAddr("priceFeed"), 1e18);
        uint256 allocation = INDEX_ALLOCATION;
        stateUpdater.updateState(address(indexToken), allocation, (allocation * 4) / 5);
        vm.stopPrank();
        _;
    }

    function testFundingFeesAreChargedOnTheSideWithGreaterOI() public facilitateTrading {
        // open a large long
        vm.startPrank(USER);
        usdc.approve(address(requestRouter), LARGE_AMOUNT);
        uint256 executionFee = tradeStorage.minExecutionFee();
        MarketStructs.PositionRequest memory userRequest = MarketStructs.PositionRequest(
            0,
            false,
            address(indexToken),
            USER,
            1_000_000e6, // 1 mil USDC
            10_000e18, // $1000 per token, should be = 10 mil USDC (10x leverage)
            0,
            1000e18,
            0.5e18, // 10% slippage
            true,
            true
        );
        requestRouter.createTradeRequest{value: executionFee}(userRequest, executionFee);
        vm.stopPrank();
        vm.prank(OWNER);
        executor.executeTradeOrders(OWNER);
        // pass some time
        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);
        address market = TradeHelper.getMarket(address(marketStorage), address(indexToken));
        Market(market).updateFundingRate();
        vm.warp(block.timestamp + 6 days);
        vm.roll(block.number + 1);
        Market(market).updateFundingRate();
        // check funding fees
        console.log(
            "Long OI: ",
            MarketHelper.getIndexOpenInterestUSD(
                address(marketStorage), address(dataOracle), address(priceOracle), address(indexToken), true
            )
        );
        console.log("Last update time: ", Market(market).lastFundingUpdateTime());
        console.log(
            "Velocity: ", uint256(FundingCalculator.calculateFundingRateVelocity(market, 10000000000000000000000000))
        );
        console.log("Funding Rate: ", uint256(Market(market).fundingRate()));
        (uint256 funding1, uint256 funding2) = FundingCalculator.getFundingFees(market);
        console.log("Funding Fee Total Long: ", funding1);
        console.log("Funding Fee Total Short: ", funding2);
        bytes32 userPositionKey = TradeHelper.generateKey(userRequest);
        MarketStructs.Position memory userPosition = ITradeStorage(address(tradeStorage)).openPositions(userPositionKey);
        console.log("User Fees Owed: ", FundingCalculator.getTotalPositionFeeOwed(market, userPosition));
        funding1 = FundingCalculator.getTotalPositionFeeEarned(market, userPosition);
        funding2 = FundingCalculator.getTotalPositionFeeOwed(market, userPosition);
        console.log("User Fees Earned Since Last Update: ", funding1);
        console.log("User Fees Owed Since Last Update: ", funding2);
    }

    function testFundingFeesForANewPosition() public facilitateTrading {
        // open a position
        vm.startPrank(USER);
        usdc.approve(address(requestRouter), LARGE_AMOUNT);
        uint256 executionFee = tradeStorage.minExecutionFee();
        MarketStructs.PositionRequest memory userRequest = MarketStructs.PositionRequest(
            0,
            false,
            address(indexToken),
            USER,
            1_000_000e6, // 1 mil USDC
            10_000e18, // $1000 per token, should be = 10 mil USDC (10x leverage)
            0,
            1000e18,
            0.5e18, // 10% slippage
            true,
            true
        );
        requestRouter.createTradeRequest{value: executionFee}(userRequest, executionFee);
        vm.stopPrank();
        // execute the position
        vm.prank(OWNER);
        executor.executeTradeOrders(OWNER);
        // pass some time
        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);
        // check the funding rate
        address market = TradeHelper.getMarket(address(marketStorage), address(indexToken));
        // check funding fees
        console.log(
            "Long OI: ",
            MarketHelper.getIndexOpenInterestUSD(
                address(marketStorage), address(dataOracle), address(priceOracle), address(indexToken), true
            )
        );
        console.log("Last update time: ", Market(market).lastFundingUpdateTime());
        console.log(
            "Velocity: ", uint256(FundingCalculator.calculateFundingRateVelocity(market, 10000000000000000000000000))
        );
        console.log("Funding Rate: ", uint256(Market(market).fundingRate()));
        (uint256 funding1, uint256 funding2) = FundingCalculator.getFundingFees(market);
        console.log("Funding Fee Total Long: ", funding1);
        console.log("Funding Fee Total Short: ", funding2);
        bytes32 userPositionKey = TradeHelper.generateKey(userRequest);
        MarketStructs.Position memory userPosition = ITradeStorage(address(tradeStorage)).openPositions(userPositionKey);
        console.log("User Fees Owed: ", FundingCalculator.getTotalPositionFeeOwed(market, userPosition));
        funding1 = FundingCalculator.getTotalPositionFeeEarned(market, userPosition);
        funding2 = FundingCalculator.getTotalPositionFeeOwed(market, userPosition);
        console.log("User Fees Earned Since Last Update: ", funding1);
        console.log("User Fees Owed Since Last Update: ", funding2);
        // call update funding rate
        Market(market).updateFundingRate();
        // check the funding rate
        console.log("Funding Rate After: ", uint256(Market(market).fundingRate()));
        // check funding fees
        (funding1, funding2) = FundingCalculator.getFundingFees(market);
        console.log("Funding Fee Total Long After: ", funding1);
        console.log("Funding Fee Total Short After: ", funding2);
        userPosition = ITradeStorage(address(tradeStorage)).openPositions(userPositionKey);
        console.log("User Fees Owed After: ", FundingCalculator.getTotalPositionFeeOwed(market, userPosition));
        funding1 = FundingCalculator.getTotalPositionFeeEarned(market, userPosition);
        funding2 = FundingCalculator.getTotalPositionFeeOwed(market, userPosition);
        console.log("User Fees Earned Since Last Update After: ", funding1);
        console.log("User Fees Owed Since Last Update After: ", funding2);
    }

    function testFundingFeesAreTheSameBeforeAnUpdateAndAfter() public facilitateTrading {
        // open a position
        vm.startPrank(USER);
        usdc.approve(address(requestRouter), LARGE_AMOUNT);
        uint256 executionFee = tradeStorage.minExecutionFee();
        MarketStructs.PositionRequest memory userRequest = MarketStructs.PositionRequest(
            0,
            false,
            address(indexToken),
            USER,
            1_000_000e6, // 1 mil USDC
            10_000e18, // $1000 per token, should be = 10 mil USDC (10x leverage)
            0,
            1000e18,
            0.5e18, // 10% slippage
            true,
            true
        );
        requestRouter.createTradeRequest{value: executionFee}(userRequest, executionFee);
        vm.stopPrank();
        // execute the position
        vm.prank(OWNER);
        executor.executeTradeOrders(OWNER);
        // pass some time
        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);
        // check the funding rate
        MarketStructs.Position memory userPosition =
            ITradeStorage(address(tradeStorage)).openPositions(TradeHelper.generateKey(userRequest));
        address market = TradeHelper.getMarket(address(marketStorage), address(indexToken));
        // check funding fees
        uint256 feesOwed = FundingCalculator.getTotalPositionFeeOwed(market, userPosition);
        console.log("Funding Fee Owed Before Update: ", feesOwed);
        // call update funding rate
        Market(market).updateFundingRate();
        // check the funding rate
        uint256 feesAfter = FundingCalculator.getTotalPositionFeeOwed(market, userPosition);
        console.log("Funding Fee Owed After Update: ", feesAfter);
    }

    function testFundingFeesAreEarnedByCounterparties() public facilitateTrading {
        // open a large long from user
        vm.startPrank(USER);
        usdc.approve(address(requestRouter), LARGE_AMOUNT);
        uint256 executionFee = tradeStorage.minExecutionFee();
        MarketStructs.PositionRequest memory userRequest = MarketStructs.PositionRequest(
            0,
            false,
            address(indexToken),
            USER,
            1_000_000e6, // 1 mil USDC
            10_000e18, // $1000 per token, should be = 10 mil USDC (10x leverage)
            0,
            1000e18,
            0.5e18, // 10% slippage
            true,
            true
        );
        requestRouter.createTradeRequest{value: executionFee}(userRequest, executionFee);
        vm.stopPrank();
        // open a small short from owner
        vm.startPrank(OWNER);
        usdc.approve(address(requestRouter), LARGE_AMOUNT);
        MarketStructs.PositionRequest memory ownerRequest = MarketStructs.PositionRequest(
            0,
            false,
            address(indexToken),
            OWNER,
            100e6,
            1e18,
            0,
            1000e18,
            0.5e18, // 10% slippage
            false,
            true
        );
        requestRouter.createTradeRequest{value: executionFee}(ownerRequest, executionFee);
        vm.stopPrank();
        // execute the trades
        vm.prank(OWNER);
        executor.executeTradeOrders(OWNER);
        // pass some time
        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);
        // check the fees earned by the owner's position
        MarketStructs.Position memory ownerPosition =
            ITradeStorage(address(tradeStorage)).openPositions(TradeHelper.generateKey(ownerRequest));
        address market = TradeHelper.getMarket(address(marketStorage), address(indexToken));
        // check funding fees
        uint256 feesOwed = FundingCalculator.getTotalPositionFeeOwed(market, ownerPosition);
        assertEq(feesOwed, 0);
        uint256 feesEarned = FundingCalculator.getTotalPositionFeeEarned(market, ownerPosition);
        assertGt(feesEarned, 0);
        console.log("Fees Owed: ", feesOwed);
        console.log("Fees Earned: ", feesEarned);
    }

    function testFundingFeesAccumulateOnBothSidesWithSignFlip() public facilitateTrading {
        // open a trade from user skewing OI long
        vm.startPrank(USER);
        usdc.approve(address(requestRouter), LARGE_AMOUNT);
        uint256 executionFee = tradeStorage.minExecutionFee();
        MarketStructs.PositionRequest memory userRequest = MarketStructs.PositionRequest(
            0,
            false,
            address(indexToken),
            USER,
            100e6,
            1e18,
            0,
            1000e18,
            0.5e18, // 10% slippage
            true,
            true
        );
        requestRouter.createTradeRequest{value: executionFee}(userRequest, executionFee);
        vm.stopPrank();
        // execute trade
        vm.prank(OWNER);
        executor.executeTradeOrders(OWNER);
        // pass some time
        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);
        // open a trade from owner skewing OI short
        vm.startPrank(OWNER);
        usdc.approve(address(requestRouter), LARGE_AMOUNT);
        MarketStructs.PositionRequest memory ownerRequest = MarketStructs.PositionRequest(
            0,
            false,
            address(indexToken),
            OWNER,
            1000e6,
            10e18,
            0,
            1000e18,
            0.5e18, // 10% slippage
            false,
            true
        );
        requestRouter.createTradeRequest{value: executionFee}(ownerRequest, executionFee);
        // execute trade
        executor.executeTradeOrders(OWNER);
        vm.stopPrank();
        // pass some time
        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);
        // check the user's trade has fees owed and fees earned
        MarketStructs.Position memory userPosition =
            ITradeStorage(address(tradeStorage)).openPositions(TradeHelper.generateKey(userRequest));
        address market = TradeHelper.getMarket(address(marketStorage), address(indexToken));
        // check funding fees
        uint256 feesOwed = FundingCalculator.getTotalPositionFeeOwed(market, userPosition);
        assertGt(feesOwed, 0);
        uint256 feesEarned = FundingCalculator.getTotalPositionFeeEarned(market, userPosition);
        assertGt(feesEarned, 0);
        console.log("Fees Owed: ", feesOwed);
        console.log("Fees Earned: ", feesEarned);
    }
}
