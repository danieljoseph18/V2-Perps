// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.22;

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

contract TestPriceImpact is Test {
// RoleStorage roleStorage;
// GlobalMarketConfig globalMarketConfig;
// LiquidityVault liquidityVault;
// MarketFactory marketFactory;
// MarketStorage marketStorage;
// MarketToken marketToken;
// StateUpdater stateUpdater;
// IMockPriceOracle priceOracle;
// IMockUSDC usdc;
// DataOracle dataOracle;
// Executor executor;
// Liquidator liquidator;
// RequestRouter requestRouter;
// TradeStorage tradeStorage;
// TradeVault tradeVault;
// WUSDC wusdc;
// MarketToken indexToken;

// address public OWNER;
// address public USER = makeAddr("user");

// uint256 public constant LARGE_AMOUNT = 1e18;
// uint256 public constant DEPOSIT_AMOUNT = 100_000_000_000000;
// uint256 public constant INDEX_ALLOCATION = 1e24;
// uint256 public constant CONVERSION_RATE = 1e12;

// function setUp() public {
//     DeployV2 deploy = new DeployV2();
//     DeployV2.Contracts memory contracts = deploy.run();
//     roleStorage = contracts.roleStorage;
//     globalMarketConfig = contracts.globalMarketConfig;
//     liquidityVault = contracts.liquidityVault;
//     marketFactory = contracts.marketFactory;
//     marketStorage = contracts.marketStorage;
//     marketToken = contracts.marketToken;
//     stateUpdater = contracts.stateUpdater;
//     priceOracle = contracts.priceOracle;
//     usdc = contracts.usdc;
//     dataOracle = contracts.dataOracle;
//     executor = contracts.executor;
//     liquidator = contracts.liquidator;
//     requestRouter = contracts.requestRouter;
//     tradeStorage = contracts.tradeStorage;
//     tradeVault = contracts.tradeVault;
//     wusdc = contracts.wusdc;
//     OWNER = contracts.owner;
// }

// receive() external payable {}

// modifier facilitateTrading() {
//     vm.deal(OWNER, LARGE_AMOUNT);
//     vm.deal(USER, LARGE_AMOUNT);
//     // add liquidity
//     usdc.mint(OWNER, LARGE_AMOUNT);
//     usdc.mint(USER, LARGE_AMOUNT);
//     vm.startPrank(OWNER);
//     usdc.approve(address(liquidityVault), LARGE_AMOUNT);
//     liquidityVault.addLiquidity(DEPOSIT_AMOUNT);
//     // create a new index token to trade
//     indexToken = new MarketToken("Bitcoin", "BTC", address(roleStorage));
//     // create a new market and provide an allocation
//     address _market = marketFactory.createMarket(address(indexToken), makeAddr("priceFeed"), 1e18);
//     uint256 allocation = INDEX_ALLOCATION;
//     stateUpdater.updateState(address(indexToken), allocation, (allocation * 4) / 5);
//     vm.stopPrank();
//     _;
// }

// // test higher impact is charged on larger trades
// function testHigherPriceImpactIsChargedOnLargeTrades() public facilitateTrading {
//     vm.startPrank(USER);
//     usdc.approve(address(requestRouter), LARGE_AMOUNT);
//     MarketStructs.PositionRequest memory userRequestLarge = MarketStructs.PositionRequest(
//         0,
//         false,
//         address(indexToken),
//         USER,
//         1_000_000e6,
//         10_000e18,
//         0,
//         1000e18,
//         0.5e18, // 10% slippage
//         true,
//         true
//     );
//     vm.stopPrank();
//     address market = MarketHelper.getMarketFromIndexToken(address(marketStorage), address(indexToken)).market;
//     uint256 impact = ImpactCalculator.calculatePriceImpact(
//         market, address(marketStorage), address(dataOracle), address(priceOracle), userRequestLarge, 1000e18
//     );
//     console.log("Large Impact: ", impact);
//     MarketStructs.PositionRequest memory userRequestSmall = MarketStructs.PositionRequest(
//         0,
//         false,
//         address(indexToken),
//         USER,
//         100e6,
//         1e18,
//         0,
//         1000e18,
//         0.5e18, // 10% slippage
//         true,
//         true
//     );
//     uint256 smallImpact = ImpactCalculator.calculatePriceImpact(
//         market, address(marketStorage), address(dataOracle), address(priceOracle), userRequestSmall, 1000e18
//     );
//     console.log("Small Impact: ", smallImpact);
//     assertGt(impact, smallImpact);
// }

// // test reasonable impact on smaller trades
// function testReasonableImpactOnSmallerTrades() public facilitateTrading {
//     MarketStructs.PositionRequest memory userRequest = MarketStructs.PositionRequest(
//         0,
//         false,
//         address(indexToken),
//         USER,
//         100e6,
//         1e18,
//         0,
//         1000e18,
//         0.003e18, // 0.3% slippage
//         true,
//         true
//     );
//     address market = MarketHelper.getMarketFromIndexToken(address(marketStorage), address(indexToken)).market;
//     uint256 impactedPrice = ImpactCalculator.executePriceImpact(
//         market, address(marketStorage), address(dataOracle), address(priceOracle), userRequest, 1000e18
//     );
//     console.log("Impacted Price: ", impactedPrice);
// }

// function testLargeImpactOnLargeTrades() public facilitateTrading {
//     MarketStructs.PositionRequest memory userRequest = MarketStructs.PositionRequest(
//         0,
//         false,
//         address(indexToken),
//         USER,
//         1_000_000e6,
//         10_000e18,
//         0,
//         1000e18,
//         0.5e18, // 10% slippage
//         true,
//         true
//     );
//     address market = MarketHelper.getMarketFromIndexToken(address(marketStorage), address(indexToken)).market;
//     uint256 impactedPrice = ImpactCalculator.executePriceImpact(
//         market, address(marketStorage), address(dataOracle), address(priceOracle), userRequest, 1000e18
//     );
//     console.log("Impacted Price: ", impactedPrice);
// }

// // test impact is 0 on trades that don't change the position
// function testImpactIsZeroOnTradesThatDontChangeThePosition() public facilitateTrading {
//     // create a trade request
//     vm.startPrank(USER);
//     usdc.approve(address(requestRouter), LARGE_AMOUNT);
//     uint256 executionFee = tradeStorage.minExecutionFee();
//     MarketStructs.PositionRequest memory request = MarketStructs.PositionRequest(
//         0,
//         false,
//         address(indexToken),
//         USER,
//         100e6, // 100 USDC
//         1e18, // $1000 per token, should be = 1000 USDC (10x leverage)
//         0,
//         1000e18,
//         0.1e18, // 10% slippage
//         true,
//         true
//     );
//     requestRouter.createTradeRequest{value: executionFee}(request, executionFee);
//     vm.stopPrank();
//     // execute the trade request
//     vm.startPrank(OWNER);
//     executor.executeTradeOrders(OWNER);
//     vm.stopPrank();
//     // create a collateral edit request
//     MarketStructs.PositionRequest memory collateralRequest = MarketStructs.PositionRequest(
//         0,
//         false,
//         address(indexToken),
//         USER,
//         100e6, // 100 USDC
//         0, // 0 size delta
//         0,
//         1000e18,
//         0.1e18, // 10% slippage
//         true,
//         true
//     );
//     address market = MarketHelper.getMarketFromIndexToken(address(marketStorage), address(indexToken)).market;
//     uint256 impactedPrice = ImpactCalculator.executePriceImpact(
//         market, address(marketStorage), address(dataOracle), address(priceOracle), collateralRequest, 1000e18
//     );
//     console.log("Impacted Price: ", impactedPrice);
//     assertEq(impactedPrice, 1000e18);
// }

// function testCheckSlippageAccuratelyDeterminesPriceSlippage() public facilitateTrading {
//     uint256 impactedPrice = 500e18; // slippage 50%
//     uint256 signedPrice = 1000e18;
//     ImpactCalculator.checkSlippage(impactedPrice, signedPrice, 0.55e18); // 55%
//     ImpactCalculator.checkSlippage(impactedPrice, signedPrice, 0.5e18); // 50%
//     vm.expectRevert();
//     ImpactCalculator.checkSlippage(impactedPrice, signedPrice, 0.499e18); // 49.9%
//     vm.expectRevert();
//     ImpactCalculator.checkSlippage(impactedPrice, signedPrice, 0.1e18); // 10%
// }

// function testApplyPriceImpactCorrectlyAppliesImpactToPrices() public facilitateTrading {
//     uint256 signedBlockPrice = 1000e18;
//     uint256 priceImpactUsd = 700e18;
//     uint256 impactedPrice = ImpactCalculator.applyPriceImpact(signedBlockPrice, priceImpactUsd, true, true);
//     assertEq(impactedPrice, 1700e18);
//     impactedPrice = ImpactCalculator.applyPriceImpact(signedBlockPrice, priceImpactUsd, true, false);
//     assertEq(impactedPrice, 300e18);
// }
}
