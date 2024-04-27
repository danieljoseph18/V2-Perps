// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {FunctionsClient} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/FunctionsClient.sol";
import {FunctionsRequest} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/libraries/FunctionsRequest.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {EnumerableSetLib} from "../libraries/EnumerableSetLib.sol";
import {EnumerableMap} from "../libraries/EnumerableMap.sol";
import {RoleValidation} from "../access/RoleValidation.sol";
import {IMarketFactory} from "../markets/interfaces/IMarketFactory.sol";
import {IPriceFeed} from "./interfaces/IPriceFeed.sol";
import {ISwapRouter} from "./interfaces/ISwapRouter.sol";
import {IUniswapV3Factory} from "./interfaces/IUniswapV3Factory.sol";
import {IWETH} from "../tokens/interfaces/IWETH.sol";
import {AggregatorV2V3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV2V3Interface.sol";
import {ReentrancyGuard} from "../utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "../libraries/SafeTransferLib.sol";
import {Oracle} from "./Oracle.sol";

contract PriceFeed is FunctionsClient, ReentrancyGuard, RoleValidation, IPriceFeed {
    using FunctionsRequest for FunctionsRequest.Request;
    using EnumerableSetLib for EnumerableSetLib.Bytes32Set;
    using EnumerableMap for EnumerableMap.PriceRequestMap;

    uint256 public constant PRICE_DECIMALS = 30;
    // Length of 1 Bytes32 Word
    uint8 private constant WORD = 32;
    uint8 private constant MIN_EXPIRATION_TIME = 2 minutes;
    uint40 private constant MSB1 = 0x8000000000;
    uint64 private constant LINK_BASE_UNIT = 1e18;
    uint16 private constant MAX_DATA_LENGTH = 3296;
    // Uniswap V3 Router address on Network
    address public immutable UNISWAP_V3_ROUTER;
    // Uniswap V3 Factory address on Network
    address public immutable UNISWAP_V3_FACTORY;
    // WETH address on Network
    address public immutable WETH;
    // LINK address on Network
    address public immutable LINK;

    IMarketFactory public marketFactory;

    // Don IDs: https://docs.chain.link/chainlink-functions/supported-networks
    bytes32 private donId;
    address public sequencerUptimeFeed;
    uint64 subscriptionId;
    uint64 settlementFee;
    uint8 maxRetries;
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
    address public nativeLinkPriceFeed;
    uint32 public callbackGasLimit;
    uint48 public timeToExpiration;

    // State variable to store the returned character information
    mapping(string ticker => mapping(uint48 blockTimestamp => Price priceResponse)) private prices;
    mapping(address market => mapping(uint48 blockTimestamp => Pnl cumulativePnl)) public cumulativePnl;
    // store who requested the data and what type of data was requested
    // only the keeper who requested can fill the order for non market orders
    // all pricing should be cleared once the request is filled
    // data should be tied only to the request as its specific to the request
    mapping(string ticker => TokenData) private tokenData;
    mapping(string ticker => bytes32 pythId) public pythIds;

    // Dictionary to enable clearing of the RequestKey
    // Bi-directional to handle the case of invalidated requests
    mapping(bytes32 requestId => bytes32 requestKey) private idToKey;
    mapping(bytes32 requestKey => bytes32 requestId) private keyToId;
    /**
     * Used to count the number of failed price / pnl retrievals. If > MAX, the request is
     * invalidated and removed from storage.
     */
    mapping(bytes32 requestKey => uint256 retries) numberOfRetries;
    EnumerableMap.PriceRequestMap private requestData;
    EnumerableSetLib.Bytes32Set private assetIds;
    EnumerableSetLib.Bytes32Set private requestKeys;

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
        donId = _donId;
    }

    function initialize(
        uint256 _gasOverhead,
        uint32 _callbackGasLimit,
        uint256 _premiumFee,
        uint64 _settlementFee,
        address _nativeLinkPriceFeed,
        address _sequencerUptimeFeed,
        uint48 _timeToExpiration
    ) external onlyAdmin {
        if (isInitialized) revert PriceFeed_AlreadyInitialized();
        gasOverhead = _gasOverhead;
        callbackGasLimit = _callbackGasLimit;
        premiumFee = _premiumFee;
        settlementFee = _settlementFee;
        nativeLinkPriceFeed = _nativeLinkPriceFeed;
        sequencerUptimeFeed = _sequencerUptimeFeed;
        timeToExpiration = _timeToExpiration;
        isInitialized = true;
    }

    function updateBillingParameters(
        uint64 _subId,
        bytes32 _donId,
        uint256 _gasOverhead,
        uint32 _callbackGasLimit,
        uint256 _premiumFee,
        uint64 _settlementFee,
        address _nativeLinkPriceFeed
    ) external onlyAdmin {
        subscriptionId = _subId;
        donId = _donId;
        gasOverhead = _gasOverhead;
        callbackGasLimit = _callbackGasLimit;
        premiumFee = _premiumFee;
        settlementFee = _settlementFee;
        nativeLinkPriceFeed = _nativeLinkPriceFeed;
    }

    function setJavascriptSourceCode(string memory _priceUpdateSource, string memory _cumulativePnlSource)
        external
        onlyAdmin
    {
        priceUpdateSource = _priceUpdateSource;
        cumulativePnlSource = _cumulativePnlSource;
    }

    function supportAsset(string memory _ticker, TokenData memory _tokenData, bytes32 _pythId)
        external
        onlyMarketFactory
    {
        bytes32 assetId = keccak256(abi.encode(_ticker));
        if (assetIds.contains(assetId)) return; // Return if already supported
        if (_tokenData.feedType == FeedType.PYTH) {
            pythIds[_ticker] = _pythId;
        }
        bool success = assetIds.add(assetId);
        if (!success) revert PriceFeed_AssetSupportFailed();
        tokenData[_ticker] = _tokenData;
        emit AssetSupported(_ticker, _tokenData.tokenDecimals);
    }

    /// @dev - No need to unsupport Pyth Ids --> save gas if asset is re-supported
    function unsupportAsset(string memory _ticker) external onlyAdmin {
        bytes32 assetId = keccak256(abi.encode(_ticker));
        if (!assetIds.contains(assetId)) return; // Return if not supported
        bool success = assetIds.remove(assetId);
        if (!success) revert PriceFeed_AssetRemovalFailed();
        delete tokenData[_ticker];
        emit SupportRemoved(_ticker);
    }

    function updateSequencerUptimeFeed(address _sequencerUptimeFeed) external onlyAdmin {
        sequencerUptimeFeed = _sequencerUptimeFeed;
    }

    function setTimeToExpiration(uint48 _timeToExpiration) external onlyAdmin {
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
     * @return requestKey The signature of the request
     */
    function requestPriceUpdate(string[] calldata args, address _requester)
        external
        payable
        onlyRouter
        nonReentrant
        returns (bytes32 requestKey)
    {
        Oracle.isSequencerUp(this);

        // Compute the key and check if the same request exists:
        // if it does, return to prevent the consumer from running the same computation multiple times.
        requestKey = _generateKey(abi.encode(args, _requester, _blockTimestamp()));
        if (requestKeys.contains(requestKey)) return bytes32(0);

        bytes32 requestId = _requestFulfillment(args, true);

        RequestData memory data = RequestData({
            requester: _requester,
            blockTimestamp: _blockTimestamp(),
            requestType: RequestType.PRICE_UPDATE,
            args: args
        });

        // Add the Request to Storage
        requestKeys.add(requestKey);
        idToKey[requestId] = requestKey;
        keyToId[requestKey] = requestId;
        requestData.set(requestId, data);
    }

    /// @dev - for this, we need to copy / call the function MarketUtils.calculateCumulativeMarketPnl but offchain
    function requestCumulativeMarketPnl(IMarket market, address _requester)
        external
        payable
        onlyRouter
        nonReentrant
        returns (bytes32 requestKey)
    {
        // Need to check the market is valid
        // If the market is not valid, revert
        if (!marketFactory.isMarket(address(market))) revert PriceFeed_InvalidMarket();

        string[] memory args = Oracle.constructPnlArguments(market);

        // Compute the key and check if the same request exists:
        // if it does, return to prevent the consumer running multiple times for a given block.
        requestKey = _generateKey(abi.encode(args, _requester, _blockTimestamp()));
        if (requestKeys.contains(requestKey)) return bytes32(0);

        bytes32 requestId = _requestFulfillment(args, false);

        RequestData memory data = RequestData({
            requester: _requester,
            blockTimestamp: _blockTimestamp(),
            requestType: RequestType.CUMULATIVE_PNL,
            args: args
        });

        // Add the Request to Storage
        requestKeys.add(requestKey);
        idToKey[requestId] = requestKey;
        keyToId[requestKey] = requestId;
        requestData.set(requestId, data);
    }

    /**
     * @notice Callback function for fulfilling a request
     * @param requestId The ID of the request to fulfill
     * @param response The HTTP response data
     * @param err Any errors from the Functions request
     */
    /// @dev - Need to make sure an err is only passed to the contract if it's critical,
    /// to prevent valid prices being invalidated.
    // Decode the response, according to the structure of the request
    // Try to avoid reverting, and instead return without storing the price response if invalid.
    function fulfillRequest(bytes32 requestId, bytes memory response, bytes memory err) internal override {
        // Return if invalid requestId
        if (!requestData.contains(requestId)) return;
        // Return if an error is thrown
        if (err.length > 0) {
            _recreateRequest(requestId);
            return;
        }
        // Remove the RequestId from storage and return if fail
        if (!requestData.remove(requestId)) return;
        requestKeys.remove(idToKey[requestId]);
        delete idToKey[requestId];
        // Get the request type of the request
        RequestData memory data = requestData.get(requestId);
        if (data.requestType == RequestType.PRICE_UPDATE) {
            _decodeAndStorePrices(response);
        } else if (data.requestType == RequestType.CUMULATIVE_PNL) {
            _decodeAndStorePnl(response);
        } else {
            revert PriceFeed_InvalidRequestType();
        }

        // Emit an event to log the response
        emit Response(requestId, data, response, err);
    }

    function settleEthForLink() external onlyAdmin nonReentrant {
        // Get the amount of Ether held within the contract
        uint256 ethBalance = address(this).balance;
        if (ethBalance == 0) revert PriceFeed_ZeroBalance();
        // Calculate the fee to be paid to the arbitrageur based on the bonus fee paid by the requesters
        uint256 settlementReward = Oracle.calculateSettlementFee(ethBalance, settlementFee);
        uint256 conversionAmount = ethBalance - settlementReward;
        // Convert the Ether to LINK using the Uniswap V3 Router
        // Get the Uniswap V3 router instance
        ISwapRouter uniswapRouter = ISwapRouter(UNISWAP_V3_ROUTER);

        // Approve the router to spend ETH
        IWETH(WETH).deposit{value: conversionAmount}();
        IWETH(WETH).approve(address(uniswapRouter), conversionAmount);

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
                deadline: block.timestamp + 2 minutes,
                amountIn: conversionAmount,
                amountOutMinimum: 0
            })
        );
        if (amountOut == 0) revert PriceFeed_SwapFailed();
        // Send the settlement fee to the caller
        SafeTransferLib.safeTransferETH(payable(msg.sender), settlementReward);
        // Emit an event to log the amount of LINK received
        emit LinkBalanceSettled(settlementReward);
    }

    /**
     * ================================== Private Functions ==================================
     */

    /// @dev Needed to re-request any failed requests to ensure they're fulfilled
    /// if a request fails > max retries, the request is cancelled and removed from storage.
    function _recreateRequest(bytes32 _oldRequestId) private {
        // get the failed request
        RequestData memory failedRequestData = requestData.get(_oldRequestId);
        // key will remain the same, so cache the key
        bytes32 requestKey = idToKey[_oldRequestId];
        // increment the number of retries
        if (numberOfRetries[requestKey] > maxRetries) {
            // delete the request to stop the loop
            requestData.remove(_oldRequestId);
            delete idToKey[_oldRequestId];
            requestKeys.remove(requestKey);
            delete keyToId[requestKey];
        } else {
            ++numberOfRetries[requestKey];
            // create a new request
            bytes32 newRequestId =
                _requestFulfillment(failedRequestData.args, failedRequestData.requestType == RequestType.PRICE_UPDATE);
            // replace the old request with the new one
            // Delete the old request
            requestData.remove(_oldRequestId);
            delete idToKey[_oldRequestId];
            idToKey[newRequestId] = requestKey;
            keyToId[requestKey] = newRequestId;
            requestData.set(newRequestId, failedRequestData);
        }
    }

    function _requestFulfillment(string[] memory _args, bool _isPrice) private returns (bytes32 requestId) {
        FunctionsRequest.Request memory req;
        req.initializeRequestForInlineJavaScript(_isPrice ? priceUpdateSource : cumulativePnlSource); // Initialize the request with JS code
        if (_args.length > 0) req.setArgs(_args); // Set the arguments for the request

        // Send the request and store the request ID
        requestId = _sendRequest(req.encodeCBOR(), subscriptionId, callbackGasLimit, donId);
    }

    function _decodeAndStorePrices(bytes memory _encodedPrices) private {
        if (_encodedPrices.length > MAX_DATA_LENGTH) revert PriceFeed_PriceUpdateLength();
        if (_encodedPrices.length % WORD != 0) revert PriceFeed_PriceUpdateLength();

        uint256 numPrices = _encodedPrices.length / 32;

        for (uint16 i = 0; i < numPrices;) {
            bytes32 encodedPrice;

            // Use yul to extract the encoded price from the bytes
            // offset = (32 * i) + 32 (first 32 bytes are the length of the byte string)
            // encodedPrice = mload(encodedPrices[offset:offset+32])
            /// @solidity memory-safe-assembly
            assembly {
                encodedPrice := mload(add(_encodedPrices, add(32, mul(i, 32))))
            }

            Price memory price = Price(
                // First 15 bytes are the ticker
                bytes15(encodedPrice),
                // Next byte is the precision
                uint8(encodedPrice[15]),
                // Shift recorded values to the left and store the first 2 bytes (variance)
                uint16(bytes2(encodedPrice << 128)),
                // Shift recorded values to the left and store the first 6 bytes (timestamp)
                uint48(bytes6(encodedPrice << 144)),
                // Shift recorded values to the left and store the first 8 bytes (median price)
                uint64(bytes8(encodedPrice << 192))
            );
            // Validate the price range, and discard it if invalid
            if (!Oracle.validatePrice(this, price)) return;
            // Store the constructed price struct in the mapping
            prices[string(abi.encodePacked(price.ticker))][price.timestamp] = price;

            unchecked {
                ++i;
            }
        }
    }

    function _decodeAndStorePnl(bytes memory _encodedPnl) private {
        // Fulfill the cumulative PNL request
        uint256 len = _encodedPnl.length;
        if (len != WORD) revert PriceFeed_InvalidResponseLength();

        Pnl memory pnl;

        bytes32 responseBytes = bytes32(_encodedPnl);
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
    }

    function _blockTimestamp() internal view returns (uint48) {
        return uint48(block.timestamp);
    }

    function _generateKey(bytes memory _args) internal pure returns (bytes32) {
        return keccak256(_args);
    }

    /**
     * ================================== External / Getter Functions ==================================
     */

    // Used to pack price data into a single bytes32 word for fulfillment
    function encodePrices(
        string[] calldata _tickers,
        uint8[] calldata _precisions,
        uint16[] calldata _variances,
        uint48[] calldata _timestamps,
        uint64[] calldata _meds
    ) external pure returns (bytes memory) {
        uint16 len = uint16(_tickers.length);
        bytes32[] memory encodedPrices = new bytes32[](len);
        // Loop through the prices and encode them into a single bytes32 word
        for (uint16 i = 0; i < len;) {
            bytes32 encodedPrice = bytes32(
                abi.encodePacked(bytes15(bytes(_tickers[i])), _precisions[i], _variances[i], _timestamps[i], _meds[i])
            );
            encodedPrices[i] = encodedPrice;
            unchecked {
                ++i;
            }
        }
        // Concatenate the encoded prices into a single bytes string
        return abi.encodePacked(encodedPrices);
    }

    // Used to pack cumulative PNL into a single bytes32 word for fulfillment
    function encodePnl(uint8 _precision, address _market, uint48 _timestamp, int40 _cumulativePnl)
        external
        pure
        returns (bytes memory)
    {
        Pnl memory pnl;
        pnl.precision = _precision;
        pnl.market = _market;
        pnl.timestamp = _timestamp;
        pnl.cumulativePnl = _cumulativePnl;
        return abi.encodePacked(pnl.precision, pnl.market, pnl.timestamp, pnl.cumulativePnl);
    }

    function getPrices(string memory _ticker, uint48 _timestamp) external view returns (Price memory signedPrices) {
        signedPrices = prices[_ticker][_timestamp];
        if (signedPrices.timestamp == 0) revert PriceFeed_PriceNotSigned();
        if (signedPrices.timestamp + MIN_EXPIRATION_TIME < block.timestamp) revert PriceFeed_PriceExpired();
    }

    function getCumulativePnl(address _market, uint48 _timestamp) external view returns (Pnl memory pnl) {
        pnl = cumulativePnl[_market][_timestamp];
        if (pnl.market == address(0)) revert PriceFeed_PnlNotSigned();
    }

    function getTokenData(string memory _ticker) external view returns (TokenData memory) {
        return tokenData[_ticker];
    }

    function priceUpdateRequested(bytes32 _requestId) external view returns (bool) {
        return requestData.get(_requestId).requester != address(0);
    }

    function getRequester(bytes32 _requestId) external view returns (address) {
        return requestData.get(_requestId).requester;
    }

    function getRequestData(bytes32 _requestKey) external view returns (RequestData memory) {
        bytes32 requestId = keyToId[_requestKey];
        return requestData.get(requestId);
    }

    function isRequestValid(bytes32 _requestKey) external view returns (bool) {
        bytes32 requestId = keyToId[_requestKey];
        return requestData.contains(requestId);
    }

    function getRequestTimestamp(bytes32 _requestKey) external view returns (uint48) {
        bytes32 requestId = keyToId[_requestKey];
        return requestData.get(requestId).blockTimestamp;
    }

    function getRequests() external view returns (bytes32[] memory) {
        return requestData.keys();
    }
}
