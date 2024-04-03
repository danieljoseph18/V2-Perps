// // SPDX-License-Identifier: MIT
// pragma solidity 0.8.23;

// import {Test, console, console2} from "forge-std/Test.sol";
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
// import {Position} from "../../../src/positions/Position.sol";
// import {Gas} from "../../../src/libraries/Gas.sol";
// import {Funding} from "../../../src/libraries/Funding.sol";
// import {PriceImpact} from "../../../src/libraries/PriceImpact.sol";
// import {Borrowing} from "../../../src/libraries/Borrowing.sol";
// import {Execution} from "../../../src/positions/Execution.sol";
// import {mulDiv} from "@prb/math/Common.sol";
// import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
// import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
// import {MarketUtils} from "../../../src/markets/MarketUtils.sol";

// contract TestMarketAllocations is Test {
//     using SignedMath for int256;

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

//     bytes32 ethAssetId = keccak256(abi.encode("ETH"));
//     bytes32 usdcAssetId = keccak256(abi.encode("USDC"));

//     bytes[] tokenUpdateData;
//     uint256[] allocations;
//     bytes32[] assetIds;
//     uint256[] compactedPrices;

//     address USER = makeAddr("USER");

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
//         (weth, usdc, ethPriceId, usdcPriceId,,) = deploy.activeNetworkConfig();
//         // Pass some time so block timestamp isn't 0
//         vm.warp(block.timestamp + 1 days);
//         vm.roll(block.number + 1);
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
//             marketTokenSymbol: "BRRR",
//             baseUnit: 1e18
//         });
//         marketMaker.requestNewMarket{value: 0.01 ether}(request);
//         marketMaker.executeNewMarket(marketMaker.getMarketRequestKey(request.owner, request.indexTokenTicker));
//         vm.stopPrank();
//         // @audit - eth ticker
//         // market = Market(payable(marketMaker.tokenToMarket(ethAssetId)));
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
//         // assertEq(MarketUtils.getAllocation(market, ethAssetId), 10000);
//         vm.stopPrank();
//         _;
//     }

//     /**
//      * Tests Required:
//      *
//      *     - Listing multiple assets under the same market
//      *     - Dividing liquidity between multiple assets in the same market
//      *     - Testing data storage for different assets within the same market
//      */
//     function testCreatingMultipleAssetsUnderTheSameMarket() public {
//         // IMarketMaker.MarketRequest memory request = IMarketMaker.MarketRequest({
//         //     owner: OWNER,
//         //     indexTokenTicker: "ETH",
//         //     marketTokenName: "BRRR",
//         //     marketTokenSymbol: "BRRR",
//         //     baseUnit: 1e18
//         // });

//         // marketMaker.requestNewMarket{value: 0.01 ether}(request);

//         // bytes32 marketKey = marketMaker.getMarketRequestKey(request.owner, request.indexTokenTicker);
//         // Set primary prices for ref price
//         // priceFeed.setPrimaryPrices{value: 0.01 ether}(assetIds, tokenUpdateData, compactedPrices);
//         // Clear them
//         // priceFeed.clearPrimaryPrices();
//         // IMarket marketInterface = IMarket(marketMaker.executeNewMarket(marketKey));

//         // uint256 firstAllocation = 5000;
//         // uint256 secondAllocation = 5000;

//         // uint256 encodedAllocation = firstAllocation << 240;

//         // encodedAllocation |= secondAllocation << 224;

//         // delete allocations; // clear allocations
//         // allocations.push(encodedAllocation);

//         // // split the allocation between the markets
//         // marketMaker.addTokenToMarket(marketInterface, keccak256(abi.encode("RANDOM_ERC")), ethPriceId, allocations);

//         // assertEq(MarketUtils.getAllocation(marketInterface, keccak256(abi.encode("RANDOM_ERC"))), 5000);

//         // firstAllocation = 3334;
//         // secondAllocation = 3333;

//         // encodedAllocation = firstAllocation << 240;
//         // encodedAllocation |= secondAllocation << 224;
//         // encodedAllocation |= secondAllocation << 208;

//         // delete allocations;
//         // allocations.push(encodedAllocation);
//         // marketMaker.addTokenToMarket(marketInterface, keccak256(abi.encode("RANDOM_ERC_2")), ethPriceId, allocations);

//         // assertEq(MarketUtils.getAllocation(marketInterface, keccak256(abi.encode("RANDOM_ERC_2"))), 3333);

//         // firstAllocation = 2500;

//         // encodedAllocation = firstAllocation << 240;
//         // encodedAllocation |= firstAllocation << 224;
//         // encodedAllocation |= firstAllocation << 208;
//         // encodedAllocation |= firstAllocation << 192;

//         // delete allocations;
//         // allocations.push(encodedAllocation);
//         // marketMaker.addTokenToMarket(marketInterface, keccak256(abi.encode("RANDOM_ERC_3")), ethPriceId, allocations);
//     }
// }
