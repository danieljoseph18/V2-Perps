// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {FunctionsClient} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/FunctionsClient.sol";
import {FunctionsRequest} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/libraries/FunctionsRequest.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {EnumerableMap} from "../libraries/EnumerableMap.sol";
import {RoleValidation} from "../access/RoleValidation.sol";
import {IMarketFactory} from "../markets/interfaces/IMarketFactory.sol";
import {IPriceFeed} from "./interfaces/IPriceFeed.sol";
import {ISwapRouter} from "./interfaces/ISwapRouter.sol";
import {IUniswapV3Factory} from "./interfaces/IUniswapV3Factory.sol";
import {IWETH} from "../tokens/interfaces/IWETH.sol";
import {AggregatorV2V3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV2V3Interface.sol";
import {ReentrancyGuard} from "@solmate/utils/ReentrancyGuard.sol";
import {Oracle} from "./Oracle.sol";

/// @dev - Needs LINK / subscription to fulfill requests -> need to put this cost onto users
contract PriceFeed is FunctionsClient, ReentrancyGuard, RoleValidation, IPriceFeed {
    using FunctionsRequest for FunctionsRequest.Request;
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using EnumerableMap for EnumerableMap.PriceRequestMap;

    uint256 public constant PRICE_DECIMALS = 30;
    // Length of 1 Bytes32 Word
    uint8 private constant WORD = 32;
    uint8 private constant MIN_EXPIRATION_TIME = 2 minutes;
    uint40 private constant MSB1 = 0x8000000000;
    uint64 private constant LINK_BASE_UNIT = 1e18;
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
    mapping(string ticker => mapping(uint48 blockTimestamp => Price priceResponse)) private prices;
    mapping(address market => mapping(uint48 blockTimestamp => Pnl cumulativePnl)) public cumulativePnl;
    // store who requested the data and what type of data was requested
    // only the keeper who requested can fill the order for non market orders
    // all pricing should be cleared once the request is filled
    // data should be tied only to the request as its specific to the request
    mapping(string ticker => uint256 baseUnit) public baseUnits;
    /**
     * audit - to prevent multiple requests for the same action, we can perhaps store a generic
     * request signature. If a request already exists for the same action, we can prevent the
     * request from processing and save the end user some gas.
     */
    // Dictionary to enable clearing of the RequestKey
    mapping(bytes32 id => bytes32 key) private idToKey;
    EnumerableMap.PriceRequestMap private requestData;
    EnumerableSet.Bytes32Set private assetIds;
    EnumerableSet.Bytes32Set private requestKeys;

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
        onlyRouter
        nonReentrant
        returns (bytes32 requestId)
    {
        Oracle.isSequencerUp(this);
        // Compute the key and check if the same request exists
        bytes32 priceRequestKey = _generateKey(abi.encode(args, _requester, _blockTimestamp()));
        if (requestKeys.contains(priceRequestKey)) return bytes32(0);
        // Convert ETH into Link
        // @audit - convert to arbitrage version
        _convertEthToLink(msg.value);
        // Initialize the request
        FunctionsRequest.Request memory req;
        req.initializeRequestForInlineJavaScript(priceUpdateSource); // Initialize the request with JS code
        req.setArgs(args); // Set the arguments for the request

        // Send the request and store the request ID
        requestId = _sendRequest(req.encodeCBOR(), subscriptionId, callbackGasLimit, DON_ID);

        RequestData memory data = RequestData({
            requester: _requester,
            blockTimestamp: _blockTimestamp(),
            requestType: RequestType.PRICE_UPDATE
        });

        // Add the Request to Storage
        requestKeys.add(priceRequestKey);
        idToKey[requestId] = priceRequestKey;
        requestData.set(requestId, data);

        return requestId;
    }

    /// @dev - for this, we need to copy / call the function MarketUtils.calculateCumulativeMarketPnl but offchain
    function requestCumulativeMarketPnl(IMarket market, address _requester)
        external
        payable
        onlyRouter
        nonReentrant
        returns (bytes32 requestId)
    {
        // Need to check the market is valid
        // If the market is not valid, revert
        if (!marketFactory.isMarket(address(market))) revert PriceFeed_InvalidMarket();
        // Compute the key and check if the same request exists
        bytes32 cumulativePnlRequestKey = _generateKey(abi.encode(market, _requester, _blockTimestamp()));
        if (requestKeys.contains(cumulativePnlRequestKey)) return bytes32(0);

        // @audit - convert to arbitrage version
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

        RequestData memory data = RequestData({
            requester: _requester,
            blockTimestamp: _blockTimestamp(),
            requestType: RequestType.CUMULATIVE_PNL
        });

        // Add the Request to Storage
        requestKeys.add(cumulativePnlRequestKey);
        idToKey[requestId] = cumulativePnlRequestKey;
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
    // @audit - what if the request for the block failed --> how can users price their assets?
    // @audit - what if the data is already in storage? How do we prevent the consumer from running?
    function fulfillRequest(bytes32 requestId, bytes memory response, bytes memory err) internal override {
        // Return if invalid requestId
        if (!requestData.contains(requestId)) return;
        // Return if an error is thrown
        // @audit - What if an error is thrown but the response is still valid?
        if (err.length > 0) return;
        // Remove the RequestId from storage and return if fail
        // @audit - could this clearing cause issues as it's a struct?
        if (!requestData.remove(requestId)) return;
        requestKeys.remove(idToKey[requestId]);
        delete idToKey[requestId];
        // Get the request type of the request
        RequestData memory data = requestData.get(requestId);
        if (data.requestType == RequestType.PRICE_UPDATE) {
            // Fulfill the price update request
            uint256 len = response.length;
            if (len % WORD != 0) revert PriceFeed_InvalidResponseLength();
            // @audit - response can contain a number of prices to update
            // need to loop through in 32 byte words and deconstruct as shown.
            // max length is 100 assets * 32 byte words = 3200 --> uint16 sufficient
            for (uint16 i = 0; i < len;) {
                Price memory price;
                // Decode the encodedPrice into a bytes32
                // @audit - wrong, needs to be 32 bytes of the current word
                bytes32 responseBytes = bytes32(response);

                // Extract the values from the bytes32 and store them in the Price struct
                // truncate first 15 bytes of the response
                price.ticker = bytes15(responseBytes);
                // shift response 15 bytes left, then truncate the first byte
                price.precision = uint8(bytes1((responseBytes << 120)));
                // shift the response another byte left, then truncate the first 2 bytes
                price.variance = uint16(bytes2(responseBytes << 128));
                // shift the response another 2 bytes left, then truncate the first 6 bytes
                price.timestamp = uint48(bytes6(responseBytes << 144));
                // shift the response another 6 bytes left, then truncate the first 8 bytes
                price.med = uint64(bytes8(responseBytes << 192));

                // Store the price in storage
                prices[string(abi.encodePacked(price.ticker))][price.timestamp] = price;

                unchecked {
                    i += WORD;
                }
            }
        } else if (data.requestType == RequestType.CUMULATIVE_PNL) {
            // Fulfill the cumulative PNL request
            uint256 len = response.length;
            if (len != WORD) revert PriceFeed_InvalidResponseLength();

            Pnl memory pnl;

            bytes32 responseBytes = bytes32(response);
            // shift the response 1 byte left, then truncate the first byte
            pnl.precision = uint8(bytes1(responseBytes));
            // shift the response another byte left, then truncate the first 20 bytes
            pnl.market = address(bytes20(responseBytes << 8));
            // shift the response another 20 bytes left, then truncate the first 6 bytes
            pnl.timestamp = uint48(bytes6(responseBytes << 168));
            // shift the response another 6 bytes left, then truncate the first 5 bytes
            // Extract the cumulativePnl as uint40 as we can't directly extract
            // an int40 from bytes.
            uint40 pnlValue = uint40(bytes5(responseBytes << 216));

            // Check if the most significant bit is 1 or 0
            // 0x800... in binary is 1000000... The msb is 1, and all of the rest are 0
            // Using the & operator, we check if the msb matches
            // If they match, the number is negative, else positive.
            if (pnlValue & MSB1 != 0) {
                // If msb is 1, this indicates the number is negative.
                // In this case, we flip all of the bits and add 1 to convert from +ve to -ve
                pnl.cumulativePnl = -int40(~pnlValue + 1);
            } else {
                // If msb is 0, the value is positive, so we convert and return as is.
                pnl.cumulativePnl = int40(pnlValue);
            }

            // Store the cumulative PNL in the mapping
            cumulativePnl[pnl.market][pnl.timestamp] = pnl;
        } else {
            revert PriceFeed_InvalidRequestType();
        }

        // Emit an event to log the response
        emit Response(requestId, data, response, err);
    }

    function estimateRequestCost() external view returns (uint256) {
        // Get the current gas price
        uint256 gasPrice = tx.gasprice;

        // Calculate the overestimated gas price
        uint256 overestimatedGasPrice = (gasPrice * 110) / 100;

        // Calculate the total estimated gas cost in native units
        uint256 totalEstimatedGasCost = overestimatedGasPrice * (gasOverhead + callbackGasLimit);

        // Convert the total estimated gas cost to LINK using the price feed or fallback ratio
        uint256 totalEstimatedGasCostInLink;
        try AggregatorV2V3Interface(nativeLinkPriceFeed).latestAnswer() returns (int256 answer) {
            totalEstimatedGasCostInLink = totalEstimatedGasCost * uint256(answer) / LINK_BASE_UNIT;
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
    // @audit
    /**
     * Can make this an open function that anyone can call to convert ETH to LINK,
     * then get paid a small settlement fee for doing so. Basically incentivize
     * users to settle all Ether on the contract accumulated for LINK.
     *
     * Need to punish people from manipulating the AMM to extract value from the contract.
     */
    function _convertEthToLink(uint256 _ethAmount) private {
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
        uint256 amountOut = uniswapRouter.exactInput(
            ISwapRouter.ExactInputParams({
                path: abi.encodePacked(path[0], feeTier, path[1]),
                recipient: address(this),
                deadline: block.timestamp + 1800,
                amountIn: ethAmount,
                amountOutMinimum: 0
            })
        );
        if (amountOut == 0) revert PriceFeed_SwapFailed();
    }

    function _blockTimestamp() internal view returns (uint48) {
        return uint48(block.timestamp);
    }

    function _generateKey(bytes memory _args) internal pure returns (bytes32) {
        return keccak256(_args);
    }

    function getPrices(string memory _ticker, uint48 _timestamp) external view returns (Price memory signedPrices) {
        signedPrices = prices[_ticker][_timestamp];
        if (signedPrices.timestamp == 0) revert PriceFeed_PriceNotSigned();
        if (signedPrices.timestamp + MIN_EXPIRATION_TIME < block.timestamp) revert PriceFeed_PriceExpired();
    }

    function getCumulativePnl(address _market, uint48 _timestamp) external view returns (int256 pnl) {
        pnl = cumulativePnl[_market][_timestamp].cumulativePnl;
        if (cumulativePnl[_market][_timestamp].market == address(0)) revert PriceFeed_PnlNotSigned();
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
}
