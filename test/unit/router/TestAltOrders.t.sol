// // SPDX-License-Identifier: MIT
// pragma solidity 0.8.23;

// import {Test, console, console2} from "forge-std/Test.sol";
// import {Deploy} from "../../../script/Deploy.s.sol";
// import {RoleStorage} from "../../../src/access/RoleStorage.sol";
// import {Market, IMarket, IMarketToken} from "../../../src/markets/Market.sol";
// import {MarketFactory, IMarketFactory} from "../../../src/markets/MarketFactory.sol";
// import {IPriceFeed} from "../../../src/oracle/interfaces/IPriceFeed.sol";
// import {TradeStorage, ITradeStorage} from "../../../src/positions/TradeStorage.sol";
// import {ReferralStorage} from "../../../src/referrals/ReferralStorage.sol";
// import {PositionManager} from "../../../src/router/PositionManager.sol";
// import {Router} from "../../../src/router/Router.sol";
// import {WETH} from "../../../src/tokens/WETH.sol";
// import {Oracle} from "../../../src/oracle/Oracle.sol";
// import {MockUSDC} from "../../mocks/MockUSDC.sol";
// import {Position} from "../../../src/positions/Position.sol";
// import {MarketUtils} from "../../../src/markets/MarketUtils.sol";
// import {RewardTracker} from "../../../src/rewards/RewardTracker.sol";
// import {LiquidityLocker} from "../../../src/rewards/LiquidityLocker.sol";
// import {FeeDistributor} from "../../../src/rewards/FeeDistributor.sol";
// import {TransferStakedTokens} from "../../../src/rewards/TransferStakedTokens.sol";
// import {MockPriceFeed} from "../../mocks/MockPriceFeed.sol";
// import {MathUtils} from "../../../src/libraries/MathUtils.sol";

// contract TestAltOrders is Test {
//     using MathUtils for uint256;

//     RoleStorage roleStorage;

//     MarketFactory marketFactory;
//     MockPriceFeed priceFeed; // Deployed in Helper Config
//     ITradeStorage tradeStorage;
//     ReferralStorage referralStorage;
//     PositionManager positionManager;
//     Router router;
//     address OWNER;
//     Market market;
//     FeeDistributor feeDistributor;
//     TransferStakedTokens transferStakedTokens;
//     RewardTracker rewardTracker;
//     LiquidityLocker liquidityLocker;

//     address weth;
//     address usdc;
//     address link;

//     string ethTicker = "ETH";
//     string usdcTicker = "USDC";
//     string[] tickers;

//     address USER = makeAddr("USER");
//     address USER1 = makeAddr("USER1");
//     address USER2 = makeAddr("USER2");

//     uint8[] precisions;
//     uint16[] variances;
//     uint48[] timestamps;
//     uint64[] meds;

//     function setUp() public {
//         Deploy deploy = new Deploy();
//         Deploy.Contracts memory contracts = deploy.run();
//         roleStorage = contracts.roleStorage;

//         marketFactory = contracts.marketFactory;
//         priceFeed = MockPriceFeed(address(contracts.priceFeed));
//         referralStorage = contracts.referralStorage;
//         positionManager = contracts.positionManager;
//         router = contracts.router;
//         feeDistributor = contracts.feeDistributor;
//         transferStakedTokens = contracts.transferStakedTokens;
//         OWNER = contracts.owner;
//         (weth, usdc, link,,,,,,,) = deploy.activeNetworkConfig();
//         tickers.push(ethTicker);
//         tickers.push(usdcTicker);
//         // Pass some time so block timestamp isn't 0
//         vm.warp(block.timestamp + 1 days);
//         vm.roll(block.number + 1);
//     }

//     receive() external payable {}

//     modifier setUpMarkets() {
//         vm.deal(OWNER, 2_000_000 ether);
//         MockUSDC(usdc).mint(OWNER, 1_000_000_000e6);
//         vm.deal(USER, 2_000_000 ether);
//         MockUSDC(usdc).mint(USER, 1_000_000_000e6);
//         vm.deal(USER1, 2_000_000 ether);
//         MockUSDC(usdc).mint(USER1, 1_000_000_000e6);
//         vm.deal(USER2, 2_000_000 ether);
//         MockUSDC(usdc).mint(USER2, 1_000_000_000e6);
//         vm.prank(USER);
//         WETH(weth).deposit{value: 1_000_000 ether}();
//         vm.prank(USER1);
//         WETH(weth).deposit{value: 1_000_000 ether}();
//         vm.prank(USER2);
//         WETH(weth).deposit{value: 1_000_000 ether}();
//         vm.startPrank(OWNER);
//         WETH(weth).deposit{value: 1_000_000 ether}();
//         IMarketFactory.DeployParams memory request = IMarketFactory.DeployParams({
//             isMultiAsset: false,
//             owner: OWNER,
//             indexTokenTicker: "ETH",
//             marketTokenName: "BRRR",
//             marketTokenSymbol: "BRRR",
//             tokenData: IPriceFeed.TokenData(address(0), 18, IPriceFeed.FeedType.CHAINLINK, false),
//             pythData: IMarketFactory.PythData({id: bytes32(0), merkleProof: new bytes32[](0)}),
//             stablecoinMerkleProof: new bytes32[](0),
//             requestTimestamp: uint48(block.timestamp)
//         });
//         marketFactory.createNewMarket{value: 0.01 ether}(request);
//         // Set Prices
//         precisions.push(0);
//         precisions.push(0);
//         variances.push(100);
//         variances.push(100);
//         timestamps.push(uint48(block.timestamp));
//         timestamps.push(uint48(block.timestamp));
//         meds.push(3000);
//         meds.push(1);
//         bytes memory encodedPrices = priceFeed.encodePrices(tickers, precisions, variances, timestamps, meds);
//         priceFeed.updatePrices(encodedPrices);
//         marketFactory.executeMarketRequest(marketFactory.getRequestKeys()[0]);
//         market = Market(payable(marketFactory.markets(0)));
//         vm.stopPrank();
//         tradeStorage = ITradeStorage(market.tradeStorage());
//         rewardTracker = RewardTracker(address(market.rewardTracker()));
//         liquidityLocker = LiquidityLocker(address(rewardTracker.liquidityLocker()));
//         // Call the deposit function with sufficient gas
//         vm.prank(OWNER);
//         router.createDeposit{value: 20_000.01 ether + 1 gwei}(market, OWNER, weth, 20_000 ether, 0.01 ether, true);
//         vm.prank(OWNER);
//         positionManager.executeDeposit{value: 0.01 ether}(market, market.getRequestAtIndex(0).key);

//         vm.startPrank(OWNER);
//         MockUSDC(usdc).approve(address(router), type(uint256).max);
//         router.createDeposit{value: 0.01 ether + 1 gwei}(market, OWNER, usdc, 50_000_000e6, 0.01 ether, false);
//         positionManager.executeDeposit{value: 0.01 ether}(market, market.getRequestAtIndex(0).key);
//         vm.stopPrank();
//         _;
//     }

//     /**
//      * ================================== Limit / Stop Loss / Take Profit ==================================
//      */
//     function testStopLossTakeProfitOrdersCanBeAttachedToOpenPositions(
//         uint256 _sizeDelta,
//         uint256 _limitPrice,
//         uint256 _leverage,
//         bool _isLong,
//         bool _shouldWrap
//     ) public setUpMarkets {
//         // Create Request
//         Position.Input memory input;
//         uint256 collateralDelta;
//         _leverage = bound(_leverage, 2, 15);
//         // $500 - $10,000
//         _limitPrice = bound(_limitPrice, 500, 10_000);
//         if (_isLong) {
//             _sizeDelta = bound(_sizeDelta, 210e30, 1_000_000e30);
//             collateralDelta = mulDiv(_sizeDelta / _leverage, 1e18, 3000e30);
//             input = Position.Input({
//                 ticker: ethTicker,
//                 collateralToken: weth,
//                 collateralDelta: collateralDelta,
//                 sizeDelta: _sizeDelta,
//                 limitPrice: 0,
//                 maxSlippage: 0.3e30,
//                 executionFee: 0.01 ether,
//                 isLong: true,
//                 isLimit: false,
//                 isIncrease: true,
//                 reverseWrap: _shouldWrap,
//                 triggerAbove: false
//             });
//             if (_shouldWrap) {
//                 vm.prank(OWNER);
//                 router.createPositionRequest{value: collateralDelta + 0.01 ether}(
//                     market, input, Position.Conditionals(false, false, 0, 0, 0, 0)
//                 );
//             } else {
//                 vm.startPrank(OWNER);
//                 WETH(weth).approve(address(router), type(uint256).max);
//                 router.createPositionRequest{value: 0.01 ether}(
//                     market, input, Position.Conditionals(false, false, 0, 0, 0, 0)
//                 );
//                 vm.stopPrank();
//             }
//         } else {
//             _sizeDelta = bound(_sizeDelta, 210e30, 1_000_000e30);
//             collateralDelta = (_sizeDelta / _leverage).fromUsd(1e30, 1e6);
//             input = Position.Input({
//                 ticker: ethTicker,
//                 collateralToken: usdc,
//                 collateralDelta: collateralDelta,
//                 sizeDelta: _sizeDelta, // 10x leverage
//                 limitPrice: 0,
//                 maxSlippage: 0.3e30,
//                 executionFee: 0.01 ether,
//                 isLong: false,
//                 isLimit: false,
//                 isIncrease: true,
//                 reverseWrap: false,
//                 triggerAbove: false
//             });

//             vm.startPrank(OWNER);
//             MockUSDC(usdc).approve(address(router), type(uint256).max);
//             router.createPositionRequest{value: 0.01 ether}(
//                 market, input, Position.Conditionals(false, false, 0, 0, 0, 0)
//             );
//             vm.stopPrank();
//         }
//         // Execute Request
//         bytes32 key = tradeStorage.getOrderAtIndex(0, false);
//         vm.prank(OWNER);
//         positionManager.executePosition(market, key, bytes32(0), OWNER);

//         // Create Stop Loss Order
//         input.isLimit = true;
//         input.isIncrease = false;
//         input.limitPrice = _limitPrice;
//         input.collateralDelta = 0;
//         input.triggerAbove = _limitPrice > 3000e30 ? true : false;

//         vm.prank(OWNER);
//         router.createPositionRequest{value: 0.01 ether}(market, input, Position.Conditionals(false, false, 0, 0, 0, 0));

//         // Check stop loss is attached to position
//         Position.Data memory position = tradeStorage.getPosition(keccak256(abi.encode(ethTicker, OWNER, _isLong)));
//         if (input.triggerAbove) {
//             if (_isLong) {
//                 assertNotEq(position.takeProfitKey, bytes32(0));
//             } else {
//                 assertNotEq(position.stopLossKey, bytes32(0));
//             }
//         } else {
//             if (_isLong) {
//                 assertNotEq(position.stopLossKey, bytes32(0));
//             } else {
//                 assertNotEq(position.takeProfitKey, bytes32(0));
//             }
//         }

//         // Move the price to where it can be executed and execute
//         vm.warp(block.timestamp + 1 days);
//         vm.roll(block.number + 1);

//         _setPrices(uint64(_limitPrice), 1);

//         // Execute Stop Loss
//         key = tradeStorage.getOrderAtIndex(0, true);
//         bytes32 requestId = keccak256(abi.encode("PRICE REQUEST"));
//         vm.prank(OWNER);
//         positionManager.executePosition(market, key, requestId, OWNER);
//     }

//     /**
//      * ================================== Liquidations ==================================
//      */
//     function testLiquidatingPositionsThatGoUnder(
//         uint256 _sizeDelta,
//         uint256 _leverage,
//         uint256 _newPrice,
//         bool _isLong,
//         bool _shouldWrap
//     ) public setUpMarkets {
//         // Create Request
//         Position.Input memory input;
//         uint256 collateralDelta;
//         _leverage = bound(_leverage, 2, 15);
//         if (_isLong) {
//             _sizeDelta = bound(_sizeDelta, 210e30, 1_000_000e30);
//             collateralDelta = mulDiv(_sizeDelta / _leverage, 1e18, 3000e30);
//             input = Position.Input({
//                 ticker: ethTicker,
//                 collateralToken: weth,
//                 collateralDelta: collateralDelta,
//                 sizeDelta: _sizeDelta,
//                 limitPrice: 0,
//                 maxSlippage: 0.3e30,
//                 executionFee: 0.01 ether,
//                 isLong: true,
//                 isLimit: false,
//                 isIncrease: true,
//                 reverseWrap: _shouldWrap,
//                 triggerAbove: false
//             });
//             if (_shouldWrap) {
//                 vm.prank(OWNER);
//                 router.createPositionRequest{value: collateralDelta + 0.01 ether}(
//                     market, input, Position.Conditionals(false, false, 0, 0, 0, 0)
//                 );
//             } else {
//                 vm.startPrank(OWNER);
//                 WETH(weth).approve(address(router), type(uint256).max);
//                 router.createPositionRequest{value: 0.01 ether}(
//                     market, input, Position.Conditionals(false, false, 0, 0, 0, 0)
//                 );
//                 vm.stopPrank();
//             }
//         } else {
//             _sizeDelta = bound(_sizeDelta, 210e30, 1_000_000e30);
//             collateralDelta = (_sizeDelta / _leverage).fromUsd(1e30, 1e6);
//             input = Position.Input({
//                 ticker: ethTicker,
//                 collateralToken: usdc,
//                 collateralDelta: collateralDelta,
//                 sizeDelta: _sizeDelta, // 10x leverage
//                 limitPrice: 0,
//                 maxSlippage: 0.3e30,
//                 executionFee: 0.01 ether,
//                 isLong: false,
//                 isLimit: false,
//                 isIncrease: true,
//                 reverseWrap: false,
//                 triggerAbove: false
//             });

//             vm.startPrank(OWNER);
//             MockUSDC(usdc).approve(address(router), type(uint256).max);
//             router.createPositionRequest{value: 0.01 ether}(
//                 market, input, Position.Conditionals(false, false, 0, 0, 0, 0)
//             );
//             vm.stopPrank();
//         }

//         // Execute Request
//         bytes32 key = tradeStorage.getOrderAtIndex(0, false);
//         vm.prank(OWNER);
//         positionManager.executePosition(market, key, bytes32(0), OWNER);

//         // determine the threshold for liquidation
//         // get the position
//         bytes32 positionKey = keccak256(abi.encode(ethTicker, OWNER, _isLong));
//         Position.Data memory position = tradeStorage.getPosition(positionKey);

//         // get the liquidation price
//         if (_isLong) {
//             uint256 liquidationPrice = Position.getLiquidationPrice(position);
//             // bound price below liquidation price
//             _newPrice = bound(_newPrice, 100, liquidationPrice / 1e30);
//         } else {
//             uint256 liquidationPrice = Position.getLiquidationPrice(position);
//             // bound price above liquidation price
//             _newPrice = bound(_newPrice, liquidationPrice / 1e30, 100_000);
//         }

//         // sign the new price
//         _setPrices(uint64(_newPrice), 1);
//         // liquidate the position
//         bytes32 requestId = keccak256(abi.encode("PRICE REQUEST"));
//         vm.prank(OWNER);
//         positionManager.liquidatePosition(market, positionKey, requestId);
//     }

//     /**
//      * ================================== ADLs ==================================
//      */

//     // Open positions, then move the price so that the PNL to pool ratio is > 0.45
//     // Try to ADL any of the positions
//     function testAdlingProfitablePositions(uint256 _newPrice, bool _isLong, bool _shouldWrap) public setUpMarkets {
//         // Create Request
//         Position.Input memory input;
//         if (_isLong) {
//             input = Position.Input({
//                 ticker: ethTicker,
//                 collateralToken: weth,
//                 collateralDelta: 333.333 ether,
//                 sizeDelta: 10_000_000e30, // 10x leverage
//                 limitPrice: 0,
//                 maxSlippage: 0.3e30,
//                 executionFee: 0.01 ether,
//                 isLong: true,
//                 isLimit: false,
//                 isIncrease: true,
//                 reverseWrap: _shouldWrap,
//                 triggerAbove: false
//             });
//             if (_shouldWrap) {
//                 vm.prank(OWNER);
//                 router.createPositionRequest{value: 333.333 ether + 0.01 ether}(
//                     market, input, Position.Conditionals(false, false, 0, 0, 0, 0)
//                 );
//                 vm.prank(USER);
//                 router.createPositionRequest{value: 333.333 ether + 0.01 ether}(
//                     market, input, Position.Conditionals(false, false, 0, 0, 0, 0)
//                 );
//                 vm.prank(USER1);
//                 router.createPositionRequest{value: 333.333 ether + 0.01 ether}(
//                     market, input, Position.Conditionals(false, false, 0, 0, 0, 0)
//                 );
//                 vm.prank(USER2);
//                 router.createPositionRequest{value: 333.333 ether + 0.01 ether}(
//                     market, input, Position.Conditionals(false, false, 0, 0, 0, 0)
//                 );
//             } else {
//                 vm.startPrank(OWNER);
//                 WETH(weth).approve(address(router), type(uint256).max);
//                 router.createPositionRequest{value: 0.01 ether}(
//                     market, input, Position.Conditionals(false, false, 0, 0, 0, 0)
//                 );
//                 vm.stopPrank();
//                 vm.startPrank(USER);
//                 WETH(weth).approve(address(router), type(uint256).max);
//                 router.createPositionRequest{value: 0.01 ether}(
//                     market, input, Position.Conditionals(false, false, 0, 0, 0, 0)
//                 );
//                 vm.stopPrank();
//                 vm.startPrank(USER1);
//                 WETH(weth).approve(address(router), type(uint256).max);
//                 router.createPositionRequest{value: 0.01 ether}(
//                     market, input, Position.Conditionals(false, false, 0, 0, 0, 0)
//                 );
//                 vm.stopPrank();
//                 vm.startPrank(USER2);
//                 WETH(weth).approve(address(router), type(uint256).max);
//                 router.createPositionRequest{value: 0.01 ether}(
//                     market, input, Position.Conditionals(false, false, 0, 0, 0, 0)
//                 );
//                 vm.stopPrank();
//             }
//         } else {
//             input = Position.Input({
//                 ticker: ethTicker,
//                 collateralToken: usdc,
//                 collateralDelta: 1_000_000e6,
//                 sizeDelta: 10_000_000e30, // 10x leverage
//                 limitPrice: 0,
//                 maxSlippage: 0.3e30,
//                 executionFee: 0.01 ether,
//                 isLong: false,
//                 isLimit: false,
//                 isIncrease: true,
//                 reverseWrap: false,
//                 triggerAbove: false
//             });

//             // Create a Bunch of Position Requests
//             vm.startPrank(OWNER);
//             MockUSDC(usdc).approve(address(router), type(uint256).max);
//             router.createPositionRequest{value: 0.01 ether}(
//                 market, input, Position.Conditionals(false, false, 0, 0, 0, 0)
//             );
//             vm.stopPrank();
//             vm.startPrank(USER);
//             MockUSDC(usdc).approve(address(router), type(uint256).max);
//             router.createPositionRequest{value: 0.01 ether}(
//                 market, input, Position.Conditionals(false, false, 0, 0, 0, 0)
//             );
//             vm.stopPrank();
//             vm.startPrank(USER1);
//             MockUSDC(usdc).approve(address(router), type(uint256).max);
//             router.createPositionRequest{value: 0.01 ether}(
//                 market, input, Position.Conditionals(false, false, 0, 0, 0, 0)
//             );
//             vm.stopPrank();
//             vm.startPrank(USER2);
//             MockUSDC(usdc).approve(address(router), type(uint256).max);
//             router.createPositionRequest{value: 0.01 ether}(
//                 market, input, Position.Conditionals(false, false, 0, 0, 0, 0)
//             );
//             vm.stopPrank();
//         }

//         // Execute Request
//         bytes32 key = tradeStorage.getOrderAtIndex(0, false);
//         vm.startPrank(OWNER);
//         positionManager.executePosition(market, key, bytes32(0), OWNER);
//         key = tradeStorage.getOrderAtIndex(0, false);
//         positionManager.executePosition(market, key, bytes32(0), OWNER);
//         key = tradeStorage.getOrderAtIndex(0, false);
//         positionManager.executePosition(market, key, bytes32(0), OWNER);
//         key = tradeStorage.getOrderAtIndex(0, false);
//         positionManager.executePosition(market, key, bytes32(0), OWNER);
//         vm.stopPrank();

//         IMarket.PnlValues memory pnl = market.getPnlValues(ethTicker);
//         if (_isLong) {
//             pnl.longAverageEntryPriceUsd = 1000e30;
//             _newPrice = bound(_newPrice, 5000e30, 100_000e30);
//         } else {
//             pnl.shortAverageEntryPriceUsd = 10_000e30;
//             _newPrice = bound(_newPrice, 1e30, 2000e30);
//         }
//         vm.mockCall(
//             address(market),
//             abi.encodeWithSelector(market.getPnlValues.selector, market, ethTicker, _isLong),
//             abi.encode(pnl)
//         );

//         // sign the new price
//         _setPrices(uint64(_newPrice), 1);

//         bytes32 requestId = keccak256(abi.encode("PRICE REQUEST"));
//         if (_isLong) {
//             vm.assume(MarketUtils.getPnlFactor(market, ethTicker, 3000e30, 1e18, 3000e30, 1e18, true) > 0.45e18);
//             // ADL any one of the positions
//             bytes32 positionKey = keccak256(abi.encode(ethTicker, OWNER, true));
//             vm.prank(OWNER);
//             positionManager.executeAdl(market, requestId, positionKey);
//         } else {
//             vm.assume(MarketUtils.getPnlFactor(market, ethTicker, 3000e30, 1e18, 1e30, 1e6, false) > 0.45e18);
//             // ADL any one of the positions
//             bytes32 positionKey = keccak256(abi.encode(ethTicker, OWNER, false));
//             vm.prank(OWNER);
//             positionManager.executeAdl(market, requestId, positionKey);
//         }
//     }

//     function _setPrices(uint64 _ethPrice, uint64 _usdcPrice) private {
//         // Set Prices
//         timestamps[0] = uint48(block.timestamp);
//         timestamps[1] = uint48(block.timestamp);
//         meds[0] = _ethPrice;
//         meds[1] = _usdcPrice;
//         bytes memory encodedPrices = priceFeed.encodePrices(tickers, precisions, variances, timestamps, meds);
//         priceFeed.updatePrices(encodedPrices);
//     }
// }
