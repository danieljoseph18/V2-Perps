// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {FunctionsClient} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/FunctionsClient.sol";
import {FunctionsRequest} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/libraries/FunctionsRequest.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {RoleValidation} from "../access/RoleValidation.sol";
import {IMarketMaker} from "../markets/interfaces/IMarketMaker.sol";
import {IPriceFeed} from "./interfaces/IPriceFeed.sol";

/// @dev - Needs LINK / subscription to fulfill requests -> need to put this cost onto users
// @audit - how do we estimate the cost of fulfilling requests?
// @audit - what happens if a price expires? How do you update the price once again to execute the request?
// @audit - needs to be upgradeable for new releases of Chainlink Functions
// @audit - how do we put this cost onto users
// @audit - probably need an expiry on the validity of price requests
contract PriceFeed is FunctionsClient, RoleValidation, IPriceFeed {
    using FunctionsRequest for FunctionsRequest.Request;
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using EnumerableSet for EnumerableSet.AddressSet;

    uint256 public constant PRICE_DECIMALS = 30;

    IMarketMaker public marketMaker;

    // Router address - Hardcoded for Sepolia
    // Check to get the router address for your supported network https://docs.chain.link/chainlink-functions/supported-networks
    address router = 0xb83E47C2bC239B3bf370bc41e1459A34b41238D0;
    address public sequencerUptimeFeed;
    uint64 subscriptionId;

    // JavaScript source code
    // Hard code the javascript source code here for each request's execution function
    string priceUpdateSource = "";
    string cumulativePnlSource = "";

    uint256 public averagePriceUpdateCost;
    uint256 public additionalCostPerAsset;

    //Callback gas limit
    uint32 priceGasLimit = 300000;
    uint32 cumulativePnlGasLimit = 600000;

    // donID - Hardcoded for Sepolia
    // Check to get the donID for your supported network https://docs.chain.link/chainlink-functions/supported-networks
    bytes32 donID = 0x66756e2d657468657265756d2d7365706f6c69612d3100000000000000000000;

    // State variable to store the returned character information
    mapping(bytes32 requestId => mapping(string ticker => Price priceResponse)) private prices;
    mapping(bytes32 requestId => string[] tickers) assetsWithPrices;
    mapping(bytes32 requestId => Pnl cumulativePnl) public cumulativePnl;
    // store who requested the data and what type of data was requested
    // only the keeper who requested can fill the order for non market orders
    // all pricing should be cleared once the request is filled
    // data should be tied only to the request as its specific to the request
    mapping(bytes32 requestId => RequestData requestData) public requestData;
    mapping(string ticker => uint256 baseUnit) public baseUnits;
    // Can probably purge some of these
    EnumerableSet.Bytes32Set private requestIds;
    EnumerableSet.Bytes32Set private assetIds;

    /**
     * @notice Initializes the contract with the Chainlink router address and sets the contract owner
     */
    constructor(address _marketMaker, uint64 _subId, address _roleStorage)
        FunctionsClient(router)
        RoleValidation(_roleStorage)
    {
        subscriptionId = _subId;
        marketMaker = IMarketMaker(_marketMaker);
    }

    function updateSubscriptionId(uint64 _subId) external onlyAdmin {
        subscriptionId = _subId;
    }

    function updateGasLimits(uint32 _priceGasLimit, uint32 _cumulativePnlGasLimit) external onlyAdmin {
        priceGasLimit = _priceGasLimit;
        cumulativePnlGasLimit = _cumulativePnlGasLimit;
    }

    // @audit - can probably remove / edit -> will be a fixed amount of gas for both actions
    function setAverageGasParameters(uint256 _averagePriceUpdateCost, uint256 _additionalCostPerAsset)
        external
        onlyAdmin
    {
        if (_averagePriceUpdateCost == 0 || _additionalCostPerAsset == 0) revert PriceFeed_InvalidGasParams();
        averagePriceUpdateCost = _averagePriceUpdateCost;
        additionalCostPerAsset = _additionalCostPerAsset;
    }

    function supportAsset(string memory _ticker, uint256 _baseUnit) external onlyMarketMaker {
        bytes32 assetId = keccak256(abi.encode(_ticker));
        if (assetIds.contains(assetId)) return; // Return if already supported
        bool success = assetIds.add(assetId);
        if (!success) revert PriceFeed_AssetSupportFailed();
        baseUnits[_ticker] = _baseUnit;
        emit AssetSupported(_ticker, _baseUnit);
    }

    function unsupportAsset(string memory _ticker) external onlyAdmin {
        bytes32 assetId = keccak256(abi.encode(_ticker));
        if (!assetIds.contains(assetId)) return; // Return if not supported
        bool success = assetIds.remove(assetId);
        if (!success) revert PriceFeed_AssetRemovalFailed();
        delete baseUnits[_ticker];
        emit SupportRemoved(_ticker);
    }

    function updateSequencerUptimeFeed(address _sequencerUptimeFeed) external onlyAdmin {
        sequencerUptimeFeed = _sequencerUptimeFeed;
    }

    /**
     * @notice Sends an HTTP request for character information
     * @param args The arguments to pass to the HTTP request -> should be the tickers for which pricing is requested
     * @return requestId The ID of the request
     */
    // @audit - contract needs a way to differentiate between different types of requests
    // @audit - permissions?
    function requestPriceUpdate(string[] calldata args, address _requester)
        external
        onlyRouter
        returns (bytes32 requestId)
    {
        // (Index Token), Long Token, Short Token
        if (args.length != 3 || args.length != 2) revert PriceFeed_PriceUpdateLength();
        // Initialize the request
        FunctionsRequest.Request memory req;
        req.initializeRequestForInlineJavaScript(priceUpdateSource); // Initialize the request with JS code
        req.setArgs(args); // Set the arguments for the request

        // Send the request and store the request ID
        requestId = _sendRequest(req.encodeCBOR(), subscriptionId, priceGasLimit, donID);

        requestData[requestId].requestType = RequestType.PRICE_UPDATE;
        requestData[requestId].requester = _requester;

        requestIds.add(requestId);

        return requestId;
    }

    // @audit - for this, we need to copy / call the function calculateCumulativeMarketPnl but offchain
    function requestCumulativeMarketPnl(IMarket market, address _requester)
        external
        onlyRouter
        returns (bytes32 requestId)
    {
        // Need to check the market is valid
        // If the market is not valid, revert
        if (!marketMaker.isMarket(address(market))) revert PriceFeed_InvalidMarket();

        // get all of the assets from the market
        // pass the assets to the request as args
        // convert assets to a string
        string[] memory tickers = market.getTickers();

        FunctionsRequest.Request memory req;
        req.initializeRequestForInlineJavaScript(cumulativePnlSource); // Initialize the request with JS code
        if (tickers.length > 0) req.setArgs(tickers); // Set the arguments for the request

        // Send the request and store the request ID
        requestId = _sendRequest(req.encodeCBOR(), subscriptionId, cumulativePnlGasLimit, donID);

        requestData[requestId].requestType = RequestType.CUMULATIVE_PNL;
        requestData[requestId].requester = _requester;

        requestIds.add(requestId);

        return requestId;
    }

    /**
     * @notice Callback function for fulfilling a request
     * @param requestId The ID of the request to fulfill
     * @param response The HTTP response data
     * @param err Any errors from the Functions request
     */
    // Decode the response, according to the structure of the request
    // @audit - need to check the response's validity
    function fulfillRequest(bytes32 requestId, bytes memory response, bytes memory err) internal override {
        // @audit - probably shouldn't revert
        if (!requestIds.contains(requestId)) revert PriceFeed_UnexpectedRequestID(requestId); // Check if request IDs match
        // Remove the request ID if there are no errors
        // @audit - callback probably shouldn't revert
        if (err.length == 0) requestIds.remove(requestId);
        else revert PriceFeed_FulfillmentFailed(string(err));
        // Get the request type of the request
        RequestData memory data = requestData[requestId];
        if (data.requestType == RequestType.PRICE_UPDATE) {
            // Fulfill the price update request
            UnpackedPriceResponse[] memory unpackedResponse = abi.decode(response, (UnpackedPriceResponse[]));
            uint256 len = unpackedResponse.length;
            for (uint256 i = 0; i < len;) {
                uint256 compactedPriceData = unpackedResponse[i].compactedPrices;

                Price storage price = prices[requestId][unpackedResponse[i].ticker];

                // Prices compacted as: uint64 minPrice, uint64 medPrice, uint64 maxPrice, uint8 priceDecimals
                // use bitshifting to unpack the prices
                uint256 decimals = (compactedPriceData >> 192) & 0xFF;
                price.min = (compactedPriceData & 0xFFFFFFFF) * (10 ** (PRICE_DECIMALS - decimals));
                price.med = ((compactedPriceData >> 64) & 0xFFFFFFFF) * (10 ** (PRICE_DECIMALS - decimals));
                price.max = ((compactedPriceData >> 128) & 0xFFFFFFFF) * (10 ** (PRICE_DECIMALS - decimals));
                price.timestamp = block.timestamp;

                // Add the asset to the list of assets with prices
                assetsWithPrices[requestId].push(unpackedResponse[i].ticker);

                unchecked {
                    ++i;
                }
            }
        } else if (data.requestType == RequestType.CUMULATIVE_PNL) {
            // Fulfill the cumulative pnl request
            UnpackedPnlResponse memory unpackedResponse = abi.decode(response, (UnpackedPnlResponse));
            cumulativePnl[requestId].cumulativePnl = unpackedResponse.cumulativePnl;
            cumulativePnl[requestId].wasSigned = true;
        } else {
            revert PriceFeed_InvalidRequestType();
        }

        // Emit an event to log the response
        emit Response(requestId, data, response, err);
    }

    function clearSignedPrices(IMarket market, bytes32 _requestId) external onlyTradeStorageOrMarket(address(market)) {
        // loop through the assets with prices and clear them from storage
        string[] memory assets = assetsWithPrices[_requestId];
        uint256 len = assets.length;
        for (uint256 i = 0; i < len;) {
            // Can pop in any order as assets isn't a storage ref
            assetsWithPrices[_requestId].pop();
            delete prices[_requestId][assets[i]];
            unchecked {
                ++i;
            }
        }
        emit AssetPricesCleared();
    }

    function clearCumulativePnl(IMarket market, bytes32 _requestId) external onlyMarket(address(market)) {
        if (!marketMaker.isMarket(address(market))) revert PriceFeed_InvalidMarket();
        delete cumulativePnl[_requestId];
        emit PnlCleared(address(market));
    }

    function getPrices(bytes32 _requestId, string memory _ticker) external view returns (Price memory signedPrices) {
        signedPrices = prices[_requestId][_ticker];
        if (signedPrices.med == 0) revert PriceFeed_PriceNotSigned();
    }

    function getCumulativePnl(bytes32 _requestId) external view returns (int256 pnl) {
        pnl = cumulativePnl[_requestId].cumulativePnl;
        if (!cumulativePnl[_requestId].wasSigned) revert PriceFeed_PnlNotSigned();
    }

    function priceUpdateRequested(bytes32 _requestId) external view returns (bool) {
        return requestData[_requestId].requester != address(0);
    }

    function getRequester(bytes32 _requestId) external view returns (address) {
        return requestData[_requestId].requester;
    }
}
