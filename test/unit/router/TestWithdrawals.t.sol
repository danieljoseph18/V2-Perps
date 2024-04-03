// // SPDX-License-Identifier: MIT
// pragma solidity 0.8.23;

// import {Test, console} from "forge-std/Test.sol";
// import {Deploy} from "../../../script/Deploy.s.sol";
// import {RoleStorage} from "../../../src/access/RoleStorage.sol";
// import {Market, IMarket} from "../../../src/markets/Market.sol";
// import {MarketFactory, IMarketFactory} from "../../../src/markets/MarketFactory.sol";
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

// contract TestWithdrawals is Test {
//     RoleStorage roleStorage;

//     MarketFactory marketFactory;
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

//         marketFactory = contracts.marketFactory;
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
//         IMarketFactory.MarketRequest memory request = IMarketFactory.MarketRequest({
//             owner: OWNER,
//             indexTokenTicker: "ETH",
//             marketTokenName: "BRRR",
//             marketTokenSymbol: "BRRR"
//         });
//         marketFactory.requestNewMarket{value: 0.01 ether}(request);
//         // Set primary prices for ref price
//         priceFeed.setPrimaryPrices{value: 0.01 ether}(assetIds, tokenUpdateData, compactedPrices);
//         // Clear them
//         priceFeed.clearPrimaryPrices();
//         marketFactory.executeNewMarket(marketFactory.getMarketRequestKey(request.owner, request.indexTokenTicker));
//         vm.stopPrank();
//         market = Market(payable(marketFactory.tokenToMarket(ethAssetId)));
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

//     function testCreatingAWithdrawalRequest() public setUpMarkets {
//         // Construct the withdrawal input
//         IMarketToken marketToken = market.MARKET_TOKEN();
//         uint256 marketTokenBalance = marketToken.balanceOf(OWNER);
//         // Call the withdrawal function with sufficient gas
//         vm.startPrank(OWNER);
//         marketToken.approve(address(router), type(uint256).max);
//         router.createWithdrawal{value: 0.01 ether}(market, OWNER, weth, marketTokenBalance / 1000, 0.01 ether, true);
//         vm.stopPrank();
//     }

//     function testExecutingAWithdrawalRequest() public setUpMarkets {
//         // Construct the withdrawal input
//         IMarketToken marketToken = market.MARKET_TOKEN();
//         uint256 marketTokenBalance = marketToken.balanceOf(OWNER);

//         // Call the withdrawal function with sufficient gas
//         vm.startPrank(OWNER);
//         marketToken.approve(address(router), type(uint256).max);
//         console.log("Market Token Balance: ", marketTokenBalance);
//         router.createWithdrawal{value: 0.01 ether}(market, OWNER, weth, marketTokenBalance / 1000, 0.01 ether, true);
//         bytes32 withdrawalKey = market.getRequestAtIndex(0).key;
//         positionManager.executeWithdrawal{value: 0.0001 ether}(market, withdrawalKey);
//         vm.stopPrank();
//     }

//     function testWithdrawalRequestWithTinyAmountOut() public setUpMarkets {
//         // Call the withdrawal function with sufficient gas
//         vm.startPrank(OWNER);
//         IMarketToken marketToken = market.MARKET_TOKEN();
//         marketToken.approve(address(router), type(uint256).max);
//         router.createWithdrawal{value: 0.01 ether}(market, OWNER, weth, 1, 0.01 ether, true);
//         bytes32 withdrawalKey = market.getRequestAtIndex(0).key;
//         vm.expectRevert();
//         positionManager.executeWithdrawal{value: 0.0001 ether}(market, withdrawalKey);
//         vm.stopPrank();
//     }

//     function testWithdrawalRequestForGreaterThanPoolBalance() public setUpMarkets {
//         IMarketToken marketToken = market.MARKET_TOKEN();
//         uint256 marketTokenBalance = marketToken.balanceOf(OWNER);

//         // Call the withdrawal function with sufficient gas
//         vm.startPrank(OWNER);
//         marketToken.approve(address(router), type(uint256).max);
//         router.createWithdrawal{value: 0.01 ether}(market, OWNER, weth, marketTokenBalance, 0.01 ether, true);
//         bytes32 withdrawalKey = market.getRequestAtIndex(0).key;
//         vm.expectRevert();
//         positionManager.executeWithdrawal{value: 0.0001 ether}(market, withdrawalKey);
//         vm.stopPrank();
//     }

//     function testLargeWithdrawalRequest() public setUpMarkets {
//         IMarketToken marketToken = market.MARKET_TOKEN();
//         uint256 marketTokenBalance = marketToken.balanceOf(OWNER);

//         // Call the withdrawal function with sufficient gas
//         vm.startPrank(OWNER);
//         marketToken.approve(address(router), type(uint256).max);
//         router.createWithdrawal{value: 0.01 ether}(
//             market,
//             OWNER,
//             weth,
//             marketTokenBalance / 4,
//             0.01 ether,
//             true // Quarter of balance
//         );
//         bytes32 withdrawalKey = market.getRequestAtIndex(0).key;
//         positionManager.executeWithdrawal{value: 0.0001 ether}(market, withdrawalKey);
//         vm.stopPrank();
//     }
// }
