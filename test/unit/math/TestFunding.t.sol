// // SPDX-License-Identifier: MIT
// pragma solidity 0.8.23;

// import {Test, console, console2} from "forge-std/Test.sol";
// import {Deploy} from "../../../script/Deploy.s.sol";
// import {RoleStorage} from "../../../src/access/RoleStorage.sol";
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
// import {Market, IMarket} from "../../../src/markets/Market.sol";
// import {Gas} from "../../../src/libraries/Gas.sol";
// import {Funding} from "../../../src/libraries/Funding.sol";
// import {PriceImpact} from "../../../src/libraries/PriceImpact.sol";
// import {mulDiv, mulDivSigned} from "@prb/math/Common.sol";
// import {MarketUtils} from "../../../src/markets/MarketUtils.sol";

// contract TestFunding is Test {
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

//     /**
//      * Need To Test:
//      * - Velocity Calculation
//      * - Calculation of Accumulated Fees for Market
//      * - Calculation of Accumulated Fees for Position
//      * - Calculation of Funding Rate
//      * - Calculation of Fees Since Update
//      */

//     /**
//      * Config:
//      * maxVelocity: 0.09e18, // 9%
//      * skewScale: 1_000_000e18 // 1 Mil USD
//      */
//     function testVelocityCalculationForDifferentSkews() public setUpMarkets {
//         // Different Skews
//         int256 heavyLong = 500_000e30;
//         int256 heavyShort = -500_000e30;
//         int256 balancedLong = 1000e30;
//         int256 balancedShort = -1000e30;
//         // Calculate Heavy Long Velocity
//         int256 heavyLongVelocity = Funding.getCurrentVelocity(market, ethAssetId, heavyLong);
//         /**
//          * proportional skew = $500,000 / $1,000,000 = 0.5
//          * bounded skew = 0.5
//          * velocity = 0.5 * 0.09 = 0.045
//          */
//         int256 expectedHeavyLongVelocity = 0.045e18;
//         assertEq(heavyLongVelocity, expectedHeavyLongVelocity);
//         // Calculate Heavy Short Velocity
//         int256 heavyShortVelocity = Funding.getCurrentVelocity(market, ethAssetId, heavyShort);
//         /**
//          * proportional skew = -$500,000 / $1,000,000 = -0.5
//          * bounded skew = -0.5
//          * velocity = -0.5 * 0.09 = -0.045
//          */
//         int256 expectedHeavyShortVelocity = -0.045e18;
//         assertEq(heavyShortVelocity, expectedHeavyShortVelocity);
//         // Calculate Balanced Long Velocity
//         int256 balancedLongVelocity = Funding.getCurrentVelocity(market, ethAssetId, balancedLong);
//         /**
//          * proportional skew = $1,000 / $1,000,000 = 0.001
//          * bounded skew = 0.001
//          * velocity = 0.001 * 0.09 = 0.00009
//          */
//         int256 expectedBalancedLongVelocity = 0.00009e18;
//         assertEq(balancedLongVelocity, expectedBalancedLongVelocity);
//         // Calculate Balanced Short Velocity
//         int256 balancedShortVelocity = Funding.getCurrentVelocity(market, ethAssetId, balancedShort);
//         /**
//          * proportional skew = -$1,000 / $1,000,000 = -0.001
//          * bounded skew = -0.001
//          * velocity = -0.001 * 0.09 = -0.00009
//          */
//         int256 expectedBalancedShortVelocity = -0.00009e18;
//         assertEq(balancedShortVelocity, expectedBalancedShortVelocity);
//     }

//     function testSkewCalculationForDifferentSkews(uint256 _longOi, uint256 _shortOi) public setUpMarkets {
//         _longOi = bound(_longOi, 1e30, 1_000_000_000_000e30); // Bound between $1 and $1 Trillion
//         _shortOi = bound(_shortOi, 1e30, 1_000_000_000_000e30); // Bound between $1 and $1 Trillion
//         // Get market storage
//         IMarket.MarketStorage memory marketStorage = market.getStorage(ethAssetId);
//         marketStorage.openInterest.longOpenInterest = _longOi;
//         marketStorage.openInterest.shortOpenInterest = _shortOi;
//         // Mock Fuzz long & short Oi
//         vm.mockCall(
//             address(market), abi.encodeWithSelector(market.getStorage.selector, ethAssetId), abi.encode(marketStorage)
//         );
//         // Skew should be long oi - short oi
//         int256 skew = Funding.calculateSkewUsd(market, ethAssetId);
//         int256 expectedSkew = int256(_longOi) - int256(_shortOi);
//         assertEq(skew, expectedSkew);
//     }

//     function testGettingTheCurrentFundingRateChangesOverTimeWithVelocity() public setUpMarkets {
//         // Get market storage
//         IMarket.MarketStorage memory marketStorage = market.getStorage(ethAssetId);
//         marketStorage.funding.fundingRate = 0;
//         marketStorage.funding.fundingRateVelocity = 0.0025e18;
//         marketStorage.funding.lastFundingUpdate = uint48(block.timestamp);
//         // Mock an existing rate and velocity
//         vm.mockCall(
//             address(market), abi.encodeWithSelector(market.getStorage.selector, ethAssetId), abi.encode(marketStorage)
//         );
//         // get current funding rate
//         int256 currentFundingRate = Funding.getCurrentFundingRate(market, ethAssetId);
//         /**
//          * currentFundingRate = 0 + 0.0025 * (0 / 86,400)
//          *                    = 0
//          */
//         assertEq(currentFundingRate, 0);

//         // Pass some time
//         vm.warp(block.timestamp + 10_000);
//         vm.roll(block.number + 1);

//         // get current funding rate
//         currentFundingRate = Funding.getCurrentFundingRate(market, ethAssetId);
//         /**
//          * currentFundingRate = 0 + 0.0025 * (10,000 / 86,400)
//          *                    = 0 + 0.0025 * 0.11574074
//          *                    = 0.00028935185
//          */
//         assertEq(currentFundingRate, 289351851851851);

//         // Pass some time
//         vm.warp(block.timestamp + 10_000);
//         vm.roll(block.number + 1);

//         // get current funding rate
//         currentFundingRate = Funding.getCurrentFundingRate(market, ethAssetId);
//         /**
//          * currentFundingRate = 0 + 0.0025 * (20,000 / 86,400)
//          *                    = 0 + 0.0025 * 0.23148148
//          *                    = 0.0005787037
//          */
//         assertEq(currentFundingRate, 578703703703703);

//         // Pass some time
//         vm.warp(block.timestamp + 10_000);
//         vm.roll(block.number + 1);

//         // get current funding rate
//         currentFundingRate = Funding.getCurrentFundingRate(market, ethAssetId);

//         /**
//          * currentFundingRate = 0 + 0.0025 * (30,000 / 86,400)
//          *                    = 0 + 0.0025 * 0.34722222
//          *                    = 0.00086805555
//          */
//         assertEq(currentFundingRate, 868055555555555);
//     }

//     // Test funding trajectory with sign flip
//     function testGettingTheCurrentFundingRateIsConsistentAfterASignFlip() public setUpMarkets {
//         // Get market storage
//         IMarket.MarketStorage memory marketStorage = market.getStorage(ethAssetId);
//         marketStorage.funding.fundingRate = -0.0005e18;
//         marketStorage.funding.fundingRateVelocity = 0.0025e18;
//         marketStorage.funding.lastFundingUpdate = uint48(block.timestamp);

//         // Mock an existing negative rate and positive velocity
//         vm.mockCall(
//             address(market), abi.encodeWithSelector(market.getStorage.selector, ethAssetId), abi.encode(marketStorage)
//         );
//         // get current funding rate
//         int256 currentFundingRate = Funding.getCurrentFundingRate(market, ethAssetId);
//         /**
//          * currentFundingRate = -0.0005 + 0.0025 * (0 / 86,400)
//          *                    = -0.0005
//          */
//         assertEq(currentFundingRate, -0.0005e18);

//         // Pass some time
//         vm.warp(block.timestamp + 10_000);
//         vm.roll(block.number + 1);

//         // get current funding rate
//         currentFundingRate = Funding.getCurrentFundingRate(market, ethAssetId);
//         /**
//          * currentFundingRate = -0.0005 + 0.0025 * (10,000 / 86,400)
//          *                    = -0.0005 + 0.0025 * 0.11574074
//          *                    = -0.0005 + 0.00028935185
//          *                    = -0.000210648148148
//          */
//         assertEq(currentFundingRate, -210648148148149);

//         // Pass some time
//         vm.warp(block.timestamp + 10_000);
//         vm.roll(block.number + 1);

//         // get current funding rate
//         currentFundingRate = Funding.getCurrentFundingRate(market, ethAssetId);
//         /**
//          * currentFundingRate = -0.0005 + 0.0025 * (20,000 / 86,400)
//          *                    = -0.0005 + 0.0025 * 0.23148148
//          *                    = -0.0005 + 0.0005787037
//          *                    = 0.0000787037037037
//          */
//         assertEq(currentFundingRate, 78703703703703);

//         // Pass some time
//         vm.warp(block.timestamp + 10_000);
//         vm.roll(block.number + 1);

//         // get current funding rate
//         currentFundingRate = Funding.getCurrentFundingRate(market, ethAssetId);

//         /**
//          * currentFundingRate = -0.0005 + 0.0025 * (30,000 / 86,400)
//          *                    = -0.0005 + 0.0025 * 0.34722222
//          *                    = -0.0005 + 0.00086805555
//          *                    = 0.0003680555555555
//          */
//         assertEq(currentFundingRate, 368055555555555);
//     }

//     struct PositionChange {
//         uint256 sizeDelta;
//         int256 entryFundingAccrued;
//         int256 fundingRate;
//         int256 fundingVelocity;
//         int256 fundingFeeUsd;
//         int256 nextFundingAccrued;
//     }

//     function testFuzzGetFeeForPositionChange(
//         uint256 _sizeDelta,
//         int256 _entryFundingAccrued,
//         int256 _fundingRate,
//         int256 _fundingVelocity
//     ) public setUpMarkets {
//         PositionChange memory values;

//         // Bound the inputs to reasonable ranges
//         values.sizeDelta = bound(_sizeDelta, 1e30, 1_000_000e30); // $1 - $1M
//         values.entryFundingAccrued = bound(_entryFundingAccrued, -1e30, 1e30); // Between -$1 and $1
//         values.fundingRate = bound(_fundingRate, -1e18, 1e18); // Between -100% and 100%
//         values.fundingVelocity = bound(_fundingVelocity, -1e18, 1e18); // Between -100% and 100%

//         // Get market storage
//         IMarket.MarketStorage memory marketStorage = market.getStorage(ethAssetId);
//         marketStorage.funding.fundingRate = values.fundingRate;
//         marketStorage.funding.fundingRateVelocity = values.fundingVelocity;
//         marketStorage.funding.lastFundingUpdate = uint48(block.timestamp);
//         marketStorage.funding.fundingAccruedUsd = values.entryFundingAccrued;

//         // Mock the necessary market functions
//         vm.mockCall(
//             address(market), abi.encodeWithSelector(market.getStorage.selector, ethAssetId), abi.encode(marketStorage)
//         );

//         // Pass some time
//         vm.warp(block.timestamp + 10_000);
//         vm.roll(block.number + 1);

//         // Call the function with the fuzzed inputs
//         (values.fundingFeeUsd, values.nextFundingAccrued) =
//             Position.getFundingFeeDelta(market, ethAssetId, 2500e30, values.sizeDelta, values.entryFundingAccrued);

//         // Assert that the outputs are within expected ranges
//         assertEq(
//             values.fundingFeeUsd,
//             mulDivSigned(int256(values.sizeDelta), values.nextFundingAccrued - values.entryFundingAccrued, 1e30)
//         );
//     }

//     function testFuzzRecompute(
//         int256 _fundingRate,
//         int256 _fundingVelocity,
//         int256 _entryFundingAccrued,
//         uint256 _indexPrice
//     ) public setUpMarkets {
//         // Bound inputs
//         _fundingRate = bound(_fundingRate, -1e18, 1e18); // Between -100% and 100%
//         _fundingVelocity = bound(_fundingVelocity, -1e18, 1e18); // Between -100% and 100%
//         _entryFundingAccrued = bound(_entryFundingAccrued, -1e30, 1e30); // Between -$1 and $1
//         _indexPrice = bound(_indexPrice, 100e30, 100_000e30);
//         // Get market storage
//         IMarket.MarketStorage memory marketStorage = market.getStorage(ethAssetId);
//         marketStorage.funding.fundingRate = _fundingRate;
//         marketStorage.funding.fundingRateVelocity = _fundingVelocity;
//         marketStorage.funding.lastFundingUpdate = uint48(block.timestamp);
//         marketStorage.funding.fundingAccruedUsd = _entryFundingAccrued;
//         // Mock the necessary market functions
//         vm.mockCall(
//             address(market), abi.encodeWithSelector(market.getStorage.selector, ethAssetId), abi.encode(marketStorage)
//         );

//         vm.warp(block.timestamp + 10_000);
//         vm.roll(block.number + 1);

//         // Call the function with the fuzzed input
//         (int256 nextFundingRate, int256 nextFundingAccruedUsd) = Funding.recompute(market, ethAssetId, _indexPrice);

//         // Check values are as expected
//         console2.log(nextFundingRate);
//         console2.log(nextFundingAccruedUsd);
//     }
// }
