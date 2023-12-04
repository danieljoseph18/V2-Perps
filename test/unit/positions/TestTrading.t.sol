// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

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

contract TestTrading is Test {
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

    uint256 public constant LARGE_AMOUNT = 1e30;
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
        address _market = marketFactory.createMarket(address(indexToken), makeAddr("priceFeed"), 18);
        uint256 allocation = INDEX_ALLOCATION;
        stateUpdater.updateState(address(indexToken), allocation, (allocation * 4) / 5);
        vm.stopPrank();
        _;
    }

    function testTradingHasBeenFacilitated() public facilitateTrading {
        // check the market exists
        MarketStructs.Market memory market =
            MarketHelper.getMarketFromIndexToken(address(marketStorage), address(indexToken));
        assertNotEq(market.market, address(0));
        assertNotEq(market.marketKey, bytes32(0));
        assertNotEq(market.indexToken, address(0));
        // check the market has the correct allocation
        uint256 alloc = marketStorage.marketAllocations(market.marketKey);
        uint256 maxOi = marketStorage.maxOpenInterests(market.marketKey);
        assertEq(alloc, DEPOSIT_AMOUNT / 2);
        assertEq(maxOi, ((DEPOSIT_AMOUNT / 2) * 4) / 5);
    }

    function testTradeRequestsOpenAsExpected() public facilitateTrading {
        // approve some currency
        vm.startPrank(USER);
        usdc.approve(address(requestRouter), DEPOSIT_AMOUNT);
        uint256 executionFee = tradeStorage.minExecutionFee();
        // try to create a trade request
        MarketStructs.PositionRequest memory _request = MarketStructs.PositionRequest(
            0,
            false,
            address(indexToken),
            USER,
            100e6, // 100 USDC
            1e18, // $1000 per token, should be = 1000 USDC (10x leverage)
            0,
            1000e30,
            0,
            true,
            true
        );
        requestRouter.createTradeRequest{value: executionFee}(_request, executionFee);
        vm.stopPrank();
        // check the trade request exists and has correct vals
        bytes32 _positionKey = TradeHelper.generateKey(_request);
        (,,, address user,,,,,,,) = tradeStorage.orders(false, _positionKey);
        assertEq(user, USER);
    }

    function testTradeRequestsCanBeExecutedByKeepers() public facilitateTrading {
        // create a trade request
        vm.startPrank(USER);
        usdc.approve(address(requestRouter), DEPOSIT_AMOUNT);
        uint256 executionFee = tradeStorage.minExecutionFee();
        // try to create a trade request
        MarketStructs.PositionRequest memory _request = MarketStructs.PositionRequest(
            0,
            false,
            address(indexToken),
            USER,
            100e6, // 100 USDC
            1e18, // $1000 per token, should be = 1000 USDC (10x leverage)
            0,
            1000e30,
            0.1e18, // 10% slippage
            true,
            true
        );
        requestRouter.createTradeRequest{value: executionFee}(_request, executionFee);
        vm.stopPrank();
        // attempt to execute
        vm.startPrank(OWNER);
        executor.executeTradeOrders(OWNER);
        vm.stopPrank();
    }

    function testPriceImpactCalculation() public facilitateTrading {
        MarketStructs.PositionRequest memory request = MarketStructs.PositionRequest(
            0,
            false,
            address(indexToken),
            USER,
            100e6, // 100 USDC
            1e18, // $1000 per token, should be = 1000 USDC (10x leverage)
            0,
            1000e30,
            0.1e18, // 10% slippage
            true,
            true
        );
        uint256 signedBlockPrice = 1000e30;
        address market = MarketHelper.getMarketFromIndexToken(address(marketStorage), address(indexToken)).market;
        int256 priceImpact = ImpactCalculator.calculatePriceImpact(
            market, address(marketStorage), address(dataOracle), address(priceOracle), request, signedBlockPrice
        );
        if (priceImpact >= 0) {
            console.log(uint256(priceImpact));
        } else {
            console.log(uint256(priceImpact * -1));
        }
    }

    function testExecutedTradesHaveTheCorrectParameters() public facilitateTrading {
        // create a trade request
        vm.startPrank(USER);
        usdc.approve(address(requestRouter), DEPOSIT_AMOUNT);
        uint256 executionFee = tradeStorage.minExecutionFee();
        // try to create a trade request
        MarketStructs.PositionRequest memory _request = MarketStructs.PositionRequest(
            0,
            false,
            address(indexToken),
            USER,
            100e6, // 100 USDC
            1e18, // $1000 per token, should be = 1000 USDC (10x leverage)
            0,
            1000e30,
            0.1e18, // 10% slippage
            true,
            true
        );
        requestRouter.createTradeRequest{value: executionFee}(_request, executionFee);
        vm.stopPrank();
        assertEq(address(tradeVault).balance, executionFee);
        // attempt to execute
        vm.startPrank(OWNER);
        bytes32 _positionKey = TradeHelper.generateKey(_request);
        executor.executeTradeOrder(_positionKey, OWNER, false);
        vm.stopPrank();
        (
            ,
            bytes32 market,
            address positionIndexToken,
            address user,
            uint256 collat,
            ,
            bool isLong,
            int256 realisedPnl,
            ,
            ,
            MarketStructs.PnLParams memory pnlParams,
            uint256 entryTimestamp
        ) = tradeStorage.openPositions(_positionKey);
        assertEq(market, MarketHelper.getMarketFromIndexToken(address(marketStorage), address(indexToken)).marketKey);
        assertEq(positionIndexToken, address(indexToken));
        assertEq(user, USER);
        assertGt(collat, 0);
        assertEq(isLong, true);
        assertEq(realisedPnl, 0);
        console.log(pnlParams.leverage);
        assertGt(pnlParams.leverage, 1);
        assertGt(pnlParams.weightedAvgEntryPrice, 0);
        assertEq(entryTimestamp, block.timestamp);
    }

    function testThePriceImpactOnALargeSizedTrade() public facilitateTrading {
        // Create a really large trade request
        vm.startPrank(USER);
        usdc.approve(address(requestRouter), LARGE_AMOUNT);
        uint256 executionFee = tradeStorage.minExecutionFee();
        // try to create a trade request
        MarketStructs.PositionRequest memory _request = MarketStructs.PositionRequest(
            0,
            false,
            address(indexToken),
            USER,
            1000000e6, // 1 mil USDC
            10000e18, // $1000 per token, should be = 10000000 USDC (10x leverage)
            0,
            1000e30,
            5e18, // 50% slippage
            true,
            true
        );
        requestRouter.createTradeRequest{value: executionFee}(_request, executionFee);
        vm.stopPrank();
        // Run the calculate price impact function on the request
        uint256 signedBlockPrice = 1000e30;
        address market = MarketHelper.getMarketFromIndexToken(address(marketStorage), address(indexToken)).market;
        int256 priceImpact = ImpactCalculator.calculatePriceImpact(
            market, address(marketStorage), address(dataOracle), address(priceOracle), _request, signedBlockPrice
        );
        // log the output
        if (priceImpact >= 0) {
            console.log(uint256(priceImpact));
        } else {
            console.log(uint256(priceImpact * -1));
        }
    }

    function testWeCanAddCollateralToAnExistingPosition() public facilitateTrading {}
}
