// // SPDX-License-Identifier: MIT
// pragma solidity 0.8.23;

// import {Script} from "forge-std/Script.sol";
// import {MarketFactory, IMarketFactory} from "src/factory/MarketFactory.sol";
// import {MockPriceFeed, IPriceFeed} from "test/mocks/MockPriceFeed.sol";
// import {Oracle} from "src/oracle/Oracle.sol";

// contract CreateMarket is Script {
//     MarketFactory marketFactory = MarketFactory(0xDe8304b5399A6f37168Fa1F01D43A2f7f3c43100);
//     MockPriceFeed priceFeed = MockPriceFeed(0x16F39051d2315Da24AC9c10B5193b45796010eB6);

//     bool isMultiAsset = true;
//     string ticker = "ETH";
//     string name = "XYZ";
//     string symbol = "XYZ";
//     bool hasSecondaryStrategy = false;
//     IPriceFeed.FeedType feedType = IPriceFeed.FeedType.CHAINLINK;
//     address feedAddress = address(0);
//     bytes32 feedId = bytes32(0);
//     bytes32[] merkleProof = new bytes32[](0);

//     function run() public {
//         vm.startBroadcast();
//         bytes32 requestKey = marketFactory.createNewMarket{value: 0.0001 ether}(
//             IMarketFactory.Input(
//                 isMultiAsset,
//                 ticker,
//                 name,
//                 symbol,
//                 IPriceFeed.SecondaryStrategy({
//                     exists: hasSecondaryStrategy,
//                     feedType: feedType,
//                     feedAddress: feedAddress,
//                     feedId: feedId,
//                     merkleProof: merkleProof
//                 })
//             )
//         );
//         IMarketFactory.Request memory request = marketFactory.getRequest(requestKey);

//         string[] memory tickers = new string[](2);
//         tickers[0] = "ETH";
//         tickers[1] = "USDC";

//         uint8[] memory precisions = new uint8[](2);
//         precisions[0] = 0;
//         precisions[1] = 0;

//         uint16[] memory variances = new uint16[](2);
//         variances[0] = 0;
//         variances[1] = 0;

//         uint48[] memory timestamps = new uint48[](2);
//         timestamps[0] = request.requestTimestamp;
//         timestamps[1] = request.requestTimestamp;

//         uint64[] memory medians = new uint64[](2);
//         medians[0] = 3000;
//         medians[1] = 1;

//         bytes memory encodedPrices = priceFeed.encodePrices(tickers, precisions, variances, timestamps, medians);

//         priceFeed.updatePrices(encodedPrices);

//         marketFactory.executeMarketRequest(requestKey);
//         vm.stopBroadcast();
//     }
// }
