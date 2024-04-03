// // SPDX-License-Identifier: MIT
// pragma solidity 0.8.23;

// import {Test, console, console2} from "forge-std/Test.sol";
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
// import {Position} from "../../../src/positions/Position.sol";
// import {Gas} from "../../../src/libraries/Gas.sol";
// import {Funding} from "../../../src/libraries/Funding.sol";
// import {PriceImpact} from "../../../src/libraries/PriceImpact.sol";
// import {Borrowing} from "../../../src/libraries/Borrowing.sol";
// import {mulDiv} from "@prb/math/Common.sol";
// import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
// import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
// import {Referral} from "../../../src/referrals/Referral.sol";
// import {MarketUtils} from "../../../src/markets/MarketUtils.sol";

// contract TestReferrals is Test {
//     using SignedMath for int256;

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

//     /**
//      * Tests Required:
//      *
//      *     - Using a referral code for a fee discount
//      *     - Receiving affiliate rewards for referring another user
//      */

//     /**
//      * function calculateForPosition(
//      *     ITradeStorage tradeStorage,
//      *     uint256 _sizeDelta,
//      *     uint256 _collateralDelta,
//      *     uint256 _indexPrice,
//      *     uint256 _indexBaseUnit,
//      *     uint256 _collateralPrice,
//      *     uint256 _collateralBaseUnit
//      * )
//      */
//     function testUsingAReferralCodeGrantsAFeeDiscount() public setUpMarkets {
//         // register an affiliate code
//         // create a position
//         // use the fee estimation calculation to compare
//         // a) the fee with the affiliate code
//         // b) the fee without the affiliate code

//         // register an affiliate code from the owner
//         bytes32 code = keccak256(abi.encode("CODE"));
//         vm.prank(OWNER);
//         referralStorage.registerCode(code);

//         Position.Input memory input = Position.Input({
//             assetId: ethAssetId,
//             collateralToken: weth,
//             collateralDelta: 0.5 ether,
//             sizeDelta: 10_000e30,
//             limitPrice: 0,
//             maxSlippage: 0.4e30,
//             executionFee: 0.01 ether,
//             isLong: true,
//             isLimit: false,
//             isIncrease: true,
//             reverseWrap: true,
//             conditionals: Position.Conditionals({
//                 stopLossSet: false,
//                 takeProfitSet: false,
//                 stopLossPrice: 0,
//                 takeProfitPrice: 0,
//                 stopLossPercentage: 0,
//                 takeProfitPercentage: 0
//             })
//         });

//         uint256 fee = Position.calculateFee(tradeStorage, input.sizeDelta, input.collateralDelta, 1e18, 1e6);

//         (uint256 feeWithoutReferralCode,,) = Referral.applyFeeDiscount(referralStorage, USER, fee);

//         // set the referral code for the user
//         vm.prank(USER);
//         referralStorage.setTraderReferralCodeByUser(code);

//         (uint256 feeWithReferralCode,,) = Referral.applyFeeDiscount(referralStorage, USER, fee);

//         assertGt(feeWithoutReferralCode, feeWithReferralCode);
//     }

//     /**
//      * audit - What happened to the 4 wei
//      *     - Why is the user not receiving their funds
//      */
//     function testReceivingReferralRewardsFromAnAffiliateAccount() public setUpMarkets {
//         // register an affiliate code
//         bytes32 code = keccak256(abi.encode("CODE"));
//         vm.prank(OWNER);
//         referralStorage.registerCode(code);
//         // set the referral code for the user
//         vm.prank(USER);
//         referralStorage.setTraderReferralCodeByUser(code);
//         // open a position from the user with the fee discount applied
//         Position.Input memory input = Position.Input({
//             assetId: ethAssetId,
//             collateralToken: weth,
//             collateralDelta: 0.5 ether,
//             sizeDelta: 10_000e30,
//             limitPrice: 0,
//             maxSlippage: 0.4e30,
//             executionFee: 0.01 ether,
//             isLong: true,
//             isLimit: false,
//             isIncrease: true,
//             reverseWrap: true,
//             conditionals: Position.Conditionals({
//                 stopLossSet: false,
//                 takeProfitSet: false,
//                 stopLossPrice: 0,
//                 takeProfitPrice: 0,
//                 stopLossPercentage: 0,
//                 takeProfitPercentage: 0
//             })
//         });
//         vm.prank(USER);
//         router.createPositionRequest{value: 0.51 ether}(input);
//         // execute the position
//         bytes32 orderKey = tradeStorage.getOrderAtIndex(0, false);
//         vm.prank(OWNER);
//         positionManager.executePosition{value: 0.0001 ether}(market, orderKey, OWNER);
//         // check and claim the affiliate rewards from the owner
//         assertGt(referralStorage.getClaimableAffiliateRewards(OWNER, true), 0, "Owner should have claimable rewards");
//         uint256 balBeforeClaim = WETH(weth).balanceOf(OWNER);
//         vm.prank(OWNER);
//         referralStorage.claimAffiliateRewards();
//         assertEq(referralStorage.getClaimableAffiliateRewards(OWNER, true), 0, "Owner should have no claimable rewards");
//         assertGt(WETH(weth).balanceOf(OWNER), balBeforeClaim, "Owner should have received rewards");
//     }

//     function testIfAPositionRequestIsCancelledAffiliateRewardsCantbeClaimed() public setUpMarkets {
//         // register an affiliate code
//         bytes32 code = keccak256(abi.encode("CODE"));
//         vm.prank(OWNER);
//         referralStorage.registerCode(code);
//         // set the referral code for the user
//         vm.prank(USER);
//         referralStorage.setTraderReferralCodeByUser(code);
//         // open a position from the user with the fee discount applied
//         Position.Input memory input = Position.Input({
//             assetId: ethAssetId,
//             collateralToken: weth,
//             collateralDelta: 0.5 ether,
//             sizeDelta: 10_000e30,
//             limitPrice: 0,
//             maxSlippage: 0.4e30,
//             executionFee: 0.01 ether,
//             isLong: true,
//             isLimit: false,
//             isIncrease: true,
//             reverseWrap: true,
//             conditionals: Position.Conditionals({
//                 stopLossSet: false,
//                 takeProfitSet: false,
//                 stopLossPrice: 0,
//                 takeProfitPrice: 0,
//                 stopLossPercentage: 0,
//                 takeProfitPercentage: 0
//             })
//         });
//         vm.prank(USER);
//         router.createPositionRequest{value: 0.51 ether}(input);
//         // execute the position
//         bytes32 orderKey = tradeStorage.getOrderAtIndex(0, false);
//         // check and claim the affiliate rewards from the owner
//         vm.prank(OWNER);
//         positionManager.cancelOrderRequest(market, orderKey, false);
//         assertEq(referralStorage.getClaimableAffiliateRewards(OWNER, true), 0);
//     }
// }
