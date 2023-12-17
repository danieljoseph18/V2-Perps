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
import {PricingCalculator} from "../../../src/positions/PricingCalculator.sol";
import {ITradeStorage} from "../../../src/positions/interfaces/ITradeStorage.sol";

contract TestPriceImpact is Test {
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

    // test pnl calculations on constructed positions
    function testPnlCalculations() public facilitateTrading {
        bytes32 market = keccak256(abi.encodePacked(address(indexToken)));
        MarketStructs.Position memory position = MarketStructs.Position(
            0,
            market,
            address(indexToken),
            USER,
            100e18,
            1e18,
            true,
            0,
            MarketStructs.BorrowParams(0, 0, 0, 0),
            MarketStructs.FundingParams(0, 0, 0, 0, 0),
            MarketStructs.PnLParams(700e18, 1000e18, 1000),
            0
        );
        int256 pnl = PricingCalculator.calculatePnL(address(priceOracle), address(dataOracle), position);
        console.log("pnl: ", uint256(pnl));
    }
    // test net pnl calculations for entire markets

    function testNetPnlCalculationForEntireMarkets() public facilitateTrading {
        // open a few longs and shorts with varying impact to vary price
        vm.startPrank(USER);
        usdc.approve(address(requestRouter), LARGE_AMOUNT);
        uint256 executionFee = tradeStorage.minExecutionFee();
        MarketStructs.PositionRequest memory request = MarketStructs.PositionRequest(
            0,
            false,
            address(indexToken),
            USER,
            100e6, // 100 USDC
            1e18, // $1000 per token, should be = 1000 USDC (10x leverage)
            0,
            1000e18,
            0.1e18, // 10% slippage
            true,
            true
        );
        requestRouter.createTradeRequest{value: executionFee}(request, executionFee);
        MarketStructs.PositionRequest memory request2 = MarketStructs.PositionRequest(
            0,
            false,
            address(indexToken),
            USER,
            500e6, // 100 USDC
            5e18, // $1000 per token, should be = 1000 USDC (10x leverage)
            0,
            1000e18,
            0.1e18, // 10% slippage
            false,
            true
        );
        requestRouter.createTradeRequest{value: executionFee}(request2, executionFee);
        vm.stopPrank();
        vm.startPrank(OWNER);
        usdc.approve(address(requestRouter), LARGE_AMOUNT);
        MarketStructs.PositionRequest memory request3 = MarketStructs.PositionRequest(
            0,
            false,
            address(indexToken),
            OWNER,
            400e6, // 100 USDC
            4e18, // $1000 per token, should be = 1000 USDC (10x leverage)
            0,
            1000e18,
            0.1e18, // 10% slippage
            true,
            true
        );
        requestRouter.createTradeRequest{value: executionFee}(request3, executionFee);
        MarketStructs.PositionRequest memory request4 = MarketStructs.PositionRequest(
            0,
            false,
            address(indexToken),
            OWNER,
            2000e6, // 100 USDC
            20e18, // $1000 per token, should be = 1000 USDC (10x leverage)
            0,
            1000e18,
            0.1e18, // 10% slippage
            false,
            true
        );
        requestRouter.createTradeRequest{value: executionFee}(request4, executionFee);
        executor.executeTradeOrders(OWNER);
        vm.stopPrank();
        // check the net pnl
        address market = MarketHelper.getMarketFromIndexToken(address(marketStorage), address(indexToken)).market;
        int256 netPnl = PricingCalculator.getNetPnL(
            market, address(marketStorage), address(dataOracle), address(priceOracle), false
        );
        bool isNegative = netPnl < 0;
        if (isNegative) {
            console.log("Negative PNL: ", uint256(-netPnl));
        } else {
            console.log("Positive PNL: ", uint256(netPnl));
        }
    }
    // test weighted average entry price calculations

    function testWeightedAvgEntryCalc() public facilitateTrading {
        uint256 waep = PricingCalculator.calculateWeightedAverageEntryPrice(1000e18, 1000e18, 5000e18, 1250e18);
        assertEq(1.208333333333333333333e21, waep); // expected $1208.33
    }
}
