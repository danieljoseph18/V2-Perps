// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {FunctionsClient} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/FunctionsClient.sol";
import {FunctionsRequest} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/libraries/FunctionsRequest.sol";
import {IMarket} from "../../../src/markets/interfaces/IMarket.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {EnumerableMap} from "../../../src/libraries/EnumerableMap.sol";
import {IMarketFactory} from "../../../src/markets/interfaces/IMarketFactory.sol";
import {IPriceFeed} from "../../../src/oracle/interfaces/IPriceFeed.sol";
import {ISwapRouter} from "../../src/oracle/interfaces/ISwapRouter.sol";
import {IUniswapV3Factory} from "../../src/oracle/interfaces/IUniswapV3Factory.sol";
import {IWETH} from "../../src/tokens/interfaces/IWETH.sol";
import {AggregatorV2V3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV2V3Interface.sol";
import {Oracle} from "../../src/oracle/Oracle.sol";

contract MockPriceFeed is FunctionsClient, IPriceFeed {
    using FunctionsRequest for FunctionsRequest.Request;
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using EnumerableMap for EnumerableMap.PriceRequestMap;

    uint256 public constant PRICE_DECIMALS = 30;
    // Uniswap V3 Router address on Network
    address public immutable UNISWAP_V3_ROUTER;
    // Uniswap V3 Factory address on Network
    address public immutable UNISWAP_V3_FACTORY;
    // WETH address on Network
    address public immutable WETH;
    // LINK address on Network
    address public immutable LINK;
    // donID - Sepolia = 0x66756e2d657468657265756d2d7365706f6c69612d3100000000000000000000
    // Check to get the donID for your supported network https://docs.chain.link/chainlink-functions/supported-networks
    bytes32 private immutable DON_ID;
    // Router address - Hardcoded for Sepolia = 0xb83E47C2bC239B3bf370bc41e1459A34b41238D0
    // Check to get the router address for your supported network https://docs.chain.link/chainlink-functions/supported-networks
    address private immutable ROUTER;

    IMarketFactory public marketFactory;

    address public sequencerUptimeFeed;
    uint64 subscriptionId;
    bool private isInitialized;

    // JavaScript source code
    // Hard code the javascript source code here for each request's execution function
    /**
     * Price Sources:
     * - Aggregate CEXs
     * - CryptoCompare
     * - CMC / CoinGecko
     */
    string priceUpdateSource = "";
    string cumulativePnlSource = "";

    //Callback gas limit
    uint256 public gasOverhead;
    uint256 public premiumFee;
    uint256 public fallbackWeiToLinkRatio;
    address public nativeLinkPriceFeed;
    uint32 public callbackGasLimit;
    uint256 public timeToExpiration;

    // State variable to store the returned character information
    mapping(bytes32 requestId => mapping(string ticker => Price priceResponse)) private prices;
    mapping(bytes32 requestId => string[] tickers) assetsWithPrices;
    mapping(bytes32 requestId => Pnl cumulativePnl) public cumulativePnl;
    // store who requested the data and what type of data was requested
    //  keeper who requested can fill the order for non market orders
    // all pricing should be cleared once the request is filled
    // data should be tied  the request as its specific to the request
    mapping(string ticker => uint256 baseUnit) public baseUnits;
    // Can probably purge some of these
    EnumerableMap.PriceRequestMap private requestData;
    EnumerableSet.Bytes32Set private assetIds;

    /**
     * @notice Initializes the contract with the Chainlink router address and sets the contract owner
     */
    constructor(
        address _marketFactory,
        address _weth,
        address _link,
        address _uniV3Router,
        address _uniV3Factory,
        uint64 _subId,
        bytes32 _donId,
        address _router
    ) FunctionsClient(_router) {
        marketFactory = IMarketFactory(_marketFactory);
        WETH = _weth;
        LINK = _link;
        UNISWAP_V3_ROUTER = _uniV3Router;
        UNISWAP_V3_FACTORY = _uniV3Factory;
        subscriptionId = _subId;
        DON_ID = _donId;
        ROUTER = _router;
    }

    function initialize(
        uint256 _gasOverhead,
        uint32 _callbackGasLimit,
        uint256 _premiumFee,
        uint256 _fallbackWeiToLinkRatio,
        address _nativeLinkPriceFeed,
        address _sequencerUptimeFeed,
        uint256 _timeToExpiration
    ) external {
        if (isInitialized) revert PriceFeed_AlreadyInitialized();
        gasOverhead = _gasOverhead;
        callbackGasLimit = _callbackGasLimit;
        premiumFee = _premiumFee;
        fallbackWeiToLinkRatio = _fallbackWeiToLinkRatio;
        nativeLinkPriceFeed = _nativeLinkPriceFeed;
        sequencerUptimeFeed = _sequencerUptimeFeed;
        timeToExpiration = _timeToExpiration;
        isInitialized = true;
    }

    function updateSubscriptionId(uint64 _subId) external {
        subscriptionId = _subId;
    }

    function updateBillingParameters(
        uint256 _gasOverhead,
        uint32 _callbackGasLimit,
        uint256 _premiumFee,
        uint256 _fallbackWeiToLinkRatio,
        address _nativeLinkPriceFeed
    ) external {
        gasOverhead = _gasOverhead;
        callbackGasLimit = _callbackGasLimit;
        premiumFee = _premiumFee;
        fallbackWeiToLinkRatio = _fallbackWeiToLinkRatio;
        nativeLinkPriceFeed = _nativeLinkPriceFeed;
    }

    function setJavascriptSourceCode(string memory _priceUpdateSource, string memory _cumulativePnlSource) external {
        priceUpdateSource = _priceUpdateSource;
        cumulativePnlSource = _cumulativePnlSource;
    }

    function supportAsset(string memory _ticker, uint256 _baseUnit) external {
        bytes32 assetId = keccak256(abi.encode(_ticker));
        if (assetIds.contains(assetId)) return; // Return if already supported
        bool success = assetIds.add(assetId);
        if (!success) revert PriceFeed_AssetSupportFailed();
        baseUnits[_ticker] = _baseUnit;
        emit AssetSupported(_ticker, _baseUnit);
    }

    function unsupportAsset(string memory _ticker) external {
        bytes32 assetId = keccak256(abi.encode(_ticker));
        if (!assetIds.contains(assetId)) return; // Return if not supported
        bool success = assetIds.remove(assetId);
        if (!success) revert PriceFeed_AssetRemovalFailed();
        delete baseUnits[_ticker];
        emit SupportRemoved(_ticker);
    }

    function updateSequencerUptimeFeed(address _sequencerUptimeFeed) external {
        sequencerUptimeFeed = _sequencerUptimeFeed;
    }

    function setTimeToExpiration(uint256 _timeToExpiration) external {
        timeToExpiration = _timeToExpiration;
    }

    function clearInvalidRequest(bytes32 _requestId) external {
        if (requestData.contains(_requestId)) {
            if (!requestData.remove(_requestId)) revert PriceFeed_FailedToClearRequest();
        }
    }

    /**
     * @notice Sends an HTTP request for character information
     * @param args The arguments to pass to the HTTP request -> should be the tickers for which pricing is requested
     * @return requestId The ID of the request
     */
    function requestPriceUpdate(string[] calldata args, address _requester)
        external
        payable
        returns (bytes32 requestId)
    {
        args;
        // Create a  request id
        requestId = keccak256(abi.encode("PRICE REQUEST"));

        RequestData memory data = RequestData({requester: _requester, requestType: RequestType.PRICE_UPDATE});

        requestData.set(requestId, data);

        return requestId;
    }

    /// @dev - for this, we need to copy / call the function MarketUtils.calculateCumulativeMarketPnl but offchain
    function requestCumulativeMarketPnl(IMarket, address _requester) external payable returns (bytes32 requestId) {
        // Create a  request id
        requestId = keccak256(abi.encode("PNL REQUEST"));

        RequestData memory data = RequestData({requester: _requester, requestType: RequestType.CUMULATIVE_PNL});

        requestData.set(requestId, data);

        return requestId;
    }

    /**
     * @notice Callback function for fulfilling a request
     * @param requestId The ID of the request to fulfill
     * @param response The HTTP response data
     * @param err Any errors from the Functions request
     */
    // Decode the response, according to the structure of the request
    // Try to avoid reverting, and instead return without storing the price response if invalid.
    function fulfillRequest(bytes32 requestId, bytes memory response, bytes memory err) internal override {
        // Return if invalid requestId
        if (!requestData.contains(requestId)) return;
        // Return if an error is thrown
        if (err.length > 0) return;
        // Remove the RequestId from storage and return if fail
        bool success = requestData.remove(requestId);
        if (!success) return;
        // Get the request type of the request
        RequestData memory data = requestData.get(requestId);
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
                price.expirationTimestamp = block.timestamp + timeToExpiration;

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

    function clearSignedPrices(IMarket, bytes32) external {}

    function clearCumulativePnl(IMarket, bytes32) external {}

    function estimateRequestCost() external view returns (uint256) {
        return prices[bytes32(0)][""].min;
    }

    function getPrices(bytes32 _requestId, string memory _ticker) external view returns (Price memory signedPrices) {
        signedPrices = prices[_requestId][_ticker];
        if (signedPrices.med == 0) revert PriceFeed_PriceNotSigned();
    }

    function getCumulativePnl(bytes32 _requestId) external view returns (int256 pnl) {
        pnl = cumulativePnl[_requestId].cumulativePnl;
    }

    function priceUpdateRequested(bytes32 _requestId) external view returns (bool) {
        return requestData.get(_requestId).requester != address(0);
    }

    function getRequester(bytes32 _requestId) external view returns (address) {
        return requestData.get(_requestId).requester;
    }

    function getRequests() external view returns (bytes32[] memory) {
        return requestData.keys();
    }

    event PricesUpdated(bytes32 indexed requestId, string[] tickers, Price[] prices);

    // Used to Manually Set Prices for Testing
    function updatePrices(bytes32 _requestId, string[] calldata _tickers, Price[] calldata _prices) external {
        if (_tickers.length != _prices.length) revert PriceFeed_PriceUpdateLength();
        for (uint256 i = 0; i < _tickers.length;) {
            prices[_requestId][_tickers[i]] = _prices[i];
            assetsWithPrices[_requestId].push(_tickers[i]);
            unchecked {
                ++i;
            }
        }
        emit PricesUpdated(_requestId, _tickers, _prices);
    }

    event PnlUpdated(bytes32 indexed requestId, int256 pnl);

    // Used to Manually Set Pnl for Testing
    function updatePnl(IMarket market, int256 _pnl, bytes32 _requestId) external {
        if (!marketFactory.isMarket(address(market))) revert PriceFeed_InvalidMarket();
        cumulativePnl[_requestId] = Pnl(true, _pnl);
        emit PnlUpdated(_requestId, _pnl);
    }
}
