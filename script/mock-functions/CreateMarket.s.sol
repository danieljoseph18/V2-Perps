// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Script.sol";
import {MarketFactory, IMarketFactory} from "src/factory/MarketFactory.sol";
import {MockPriceFeed, IPriceFeed} from "test/mocks/MockPriceFeed.sol";
import {Oracle} from "src/oracle/Oracle.sol";

contract CreateMarket is Script {
    MarketFactory marketFactory = MarketFactory(0xC0a2caD2c63A98f6fcCF935516BE49b9a4D97A2e);
    MockPriceFeed priceFeed = MockPriceFeed(0xc7F60768C13B5781d29c606b7Da6b5f124B2b904);

    string[] tickers;

    uint8[] precisions;
    uint16[] variances;
    uint48[] timestamps;
    uint64[] meds;

    function run() external {
        // vm.startBroadcast();
        // IMarketFactory.Request memory request = IMarketFactory.Request({
        //     isMultiAsset: false,
        //     owner: msg.sender,
        //     indexTokenTicker: "ETH",
        //     marketTokenName: "BRRR",
        //     marketTokenSymbol: "BRRR",
        //     tokenData: IPriceFeed.TokenData(address(0), 18, IPriceFeed.FeedType.CHAINLINK, false),
        //     pythData: IMarketFactory.PythData({id: bytes32(0), merkleProof: new bytes32[](0)}),
        //     stablecoinMerkleProof: new bytes32[](0),
        //     requestTimestamp: uint48(block.timestamp)
        // });
        // uint256 fee = marketFactory.marketCreationFee() + Oracle.estimateRequestCost(priceFeed);
        // marketFactory.createNewMarket{value: fee}(request);
        // // Set Prices
        // precisions.push(0);
        // precisions.push(0);
        // variances.push(0);
        // variances.push(0);
        // timestamps.push(uint48(block.timestamp));
        // timestamps.push(uint48(block.timestamp));
        // meds.push(3000);
        // meds.push(1);
        // tickers.push("ETH");
        // tickers.push("USDC");
        // bytes memory encodedPrices = priceFeed.encodePrices(tickers, precisions, variances, timestamps, meds);
        // priceFeed.updatePrices(encodedPrices);
        // marketFactory.executeMarketRequest(marketFactory.getRequestKeys()[0]);
        // vm.stopBroadcast();
    }
}
