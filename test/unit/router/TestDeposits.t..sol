// // SPDX-License-Identifier: MIT
// pragma solidity 0.8.23;

// import {Test, console} from "forge-std/Test.sol";
// import {Deploy} from "../../../script/Deploy.s.sol";
// import {RoleStorage} from "../../../src/access/RoleStorage.sol";
// import {Market, IMarket} from "../../../src/markets/Market.sol";
// import {MarketMaker, IMarketMaker} from "../../../src/markets/MarketMaker.sol";
// import {IPriceFeed} from "../../../src/oracle/interfaces/IPriceFeed.sol";
// import {TradeStorage, ITradeStorage} from "../../../src/positions/TradeStorage.sol";
// import {ReferralStorage} from "../../../src/referrals/ReferralStorage.sol";
// import {PositionManager} from "../../../src/router/PositionManager.sol";
// import {Router} from "../../../src/router/Router.sol";
// import {WETH} from "../../../src/tokens/WETH.sol";
// import {Oracle} from "../../../src/oracle/Oracle.sol";
// import {MockUSDC} from "../../mocks/MockUSDC.sol";
// import {MarketUtils} from "../../../src/markets/MarketUtils.sol";
// import {IMarketToken} from "../../../src/markets/interfaces/IMarketToken.sol";

// contract TestDeposits is Test {
//     RoleStorage roleStorage;

//     MarketMaker marketMaker;
//     IPriceFeed priceFeed; // Deployed in Helper Config
//     ITradeStorage tradeStorage;
//     ReferralStorage referralStorage;
//     PositionManager positionManager;
//     Router router;
//     address OWNER;
//     Market market;
//     address feeDistributor;

//     address weth;
//     address usdc;
//     bytes32 ethPriceId;
//     bytes32 usdcPriceId;

//     bytes[] tokenUpdateData;
//     uint256[] allocations;
//     bytes32[] assetIds;
//     uint256[] compactedPrices;

//     address USER = makeAddr("USER");

//     bytes32 ethAssetId = keccak256(abi.encode("ETH"));
//     bytes32 usdcAssetId = keccak256(abi.encode("USDC"));

//     function setUp() public {
//         Deploy deploy = new Deploy();
//         Deploy.Contracts memory contracts = deploy.run();
//         roleStorage = contracts.roleStorage;

//         marketMaker = contracts.marketMaker;
//         priceFeed = contracts.priceFeed;
//         referralStorage = contracts.referralStorage;
//         positionManager = contracts.positionManager;
//         router = contracts.router;
//         feeDistributor = address(contracts.feeDistributor);
//         OWNER = contracts.owner;
//         (weth, usdc, ethPriceId, usdcPriceId,,,,) = deploy.activeNetworkConfig();
//         // Pass some time so block timestamp isn't 0
//         vm.warp(block.timestamp + 1 days);
//         vm.roll(block.number + 1);
//         // Set Update Data
//         assetIds.push(ethAssetId);
//         assetIds.push(usdcAssetId);
//     }

//     receive() external payable {}

//     modifier setUpMarkets() {
//         vm.deal(OWNER, 1_000_000 ether);
//         MockUSDC(usdc).mint(OWNER, 1_000_000_000e6);
//         vm.deal(USER, 1_000_000 ether);
//         MockUSDC(usdc).mint(USER, 1_000_000_000e6);
//         vm.startPrank(OWNER);
//         WETH(weth).deposit{value: 50 ether}();
//         IMarketMaker.MarketRequest memory request = IMarketMaker.MarketRequest({
//             owner: OWNER,
//             indexTokenTicker: "ETH",
//             marketTokenName: "BRRR",
//             marketTokenSymbol: "BRRR"
//         });
//         marketMaker.requestNewMarket{value: 0.01 ether}(request);
//         // Set primary prices for ref price
//         priceFeed.setPrimaryPrices{value: 0.01 ether}(assetIds, tokenUpdateData, compactedPrices);
//         // Clear them
//         priceFeed.clearPrimaryPrices();
//         marketMaker.executeNewMarket(marketMaker.getMarketRequestKey(request.owner, request.indexTokenTicker));
//         vm.stopPrank();
//         market = Market(payable(marketMaker.tokenToMarket(ethAssetId)));
//         tradeStorage = ITradeStorage(market.tradeStorage());
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
//         vm.startPrank(OWNER);
//         allocations.push(10000 << 240);
//         assertEq(MarketUtils.getAllocation(market, ethAssetId), 10000);
//         vm.stopPrank();
//         _;
//     }

//     function testCreatingADepositRequest() public setUpMarkets {
//         // Call the deposit function with sufficient gas
//         vm.prank(OWNER);
//         router.createDeposit{value: 0.51 ether}(market, OWNER, weth, 0.5 ether, 0.01 ether, true);
//     }

//     function testExecutingADepositRequest() public setUpMarkets {
//         // Call the deposit function with sufficient gas
//         vm.prank(OWNER);
//         router.createDeposit{value: 0.51 ether}(market, OWNER, weth, 0.5 ether, 0.01 ether, true);
//         // Call the execute deposit function with sufficient gas
//         bytes32 depositKey = market.getRequestAtIndex(0).key;
//         vm.prank(OWNER);
//         positionManager.executeDeposit{value: 0.0001 ether}(market, depositKey);
//     }

//     function testFuzzingDepositAmountInEther(uint256 _amountIn) public setUpMarkets {
//         // Add Buffer of 0.1 ether to cover execution fees and gas
//         _amountIn = bound(_amountIn, 1, address(OWNER).balance - 0.1 ether);
//         // Call the deposit function with sufficient gas
//         vm.prank(OWNER);
//         router.createDeposit{value: _amountIn + 0.01 ether}(market, OWNER, weth, _amountIn, 0.01 ether, true);
//         bytes32 depositKey = market.getRequestAtIndex(0).key;
//         IMarketToken marketToken = market.MARKET_TOKEN();
//         uint256 marketTokenBalanceBefore = marketToken.balanceOf(OWNER);
//         vm.prank(OWNER);
//         positionManager.executeDeposit{value: 0.0001 ether}(market, depositKey);
//         uint256 marketTokenBalanceAfter = marketToken.balanceOf(OWNER);
//         assertGt(marketTokenBalanceAfter, marketTokenBalanceBefore);
//     }

//     function testFuzzingInvalidEtherAmountInsFails(uint256 _amountIn) public setUpMarkets {
//         vm.assume(_amountIn > address(OWNER).balance);
//         // Call the deposit function with sufficient gas
//         vm.prank(OWNER);
//         vm.expectRevert();
//         router.createDeposit{value: _amountIn + 0.01 ether}(market, OWNER, weth, _amountIn, 0.01 ether, true);
//     }

//     function testFuzzingValuesWhereValueIsLessThanAmount(uint256 _amountIn, uint256 _value) public setUpMarkets {
//         vm.assume(_value < _amountIn);
//         // Call the deposit function with sufficient gas
//         vm.prank(OWNER);
//         vm.expectRevert();
//         router.createDeposit{value: _value + 0.01 ether}(market, OWNER, weth, _amountIn, 0.01 ether, true);
//     }

//     function testFuzzingDepositAmountInWrappedEther(uint256 _amountIn) public setUpMarkets {
//         _amountIn = bound(_amountIn, 1, WETH(weth).balanceOf(OWNER));
//         // Call the deposit function with sufficient gas
//         vm.prank(OWNER);
//         WETH(weth).approve(address(router), type(uint256).max);
//         router.createDeposit{value: 0.01 ether}(market, OWNER, weth, _amountIn, 0.01 ether, false);
//         bytes32 depositKey = market.getRequestAtIndex(0).key;
//         positionManager.executeDeposit{value: 0.0001 ether}(market, depositKey);
//     }

//     function testFuzzingDepositAmountInUsdc(uint256 _amountIn) public setUpMarkets {
//         _amountIn = bound(_amountIn, 1, MockUSDC(usdc).balanceOf(OWNER));
//         // Call the deposit function with sufficient gas
//         vm.startPrank(OWNER);
//         MockUSDC(usdc).approve(address(router), type(uint256).max);
//         router.createDeposit{value: 0.01 ether}(market, OWNER, usdc, _amountIn, 0.01 ether, false);
//         bytes32 depositKey = market.getRequestAtIndex(0).key;
//         positionManager.executeDeposit{value: 0.0001 ether}(market, depositKey);
//         vm.stopPrank();
//     }

//     // Expected Amount = 2.4970005e+25 (base fee + price spread)
//     // Received Amount = 2.4970005e+25
//     function testDepositWithHugeAmount() public setUpMarkets {
//         // Call the deposit function with sufficient gas
//         vm.prank(OWNER);
//         router.createDeposit{value: 10_000.01 ether}(market, OWNER, weth, 10_000 ether, 0.01 ether, true);
//         bytes32 depositKey = market.getRequestAtIndex(0).key;
//         IMarketToken marketToken = market.MARKET_TOKEN();
//         uint256 balanceBefore = marketToken.balanceOf(OWNER);
//         vm.prank(OWNER);
//         positionManager.executeDeposit{value: 0.0001 ether}(market, depositKey);
//         uint256 balanceAfter = marketToken.balanceOf(OWNER);
//         assertGt(balanceAfter, balanceBefore);
//     }

//     function testDynamicFeesOnImbalancedDeposits() public setUpMarkets {
//         // // Call the deposit function with sufficient gas
//         // vm.prank(OWNER);
//         // router.createDeposit{value: 1.01 ether}(market, OWNER, weth, 1 ether, 0.01 ether, true);
//         // bytes32 depositKey = market.getRequestAtIndex(0).key;
//         // vm.prank(OWNER);
//         // positionManager.executeDeposit{value: 0.0001 ether}(market, depositKey);
//         // IMarketToken marketToken = market.MARKET_TOKEN();
//         // uint256 balanceBefore = marketToken.balanceOf(OWNER);
//         // vm.warp(block.timestamp + 1 days);
//         // vm.roll(block.number + 1);

//         // // Calculate the expected amount out
//         // (Oracle.Price memory longPrices, Oracle.Price memory shortPrices) = Oracle.getLastMarketTokenPrices(priceFeed);
//         // console.log("LTB: ", market.longTokenBalance());
//         // console.log("STB: ", market.shortTokenBalance());
//         // console.log("MTS: ", market.totalSupply());
//         // Fee.Params memory feeParams = Fee.constructFeeParams(market, 50000e6, false, longPrices, shortPrices, true);
//         // uint256 expectedFee =
//         //     Fee.calculateFee(feeParams, market.longTokenBalance(), 1e18, market.shortTokenBalance(), 1e6);
//         // console.log("Expected Fee: ", expectedFee);
//         // uint256 amountMinusFee = 50_000e6 - expectedFee;
//         // console.log("Amount Minus Fee: ", amountMinusFee);

//         // vm.startPrank(OWNER);
//         // MockUSDC(usdc).approve(address(router), type(uint256).max);
//         // router.createDeposit{value: 0.01 ether}(market, OWNER, usdc, 50_000_000e6, 0.01 ether, false);
//         // depositKey = market.getRequestAtIndex(0).key;
//         // positionManager.executeDeposit{value: 0.0001 ether}(market, depositKey);
//         // vm.stopPrank();
//         // uint256 balanceAfter = marketToken.balanceOf(OWNER);
//         // console.log("Actual Amount Out: ", balanceAfter - balanceBefore);
//     }

//     // Bonus Fee = 0.0003995201959207653 (0.04%)
//     function testDynamicFeesOnGiganticImbalancedDeposits() public setUpMarkets {
//         // Call the deposit function with sufficient gas
//         vm.prank(OWNER);
//         router.createDeposit{value: 1.01 ether}(market, OWNER, weth, 1 ether, 0.01 ether, true);
//         bytes32 depositKey = market.getRequestAtIndex(0).key;
//         vm.prank(OWNER);
//         positionManager.executeDeposit{value: 0.0001 ether}(market, depositKey);
//         IMarketToken marketToken = market.MARKET_TOKEN();
//         uint256 balanceBefore = marketToken.balanceOf(OWNER);
//         vm.warp(block.timestamp + 1 days);
//         vm.roll(block.number + 1);

//         vm.startPrank(OWNER);
//         MockUSDC(usdc).approve(address(router), type(uint256).max);
//         router.createDeposit{value: 0.01 ether}(market, OWNER, usdc, 50_000_000e6, 0.01 ether, false);
//         depositKey = market.getRequestAtIndex(0).key;
//         positionManager.executeDeposit{value: 0.0001 ether}(market, depositKey);
//         vm.stopPrank();
//         uint256 amountReceived = marketToken.balanceOf(OWNER) - balanceBefore;
//         console.log("Actual Amount Out: ", amountReceived);
//     }

//     function testCreateDepositWithWethNoWrap() public setUpMarkets {
//         // Call the deposit function with sufficient gas
//         vm.startPrank(OWNER);
//         WETH(weth).approve(address(router), type(uint256).max);
//         router.createDeposit{value: 1.01 ether}(market, OWNER, weth, 1 ether, 0.01 ether, false);
//         bytes32 depositKey = market.getRequestAtIndex(0).key;
//         positionManager.executeDeposit{value: 0.0001 ether}(market, depositKey);
//         vm.stopPrank();
//     }
// }
