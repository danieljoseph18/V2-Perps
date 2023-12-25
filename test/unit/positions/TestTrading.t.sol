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
import {ITradeStorage} from "../../../src/positions/interfaces/ITradeStorage.sol";

contract TestTrading is Test {
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

// modifier facilitateTradingAndOpenTrade() {
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
//     // create a trade request
//     vm.startPrank(USER);
//     usdc.approve(address(requestRouter), LARGE_AMOUNT);
//     uint256 executionFee = tradeStorage.minExecutionFee();
//     MarketStructs.PositionRequest memory _request = MarketStructs.PositionRequest(
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
//     requestRouter.createTradeRequest{value: executionFee}(_request, executionFee);
//     vm.stopPrank();
//     // execute the trade request
//     vm.startPrank(OWNER);
//     executor.executeTradeOrders(OWNER);
//     vm.stopPrank();
//     _;
// }

// function testTradingHasBeenFacilitated() public facilitateTrading {
//     // check the market exists
//     MarketStructs.Market memory market =
//         MarketHelper.getMarketFromIndexToken(address(marketStorage), address(indexToken));
//     assertNotEq(market.market, address(0));
//     assertNotEq(market.marketKey, bytes32(0));
//     assertNotEq(market.indexToken, address(0));
//     // check the market has the correct allocation
//     uint256 alloc = marketStorage.marketAllocations(market.marketKey);
//     uint256 maxOi = marketStorage.maxOpenInterests(market.marketKey);
//     assertEq(alloc, INDEX_ALLOCATION);
//     assertEq(maxOi, (INDEX_ALLOCATION * 4) / 5);
// }

// function testTradeRequestsOpenAsExpected() public facilitateTrading {
//     // approve some currency
//     vm.startPrank(USER);
//     usdc.approve(address(requestRouter), DEPOSIT_AMOUNT);
//     uint256 executionFee = tradeStorage.minExecutionFee();
//     // try to create a trade request
//     MarketStructs.PositionRequest memory _request = MarketStructs.PositionRequest(
//         0,
//         false,
//         address(indexToken),
//         USER,
//         100e6, // 100 USDC
//         1e18, // $1000 per token, should be = 1000 USDC (10x leverage)
//         0,
//         1000e18,
//         0,
//         true,
//         true
//     );
//     requestRouter.createTradeRequest{value: executionFee}(_request, executionFee);
//     vm.stopPrank();
//     // check the trade request exists and has correct vals
//     bytes32 _positionKey = TradeHelper.generateKey(_request);
//     (,,, address user,,,,,,,) = tradeStorage.orders(false, _positionKey);
//     assertEq(user, USER);
// }

// function testTradeRequestsCanBeExecutedByKeepers() public facilitateTrading {
//     // create a trade request
//     vm.startPrank(USER);
//     usdc.approve(address(requestRouter), DEPOSIT_AMOUNT);
//     uint256 executionFee = tradeStorage.minExecutionFee();
//     // try to create a trade request
//     MarketStructs.PositionRequest memory _request = MarketStructs.PositionRequest(
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
//     requestRouter.createTradeRequest{value: executionFee}(_request, executionFee);
//     vm.stopPrank();
//     // attempt to execute
//     vm.startPrank(OWNER);
//     executor.executeTradeOrders(OWNER);
//     vm.stopPrank();
// }

// function testPriceImpactCalculation() public facilitateTrading {
//     MarketStructs.PositionRequest memory request = MarketStructs.PositionRequest(
//         0,
//         false, // is limit order
//         address(indexToken),
//         USER,
//         100e6, // 100 USDC collateral
//         10e18, // $1000 per token, should be = 1000 USDC position size (10x leverage)
//         0,
//         1000e18, // price $1000
//         0.1e18, // 10% slippage
//         true, // long
//         true // increase
//     );
//     uint256 signedBlockPrice = 1000e18;
//     address market = MarketHelper.getMarketFromIndexToken(address(marketStorage), address(indexToken)).market;
//     (uint256 longOI, uint256 shortOI, uint256 sizeDeltaUsd) = ImpactCalculator.getOpenInterestAndSizeDelta(
//         address(marketStorage), address(dataOracle), address(priceOracle), market, request, signedBlockPrice
//     );
//     console.log("Long OI: ", longOI);
//     console.log("Short OI: ", shortOI);
//     console.log("Size Delta: ", sizeDeltaUsd);
//     uint256 priceImpact = ImpactCalculator.calculatePriceImpact(
//         market, address(marketStorage), address(dataOracle), address(priceOracle), request, signedBlockPrice
//     );
//     console.log("Price Impact: ", priceImpact);
//     uint256 impactedPrice =
//         ImpactCalculator.applyPriceImpact(signedBlockPrice, priceImpact, request.isLong, request.isIncrease);
//     console.log("Impacted Price: ", impactedPrice);
//     ImpactCalculator.checkSlippage(impactedPrice, signedBlockPrice, request.maxSlippage);
// }

// function testExecutedTradesHaveTheCorrectParameters() public facilitateTrading {
//     // create a trade request
//     vm.startPrank(USER);
//     usdc.approve(address(requestRouter), DEPOSIT_AMOUNT);
//     uint256 executionFee = tradeStorage.minExecutionFee();
//     // try to create a trade request
//     MarketStructs.PositionRequest memory _request = MarketStructs.PositionRequest(
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
//     requestRouter.createTradeRequest{value: executionFee}(_request, executionFee);
//     vm.stopPrank();
//     assertEq(address(tradeVault).balance, executionFee);
//     // attempt to execute
//     vm.startPrank(OWNER);
//     bytes32 _positionKey = TradeHelper.generateKey(_request);
//     executor.executeTradeOrder(_positionKey, OWNER, false);
//     vm.stopPrank();
//     MarketStructs.Position memory position = ITradeStorage(address(tradeStorage)).openPositions(_positionKey);
//     assertEq(
//         position.market, MarketHelper.getMarketFromIndexToken(address(marketStorage), address(indexToken)).marketKey
//     );
//     assertEq(position.indexToken, address(indexToken));
//     assertEq(position.user, USER);
//     assertGt(position.collateralAmount, 0);
//     assertEq(position.isLong, true);
//     assertEq(position.realisedPnl, 0);
//     console.log(position.pnlParams.leverage);
//     assertGt(position.pnlParams.leverage, 1);
//     assertGt(position.pnlParams.weightedAvgEntryPrice, 0);
//     assertEq(position.entryTimestamp, block.timestamp);
// }

// function testThePriceImpactOnALargeSizedTrade() public facilitateTrading {
//     // Create a really large trade request
//     vm.startPrank(USER);
//     usdc.approve(address(requestRouter), LARGE_AMOUNT);
//     uint256 executionFee = tradeStorage.minExecutionFee();
//     // try to create a trade request
//     MarketStructs.PositionRequest memory request = MarketStructs.PositionRequest(
//         0,
//         false,
//         address(indexToken),
//         USER,
//         10000000e6, // 1 mil USDC
//         100000e18, // $1000 per token, should be = 10000000 USDC (10x leverage)
//         0,
//         1000e18,
//         5e18, // 50% slippage
//         true,
//         true
//     );
//     requestRouter.createTradeRequest{value: executionFee}(request, executionFee);
//     vm.stopPrank();
//     // Run the calculate price impact function on the request
//     uint256 signedBlockPrice = 1000e18;
//     address market = MarketHelper.getMarketFromIndexToken(address(marketStorage), address(indexToken)).market;
//     uint256 priceImpact = ImpactCalculator.calculatePriceImpact(
//         market, address(marketStorage), address(dataOracle), address(priceOracle), request, signedBlockPrice
//     );
//     uint256 impactedPrice =
//         ImpactCalculator.applyPriceImpact(signedBlockPrice, priceImpact, request.isLong, request.isIncrease);
//     console.log(impactedPrice);
//     ImpactCalculator.checkSlippage(impactedPrice, signedBlockPrice, request.maxSlippage);
// }

// function testOpenInterestValues() public facilitateTrading {
//     // Create a really large trade request
//     vm.startPrank(USER);
//     usdc.approve(address(requestRouter), LARGE_AMOUNT);
//     uint256 executionFee = tradeStorage.minExecutionFee();
//     // try to create a trade request
//     MarketStructs.PositionRequest memory _request = MarketStructs.PositionRequest(
//         0,
//         false,
//         address(indexToken),
//         USER,
//         1_000_000e6, // 1 mil USDC
//         10_000e18, // $1000 per token, should be = 10,000,000 USDC (10x leverage)
//         0,
//         1000e18,
//         5e18, // 50% slippage
//         true,
//         true
//     );
//     requestRouter.createTradeRequest{value: executionFee}(_request, executionFee);
//     vm.stopPrank();
//     vm.prank(OWNER);
//     executor.executeTradeOrders(OWNER);
//     uint256 longOI = MarketHelper.getIndexOpenInterestUSD(
//         address(marketStorage), address(dataOracle), address(priceOracle), address(indexToken), true
//     );
//     uint256 shortOI = MarketHelper.getIndexOpenInterestUSD(
//         address(marketStorage), address(dataOracle), address(priceOracle), address(indexToken), false
//     );
//     console.log("Long OI: ", longOI);
//     console.log("Short OI: ", shortOI);
// }

// function testWeCanAddCollateralToAnExistingPosition() public facilitateTrading {
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
//     vm.startPrank(USER);
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
//     requestRouter.createTradeRequest{value: executionFee}(collateralRequest, executionFee);
//     vm.stopPrank();
//     // execute the collateral edit request
//     vm.startPrank(OWNER);
//     executor.executeTradeOrders(OWNER);
//     vm.stopPrank();
//     // // check values
//     bytes32 _positionKey = TradeHelper.generateKey(request);
//     MarketStructs.Position memory position = ITradeStorage(address(tradeStorage)).openPositions(_positionKey);
//     assertGt(position.collateralAmount, 100e18);
//     console.log(position.collateralAmount);
// }

// function testWeCanIncreaseAnExistingPosition() public facilitateTrading {
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
//     bytes32 _positionKey = TradeHelper.generateKey(request);
//     MarketStructs.Position memory position = ITradeStorage(address(tradeStorage)).openPositions(_positionKey);
//     // create another trade request
//     vm.startPrank(USER);
//     MarketStructs.PositionRequest memory request2 = MarketStructs.PositionRequest(
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
//     requestRouter.createTradeRequest{value: executionFee}(request2, executionFee);
//     vm.stopPrank();
//     // execute the other trade request
//     vm.startPrank(OWNER);
//     executor.executeTradeOrders(OWNER);
//     vm.stopPrank();
//     // check the positions have stacked
//     MarketStructs.Position memory positionAfter = ITradeStorage(address(tradeStorage)).openPositions(_positionKey);
//     // check values are as expected
//     assertGt(positionAfter.collateralAmount, position.collateralAmount);
//     assertGt(positionAfter.positionSize, position.positionSize);
// }

// function testWeCanFullyCloseOutAPosition() public facilitateTrading {
//     // create trade request
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
//     // execute trade request
//     vm.prank(OWNER);
//     executor.executeTradeOrders(OWNER);
//     // create close request
//     bytes32 _positionKey = TradeHelper.generateKey(request);
//     console.log("WUSDC Bal: ", wusdc.balanceOf(address(tradeVault)));
//     MarketStructs.Position memory positionBefore = ITradeStorage(address(tradeStorage)).openPositions(_positionKey);
//     assertEq(wusdc.balanceOf(address(tradeVault)), positionBefore.collateralAmount);
//     vm.prank(USER);
//     requestRouter.createCloseRequest{value: executionFee}(_positionKey, 0, 0.1e18, false, executionFee);
//     // execute close request
//     vm.prank(OWNER);
//     executor.executeTradeOrders(OWNER);
//     // ensure trade is wiped from storage
//     MarketStructs.Position memory positionAfter = ITradeStorage(address(tradeStorage)).openPositions(_positionKey);
//     assertEq(positionAfter.user, address(0));
// }

// function testWeCanPartiallyCloseOutAPosition() public facilitateTradingAndOpenTrade {
//     uint256 executionFee = tradeStorage.minExecutionFee();
//     // create a partial close request
//     MarketStructs.PositionRequest memory decreaseRequest = MarketStructs.PositionRequest({
//         requestIndex: 0,
//         isLimit: false,
//         indexToken: address(indexToken),
//         user: USER,
//         collateralDelta: 50e6,
//         sizeDelta: 5e17,
//         requestBlock: 0,
//         orderPrice: 0,
//         maxSlippage: 0.1e18, // 10% slippage
//         isLong: true,
//         isIncrease: false
//     });
//     bytes32 _positionKey = TradeHelper.generateKey(decreaseRequest);
//     MarketStructs.Position memory positionBefore = ITradeStorage(address(tradeStorage)).openPositions(_positionKey);
//     console.log("Before Collat: ", positionBefore.collateralAmount);
//     console.log("Before Size: ", positionBefore.positionSize);
//     vm.prank(USER);
//     requestRouter.createTradeRequest{value: executionFee}(decreaseRequest, executionFee);
//     // execute the partial close request
//     vm.prank(OWNER);
//     executor.executeTradeOrders(OWNER);
//     // ensure the position has partially closed
//     MarketStructs.Position memory positionAfter = ITradeStorage(address(tradeStorage)).openPositions(_positionKey);
//     console.log("End Collat: ", positionAfter.collateralAmount);
//     console.log("End Size: ", positionAfter.positionSize);
// }

// function testOpeningTwoPositionsAtOnceIsntProblematic() public facilitateTrading {
//     // create an open request
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
//     // create another open request
//     vm.startPrank(OWNER);
//     usdc.approve(address(requestRouter), LARGE_AMOUNT);
//     MarketStructs.PositionRequest memory request2 = MarketStructs.PositionRequest(
//         0,
//         false,
//         address(indexToken),
//         OWNER,
//         100e6, // 100 USDC
//         1e18, // $1000 per token, should be = 1000 USDC (10x leverage)
//         0,
//         1000e18,
//         0.1e18, // 10% slippage
//         true,
//         true
//     );
//     requestRouter.createTradeRequest{value: executionFee}(request2, executionFee);
//     vm.stopPrank();
//     // check indices are different
//     bytes32 positionKey = TradeHelper.generateKey(request);
//     bytes32 positionKey2 = TradeHelper.generateKey(request2);
//     bytes32 key1 = tradeStorage.orderKeys(false, 0);
//     bytes32 key2 = tradeStorage.orderKeys(false, 1);
//     assertEq(key1, positionKey);
//     assertEq(key2, positionKey2);
//     // fulfill both open requests in the same block
//     vm.prank(OWNER);
//     executor.executeTradeOrders(OWNER);
//     // check positions are separate
//     MarketStructs.Position memory userPosition = ITradeStorage(address(tradeStorage)).openPositions(positionKey);
//     MarketStructs.Position memory ownerPosition = ITradeStorage(address(tradeStorage)).openPositions(positionKey2);
//     assertEq(userPosition.user, USER);
//     assertEq(ownerPosition.user, OWNER);
// }

// function testRequestFrontPointerWorksAsExpected() public facilitateTrading {
//     // open a long and a short request from user
//     vm.startPrank(USER);
//     usdc.approve(address(requestRouter), LARGE_AMOUNT);
//     uint256 executionFee = tradeStorage.minExecutionFee();
//     MarketStructs.PositionRequest memory userLong = MarketStructs.PositionRequest(
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
//     requestRouter.createTradeRequest{value: executionFee}(userLong, executionFee);
//     MarketStructs.PositionRequest memory userShort = MarketStructs.PositionRequest(
//         0,
//         false,
//         address(indexToken),
//         USER,
//         100e6, // 100 USDC
//         1e18, // $1000 per token, should be = 1000 USDC (10x leverage)
//         0,
//         1000e18,
//         0.1e18, // 10% slippage
//         false,
//         true
//     );
//     requestRouter.createTradeRequest{value: executionFee}(userShort, executionFee);
//     vm.stopPrank();
//     // open a long and a short request from owner
//     vm.startPrank(OWNER);
//     usdc.approve(address(requestRouter), LARGE_AMOUNT);
//     MarketStructs.PositionRequest memory ownerLong = MarketStructs.PositionRequest(
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
//     requestRouter.createTradeRequest{value: executionFee}(ownerLong, executionFee);
//     MarketStructs.PositionRequest memory ownerShort = MarketStructs.PositionRequest(
//         0,
//         false,
//         address(indexToken),
//         USER,
//         100e6, // 100 USDC
//         1e18, // $1000 per token, should be = 1000 USDC (10x leverage)
//         0,
//         1000e18,
//         0.1e18, // 10% slippage
//         false,
//         true
//     );
//     requestRouter.createTradeRequest{value: executionFee}(ownerShort, executionFee);
//     vm.stopPrank();
//     // execute all requests at once
//     vm.prank(OWNER);
//     executor.executeTradeOrders(OWNER);
//     // check the front pointer is correct
//     assertEq(tradeStorage.orderKeysStartIndex(), 4);
// }
}
