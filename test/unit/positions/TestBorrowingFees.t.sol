// // SPDX-License-Identifier: BUSL-1.1
// pragma solidity 0.8.23;

// import {Test, console} from "forge-std/Test.sol";
// import {DeployV2} from "../../../script/DeployV2.s.sol";
// import {RoleStorage} from "../../../src/access/RoleStorage.sol";
// import {GlobalMarketConfig} from "../../../src/markets/GlobalMarketConfig.sol";
// import {LiquidityVault} from "../../../src/markets/LiquidityVault.sol";
// import {MarketMaker} from "../../../src/markets/MarketMaker.sol";
// import {MarketToken} from "../../../src/markets/MarketToken.sol";
// import {StateUpdater} from "../../../src/markets/StateUpdater.sol";
// import {IMockPriceOracle} from "../../mocks/interfaces/IMockPriceOracle.sol";
// import {IMockUSDC} from "../../mocks/interfaces/IMockUSDC.sol";
// import {DataOracle} from "../../../src/oracle/DataOracle.sol";
// import {Executor} from "../../../src/positions/Executor.sol";
// import {Liquidator} from "../../../src/positions/Liquidator.sol";
// import {RequestRouter} from "../../../src/positions/RequestRouter.sol";
// import {TradeStorage} from "../../../src/positions/TradeStorage.sol";
// import {TradeVault} from "../../../src/positions/TradeVault.sol";
// import {USDE} from "../../../src/token/USDE.sol";
// import {Roles} from "../../../src/access/Roles.sol";
// import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
// import {TradeHelper} from "../../../src/positions/TradeHelper.sol";
// import {MarketHelper} from "../../../src/markets/MarketHelper.sol";
// import {PriceImpact} from "../../../src/libraries/PriceImpact.sol";
// import {Borrowing} from "../../../src/libraries/Borrowing.sol";
// import {Funding} from "../../../src/libraries/Funding.sol";
// import {Pricing} from "../../../src/libraries/Pricing.sol";
// import {ITradeStorage} from "../../../src/positions/interfaces/ITradeStorage.sol";

// contract TestBorrowing is Test {
// // RoleStorage roleStorage;
// // GlobalMarketConfig globalMarketConfig;
// // LiquidityVault liquidityVault;
// // MarketFactory marketFactory;
// // MarketMaker marketMaker;
// // MarketToken marketToken;
// // StateUpdater stateUpdater;
// // IMockPriceOracle priceOracle;
// // IMockUSDC usdc;
// // DataOracle dataOracle;
// // Executor executor;
// // Liquidator liquidator;
// // RequestRouter requestRouter;
// // TradeStorage tradeStorage;
// // TradeVault tradeVault;
// // WUSDC wusdc;
// // MarketToken indexToken;

// // address public OWNER;
// // address public USER = makeAddr("user");

// // uint256 public constant LARGE_AMOUNT = 1e18;
// // uint256 public constant DEPOSIT_AMOUNT = 100_000_000_000000;
// // uint256 public constant INDEX_ALLOCATION = 1e24;
// // uint256 public constant CONVERSION_RATE = 1e12;

// // function setUp() public {
// //     DeployV2 deploy = new DeployV2();
// //     DeployV2.Contracts memory contracts = deploy.run();
// //     roleStorage = contracts.roleStorage;
// //     globalMarketConfig = contracts.globalMarketConfig;
// //     liquidityVault = contracts.liquidityVault;
// //     marketFactory = contracts.marketFactory;
// //     marketMaker = contracts.marketMaker;
// //     marketToken = contracts.marketToken;
// //     stateUpdater = contracts.stateUpdater;
// //     priceOracle = contracts.priceOracle;
// //     usdc = contracts.usdc;
// //     dataOracle = contracts.dataOracle;
// //     executor = contracts.executor;
// //     liquidator = contracts.liquidator;
// //     requestRouter = contracts.requestRouter;
// //     tradeStorage = contracts.tradeStorage;
// //     tradeVault = contracts.tradeVault;
// //     wusdc = contracts.wusdc;
// //     OWNER = contracts.owner;
// // }

// // receive() external payable {}

// // modifier facilitateTrading() {
// //     vm.deal(OWNER, LARGE_AMOUNT);
// //     vm.deal(USER, LARGE_AMOUNT);
// //     // add liquidity
// //     usdc.mint(OWNER, LARGE_AMOUNT);
// //     usdc.mint(USER, LARGE_AMOUNT);
// //     vm.startPrank(OWNER);
// //     usdc.approve(address(liquidityVault), LARGE_AMOUNT);
// //     liquidityVault.addLiquidity(DEPOSIT_AMOUNT);
// //     // create a new index token to trade
// //     indexToken = new MarketToken("Bitcoin", "BTC", address(roleStorage));
// //     // create a new market and provide an allocation
// //     address _market = marketFactory.createMarket(address(indexToken), makeAddr("priceFeed"), 1e18);
// //     uint256 allocation = INDEX_ALLOCATION;
// //     stateUpdater.updateState(address(indexToken), allocation, (allocation * 4) / 5);
// //     vm.stopPrank();
// //     _;
// // }
// // /**
// //  * struct Trade {
// //  *     address indexToken;
// //  *     uint256 collateralDelta;
// //  *     uint256 sizeDelta;
// //  *     uint256 orderPrice;
// //  *     uint256 maxSlippage;
// //  *     uint256 executionFee;
// //  *     bool isLong;
// //  *     bool isLimit;
// //  *     bool isIncrease;
// //  * }
// //  */

// // // test borrowing fees are charged correctly on a regular position
// // function testBorrowingFeeCalculation() public facilitateTrading {
// //     // create a request long and short (long larger)
// //     vm.startPrank(USER);
// //     usdc.approve(address(requestRouter), LARGE_AMOUNT);
// //     uint256 executionFee = tradeStorage.minExecutionFee();
// //     Types.Trade memory userRequest = Types.Trade(
// //         address(indexToken),
// //         200e6,
// //         2e18,
// //         1000e18,
// //         0.5e18, // 50% slippage
// //         executionFee,
// //         true,
// //         false,
// //         true
// //     );
// //     requestRouter.createTradeRequest{value: executionFee}(userRequest);
// //     Types.Trade memory userRequest2 = Types.Trade(
// //         address(indexToken),
// //         100e6,
// //         1e18,
// //         1000e18,
// //         0.5e18, // 50% slippage
// //         executionFee,
// //         false,
// //         true,
// //         true
// //     );
// //     requestRouter.createTradeRequest{value: executionFee}(userRequest2);
// //     vm.stopPrank();
// //     // execute the requests
// //     vm.prank(OWNER);
// //     executor.executeTradeOrders(OWNER);
// //     // pass some time
// //     vm.warp(block.timestamp + 1 days);
// //     vm.roll(block.number + 1);
// //     bytes32 positionKey1 = keccak256(abi.encode(userRequest.indexToken, USER, userRequest.isLong));
// //     Types.Position memory userPositionLong =
// //         ITradeStorage(address(tradeStorage)).openPositions(positionKey1);
// //     bytes32 positionKey2 = keccak256(abi.encode(userRequest2.indexToken, USER, userRequest2.isLong));
// //     Types.Position memory userPositionShort =
// //         ITradeStorage(address(tradeStorage)).openPositions(positionKey2);
// //     // check the borrowing fee on the long and short
// //     address market = MarketHelper.getMarketFromIndexToken(address(marketMaker), address(indexToken)).market;
// //     uint256 longBorrowingFee = Borrowing.getBorrowingFees(market, userPositionLong);
// //     uint256 shortBorrowingFee = Borrowing.getBorrowingFees(market, userPositionShort);
// //     console.log("Long Borrow Fee: ", longBorrowingFee);
// //     console.log("Short Borrow Fee: ", shortBorrowingFee);
// // }

// // // test borrowing fees are correctly paid to LPs contract on close
// // function testBorrowingFeesAreAccumulatedOnPositionClose() public facilitateTrading {
// //     // open a trade
// //     vm.startPrank(USER);
// //     usdc.approve(address(requestRouter), LARGE_AMOUNT);
// //     uint256 executionFee = tradeStorage.minExecutionFee();
// //     Types.Trade memory userRequest = Types.Trade(
// //         address(indexToken),
// //         200e6,
// //         2e18,
// //         1000e18,
// //         0.5e18, // 50% slippage
// //         executionFee,
// //         true,
// //         false,
// //         true
// //     );
// //     requestRouter.createTradeRequest{value: executionFee}(userRequest);
// //     vm.stopPrank();
// //     // execute trade
// //     vm.prank(OWNER);
// //     executor.executeTradeOrders(OWNER);
// //     // pass some time
// //     vm.warp(block.timestamp + 1 days);
// //     vm.roll(block.number + 1);
// //     // check fees greater than 0
// //     bytes32 positionKey = keccak256(abi.encode(userRequest.indexToken, USER, userRequest.isLong));
// //     Types.Position memory userPosition = ITradeStorage(address(tradeStorage)).openPositions(positionKey);
// //     address market = MarketHelper.getMarketFromIndexToken(address(marketMaker), address(indexToken)).market;
// //     uint256 borrowingFee = Borrowing.getBorrowingFees(market, userPosition);
// //     assertGt(borrowingFee, 0);
// //     // close trade
// //     Types.Trade memory closeRequest = Types.Trade(
// //         address(indexToken),
// //         200e6,
// //         2e18,
// //         1000e18,
// //         0.5e18, // 50% slippage
// //         executionFee,
// //         true,
// //         false,
// //         false
// //     );
// //     vm.prank(USER);
// //     requestRouter.createTradeRequest{value: executionFee}(closeRequest);
// //     uint256 accumulatedFeesBefore = liquidityVault.accumulatedFees();
// //     vm.prank(OWNER);
// //     executor.executeTradeOrders(OWNER);
// //     // check accumulated fees = fees
// //     uint256 accumulatedFeesAfter = liquidityVault.accumulatedFees();
// //     assertGt(accumulatedFeesAfter, accumulatedFeesBefore);
// // }

// // // test same but on decrease
// // function testBorrowingFeesAreAccumulatedOnPositionDecreases() public facilitateTrading {
// //     // open a trade
// //     vm.startPrank(USER);
// //     usdc.approve(address(requestRouter), LARGE_AMOUNT);
// //     uint256 executionFee = tradeStorage.minExecutionFee();
// //     Types.Trade memory userRequest = Types.Trade(
// //         address(indexToken),
// //         200e6,
// //         2e18,
// //         1000e18,
// //         0.5e18, // 50% slippage
// //         executionFee,
// //         true,
// //         false,
// //         true
// //     );
// //     requestRouter.createTradeRequest{value: executionFee}(userRequest);
// //     vm.stopPrank();
// //     // execute trade
// //     vm.prank(OWNER);
// //     executor.executeTradeOrders(OWNER);
// //     // pass some time
// //     vm.warp(block.timestamp + 1 days);
// //     vm.roll(block.number + 1);
// //     // check fees greater than 0
// //     bytes32 positionKey = TradeHelper.generatePositionKey(userRequest);
// //     Types.Position memory userPosition = ITradeStorage(address(tradeStorage)).openPositions(positionKey);
// //     address market = MarketHelper.getMarketFromIndexToken(address(marketMaker), address(indexToken)).market;
// //     uint256 borrowingFee = Borrowing.getBorrowingFees(market, userPosition);
// //     assertGt(borrowingFee, 0);
// //     // decrease trade
// //     Types.PositionRequest memory userDecrease = Types.PositionRequest(
// //         0,
// //         false,
// //         address(indexToken),
// //         USER,
// //         100e6,
// //         1e18,
// //         0,
// //         1000e18,
// //         0.5e18, // 50% slippage
// //         true,
// //         false
// //     );
// //     vm.prank(USER);
// //     requestRouter.createTradeRequest{value: executionFee}(userDecrease, executionFee);
// //     uint256 accumulatedFeesBefore = liquidityVault.accumulatedFees();
// //     vm.prank(OWNER);
// //     executor.executeTradeOrders(OWNER);
// //     // check accumulated fees = fees
// //     uint256 accumulatedFeesAfter = liquidityVault.accumulatedFees();
// //     assertGt(accumulatedFeesAfter, accumulatedFeesBefore);
// //     // check fees owed on position
// //     Types.Position memory userPositionAfter =
// //         ITradeStorage(address(tradeStorage)).openPositions(positionKey);
// //     console.log("Fees Owed: ", userPositionAfter.borrowParams.feesOwed);
// // }

// // function testFeeCalculationsForPartialPositionEdits() public facilitateTrading {
// //     // open a trade
// //     vm.startPrank(USER);
// //     usdc.approve(address(requestRouter), LARGE_AMOUNT);
// //     uint256 executionFee = tradeStorage.minExecutionFee();
// //     Types.PositionRequest memory userRequest = Types.PositionRequest(
// //         0,
// //         false,
// //         address(indexToken),
// //         USER,
// //         200e6,
// //         2e18,
// //         0,
// //         1000e18,
// //         0.5e18, // 50% slippage
// //         true,
// //         true
// //     );
// //     requestRouter.createTradeRequest{value: executionFee}(userRequest, executionFee);
// //     vm.stopPrank();
// //     // execute trade
// //     vm.prank(OWNER);
// //     executor.executeTradeOrders(OWNER);
// //     // pass some time
// //     vm.warp(block.timestamp + 1 days);
// //     vm.roll(block.number + 1);
// //     // check fees greater than 0
// //     bytes32 positionKey = TradeHelper.generateKey(userRequest);
// //     Types.Position memory userPosition = ITradeStorage(address(tradeStorage)).openPositions(positionKey);
// //     address market = MarketHelper.getMarketFromIndexToken(address(marketMaker), address(indexToken)).market;
// //     uint256 quarterClose = Borrowing.calculateBorrowingFee(market, userPosition, 0.25e18);
// //     uint256 halfClose = Borrowing.calculateBorrowingFee(market, userPosition, 0.5e18);
// //     uint256 threeQuarterClose = Borrowing.calculateBorrowingFee(market, userPosition, 0.75e18);
// //     console.log("Quarter Close: ", quarterClose);
// //     console.log("Half Close: ", halfClose);
// //     console.log("Three Quarter Close: ", threeQuarterClose);
// // }
// }
