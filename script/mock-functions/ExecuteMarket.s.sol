// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Script.sol";
import {MarketFactory, IMarketFactory} from "src/factory/MarketFactory.sol";
import {MockPriceFeed, IPriceFeed} from "test/mocks/MockPriceFeed.sol";
import {Oracle} from "src/oracle/Oracle.sol";

contract ExecuteMarket is Script {
    MarketFactory marketFactory = MarketFactory(0x4Ed726bE48746894b6AC69602F7CE5A78a8267eF);
    MockPriceFeed priceFeed = MockPriceFeed(0x9d3A72Ddd46B53C84cc12F7DeFdbC3d99ca4d46D);
    bytes32 requestKey = 0x0b04b6d0eaf6acb449b5cedab4fe0567a091585146ff04e0e7b318c7154ba3ad;

    string[] tickers;

    uint8[] precisions;
    uint16[] variances;
    uint48[] timestamps;
    uint64[] meds;

    // Create Market Params example
    // [true,"ETH","BRRR","BRRR",[false,"0","0x0000000000000000000000000000000000000000","0x0000000000000000000000000000000000000000000000000000000000000000",[]]]
    function run() external {
        // Get the request
        IMarketFactory.Request memory request = marketFactory.getRequest(requestKey);
        // Set Prices
        precisions.push(0);
        precisions.push(0);
        variances.push(0);
        variances.push(0);
        timestamps.push(request.requestTimestamp);
        timestamps.push(request.requestTimestamp);
        meds.push(3000);
        meds.push(1);
        tickers.push("ETH");
        tickers.push("USDC");

        bytes memory encodedPrices = priceFeed.encodePrices(tickers, precisions, variances, timestamps, meds);

        priceFeed.updatePrices(encodedPrices);

        bytes32[] memory requestKeys = marketFactory.getRequestKeys();
        require(requestKeys.length > 0, "No request keys found");
        require(requestKeys[0] != bytes32(0), "No request keys found");

        marketFactory.executeMarketRequest(requestKeys[0]);

        vm.stopBroadcast();
    }
}
