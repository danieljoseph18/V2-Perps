// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {FunctionsClient} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/FunctionsClient.sol";
import {FunctionsRequest} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/libraries/FunctionsRequest.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {RoleValidation} from "../access/RoleValidation.sol";
import {IMarketFactory} from "../markets/interfaces/IMarketFactory.sol";
import {IPriceFeed} from "./interfaces/IPriceFeed.sol";
import {ISwapRouter} from "./interfaces/ISwapRouter.sol";
import {IUniswapV3Factory} from "./interfaces/IUniswapV3Factory.sol";
import {IWETH} from "../tokens/interfaces/IWETH.sol";
import {AggregatorV2V3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV2V3Interface.sol";
import {Oracle} from "./Oracle.sol";

/// @dev - Needs LINK / subscription to fulfill requests -> need to put this cost onto users
// @audit - needs to be upgradeable for new releases of Chainlink Functions
contract PriceFeed is FunctionsClient, RoleValidation, IPriceFeed {
    using FunctionsRequest for FunctionsRequest.Request;
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using EnumerableSet for EnumerableSet.AddressSet;

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
    constructor(
        address _marketFactory,
        address _weth,
        address _link,
        address _uniV3Router,
        address _uniV3Factory,
        uint64 _subId,
        bytes32 _donId,
        address _router,
        address _roleStorage
    ) FunctionsClient(_router) RoleValidation(_roleStorage) {
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
    ) external onlyAdmin {
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

    function updateSubscriptionId(uint64 _subId) external onlyAdmin {
        subscriptionId = _subId;
    }

    function updateBillingParameters(
        uint256 _gasOverhead,
        uint32 _callbackGasLimit,
        uint256 _premiumFee,
        uint256 _fallbackWeiToLinkRatio,
        address _nativeLinkPriceFeed
    ) external onlyAdmin {
        gasOverhead = _gasOverhead;
        callbackGasLimit = _callbackGasLimit;
        premiumFee = _premiumFee;
        fallbackWeiToLinkRatio = _fallbackWeiToLinkRatio;
        nativeLinkPriceFeed = _nativeLinkPriceFeed;
    }

    function setJavascriptSourceCode(string memory _priceUpdateSource, string memory _cumulativePnlSource)
        external
        onlyAdmin
    {
        priceUpdateSource = _priceUpdateSource;
        cumulativePnlSource = _cumulativePnlSource;
    }

    function supportAsset(string memory _ticker, uint256 _baseUnit) external onlyMarketFactory {
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

    function setTimeToExpiration(uint256 _timeToExpiration) external onlyAdmin {
        timeToExpiration = _timeToExpiration;
    }

    function clearInvalidRequest(bytes32 _requestId) external onlyAdmin {
        if (requestIds.contains(_requestId)) {
            if (!requestIds.remove(_requestId)) revert PriceFeed_FailedToClearRequest();
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
        onlyRouter
        returns (bytes32 requestId)
    {
        Oracle.isSequencerUp(this);
        // (Index Token), Long Token, Short Token
        if (args.length != 3 || args.length != 2) revert PriceFeed_PriceUpdateLength();
        // Convert ETH into Link
        _convertEthToLink(msg.value);
        // Initialize the request
        FunctionsRequest.Request memory req;
        req.initializeRequestForInlineJavaScript(priceUpdateSource); // Initialize the request with JS code
        req.setArgs(args); // Set the arguments for the request

        // Send the request and store the request ID
        requestId = _sendRequest(req.encodeCBOR(), subscriptionId, callbackGasLimit, DON_ID);

        requestData[requestId].requestType = RequestType.PRICE_UPDATE;
        requestData[requestId].requester = _requester;

        requestIds.add(requestId);

        return requestId;
    }

    /// @dev - for this, we need to copy / call the function MarketUtils.calculateCumulativeMarketPnl but offchain
    function requestCumulativeMarketPnl(IMarket market, address _requester)
        external
        payable
        onlyRouter
        returns (bytes32 requestId)
    {
        // Need to check the market is valid
        // If the market is not valid, revert
        if (!marketFactory.isMarket(address(market))) revert PriceFeed_InvalidMarket();

        // Convert ETH into Link
        _convertEthToLink(msg.value);

        // get all of the assets from the market
        // pass the assets to the request as args
        // convert assets to a string
        string[] memory tickers = market.getTickers();

        FunctionsRequest.Request memory req;
        req.initializeRequestForInlineJavaScript(cumulativePnlSource); // Initialize the request with JS code
        if (tickers.length > 0) req.setArgs(tickers); // Set the arguments for the request

        // Send the request and store the request ID
        requestId = _sendRequest(req.encodeCBOR(), subscriptionId, callbackGasLimit, DON_ID);

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
    // Try to avoid reverting, and instead return without storing the price response if invalid.
    function fulfillRequest(bytes32 requestId, bytes memory response, bytes memory err) internal override {
        // Return if invalid requestId
        if (!requestIds.contains(requestId)) return;
        // Return if an error is thrown
        if (err.length > 0) return;
        // Remove the RequestId from storage and return if fail
        bool success = requestIds.remove(requestId);
        if (!success) return;
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
        if (!marketFactory.isMarket(address(market))) revert PriceFeed_InvalidMarket();
        delete cumulativePnl[_requestId];
        emit PnlCleared(address(market));
    }

    function estimateRequestCost() external view returns (uint256) {
        // Get the current gas price
        uint256 gasPrice = tx.gasprice;

        // Calculate the overestimated gas price
        uint256 overestimatedGasPrice = gasPrice * 110 / 100;

        // Calculate the total estimated gas cost in native units
        uint256 totalEstimatedGasCost = overestimatedGasPrice * (gasOverhead + callbackGasLimit);

        // Convert the total estimated gas cost to LINK using the price feed or fallback ratio
        uint256 totalEstimatedGasCostInLink;
        try AggregatorV2V3Interface(nativeLinkPriceFeed).latestAnswer() returns (int256 answer) {
            totalEstimatedGasCostInLink = totalEstimatedGasCost * uint256(answer) / 1e18;
        } catch {
            totalEstimatedGasCostInLink = totalEstimatedGasCost / fallbackWeiToLinkRatio;
        }

        // Add the premium fee to get the total estimated cost in LINK
        uint256 totalEstimatedCost = totalEstimatedGasCostInLink + premiumFee;

        return totalEstimatedCost;
    }

    /**
     * When Ether is received, it needs to be swapped for LINK to pay for the fee of the request.
     * The execution fee should be sufficient to cover the cost of the request in LINK.
     */
    function _convertEthToLink(uint256 _ethAmount) internal {
        // Get the Uniswap V3 router instance
        ISwapRouter uniswapRouter = ISwapRouter(UNISWAP_V3_ROUTER);

        // Calculate the amount of Ether received
        uint256 ethAmount = _ethAmount;

        // Approve the router to spend ETH
        IWETH(WETH).deposit{value: ethAmount}();
        IWETH(WETH).approve(address(uniswapRouter), ethAmount);

        // Set the path for the swap (WETH -> LINK)
        address[] memory path = new address[](2);
        path[0] = WETH;
        path[1] = LINK;

        // Set the fee tier for the pool (e.g., 0.3% fee tier)
        uint24 feeTier = 3000;

        // Swap WETH for LINK
        uniswapRouter.exactInput(
            ISwapRouter.ExactInputParams({
                path: abi.encodePacked(path[0], feeTier, path[1]),
                recipient: address(this),
                deadline: block.timestamp + 1800,
                amountIn: ethAmount,
                amountOutMinimum: 0
            })
        );
    }

    function getPrices(bytes32 _requestId, string memory _ticker) external view returns (Price memory signedPrices) {
        signedPrices = prices[_requestId][_ticker];
        if (signedPrices.med == 0) revert PriceFeed_PriceNotSigned();
        if (signedPrices.expirationTimestamp < block.timestamp) revert PriceFeed_PriceExpired();
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

    function getRequests() external view returns (bytes32[] memory) {
        return requestIds.values();
    }
}
