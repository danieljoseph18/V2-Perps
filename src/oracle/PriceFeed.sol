// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {FunctionsClient} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/FunctionsClient.sol";
import {FunctionsRequest} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/libraries/FunctionsRequest.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {EnumerableSetLib} from "../libraries/EnumerableSetLib.sol";
import {EnumerableMap} from "../libraries/EnumerableMap.sol";
import {OwnableRoles} from "../auth/OwnableRoles.sol";
import {IMarketFactory} from "../factory/interfaces/IMarketFactory.sol";
import {IPriceFeed} from "./interfaces/IPriceFeed.sol";
import {ISwapRouter} from "./interfaces/ISwapRouter.sol";
import {IUniswapV3Factory} from "./interfaces/IUniswapV3Factory.sol";
import {IWETH} from "../tokens/interfaces/IWETH.sol";
import {AggregatorV2V3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV2V3Interface.sol";
import {ReentrancyGuard} from "../utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "../libraries/SafeTransferLib.sol";
import {Oracle} from "./Oracle.sol";
import {LibString} from "../../src/libraries/LibString.sol";

contract PriceFeed is FunctionsClient, ReentrancyGuard, OwnableRoles, IPriceFeed {
    using FunctionsRequest for FunctionsRequest.Request;
    using EnumerableSetLib for EnumerableSetLib.Bytes32Set;
    using EnumerableMap for EnumerableMap.PriceMap;
    using LibString for bytes15;

    uint256 public constant PRICE_DECIMALS = 30;

    uint8 private constant WORD = 32;
    uint8 private constant MIN_EXPIRATION_TIME = 3 minutes;
    uint40 private constant MSB1 = 0x8000000000;
    uint64 private constant LINK_BASE_UNIT = 1e18;
    uint16 private constant MAX_DATA_LENGTH = 3296;

    address public immutable UNISWAP_V3_ROUTER;

    address public immutable UNISWAP_V3_FACTORY;

    address public immutable WETH;

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

    mapping(string ticker => mapping(uint48 blockTimestamp => Price priceResponse)) private prices;
    mapping(address market => mapping(uint48 blockTimestamp => Pnl cumulativePnl)) public cumulativePnl;

    mapping(string ticker => SecondaryStrategy) private strategies;
    mapping(string ticker => uint8) public tokenDecimals;

    // Dictionary to enable clearing of the RequestKey
    // Bi-directional to handle the case of invalidated requests
    mapping(bytes32 requestId => bytes32 requestKey) private idToKey;
    mapping(bytes32 requestKey => bytes32 requestId) private keyToId;
    /**
     * Used to count the number of failed price / pnl retrievals. If > MAX, the request is
     * permanently invalidated and removed from storage.
     */
    mapping(bytes32 requestKey => uint256 retries) numberOfRetries;

    EnumerableMap.PriceMap private requestData;
    EnumerableSetLib.Bytes32Set private assetIds;
    EnumerableSetLib.Bytes32Set private requestKeys;

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
        _initializeOwner(msg.sender);
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
    ) external onlyOwner {
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
    ) external onlyOwner {
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
        onlyOwner
    {
        priceUpdateSource = _priceUpdateSource;
        cumulativePnlSource = _cumulativePnlSource;
    }

    function supportAsset(string memory _ticker, SecondaryStrategy calldata _strategy, uint8 _tokenDecimals)
        external
        onlyRoles(_ROLE_0)
    {
        bytes32 assetId = keccak256(abi.encode(_ticker));
        if (assetIds.contains(assetId)) return; // Return if already supported
        bool success = assetIds.add(assetId);
        if (!success) revert PriceFeed_AssetSupportFailed();
        strategies[_ticker] = _strategy;
        emit AssetSupported(_ticker, _tokenDecimals);
    }

    function unsupportAsset(string memory _ticker) external onlyOwner {
        bytes32 assetId = keccak256(abi.encode(_ticker));
        if (!assetIds.contains(assetId)) return; // Return if not supported
        bool success = assetIds.remove(assetId);
        if (!success) revert PriceFeed_AssetRemovalFailed();
        delete strategies[_ticker];
        delete tokenDecimals[_ticker];
        emit SupportRemoved(_ticker);
    }

    function updateSequencerUptimeFeed(address _sequencerUptimeFeed) external onlyOwner {
        sequencerUptimeFeed = _sequencerUptimeFeed;
    }

    function updateSecondaryStrategy(string memory _ticker, SecondaryStrategy memory _strategy) external onlyOwner {
        strategies[_ticker] = _strategy;
    }

    function setTimeToExpiration(uint48 _timeToExpiration) external onlyOwner {
        timeToExpiration = _timeToExpiration;
    }

    function clearInvalidRequest(bytes32 _requestId) external onlyOwner {
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
        onlyRoles(_ROLE_3)
        nonReentrant
        returns (bytes32)
    {
        Oracle.isSequencerUp(this);

        bytes32 requestKey = _generateKey(abi.encode(args, _requester, _blockTimestamp()));

        if (requestKeys.contains(requestKey)) return requestKey;

        bytes32 requestId = _requestFulfillment(args, true);

        RequestData memory data = RequestData({
            requester: _requester,
            blockTimestamp: _blockTimestamp(),
            requestType: RequestType.PRICE_UPDATE,
            args: args
        });

        requestKeys.add(requestKey);
        idToKey[requestId] = requestKey;
        keyToId[requestKey] = requestId;
        requestData.set(requestId, data);

        return requestKey;
    }

    function requestCumulativeMarketPnl(IMarket market, address _requester)
        external
        payable
        onlyRoles(_ROLE_3)
        nonReentrant
        returns (bytes32)
    {
        if (!marketFactory.isMarket(address(market))) revert PriceFeed_InvalidMarket();

        string[] memory args = Oracle.constructPnlArguments(market);

        bytes32 requestKey = _generateKey(abi.encode(args, _requester, _blockTimestamp()));

        if (requestKeys.contains(requestKey)) return requestKey;

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

        return requestKey;
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
        if (!requestData.contains(requestId)) return;

        if (err.length > 0) {
            _recreateRequest(requestId);
            return;
        }

        RequestData memory data = requestData.get(requestId);

        if (!requestData.remove(requestId)) return;
        requestKeys.remove(idToKey[requestId]);
        delete idToKey[requestId];

        if (data.requestType == RequestType.PRICE_UPDATE) {
            _decodeAndStorePrices(response);
        } else if (data.requestType == RequestType.CUMULATIVE_PNL) {
            _decodeAndStorePnl(response);
        } else {
            revert PriceFeed_InvalidRequestType();
        }

        emit Response(requestId, data, response, err);
    }

    function settleEthForLink() external onlyOwner nonReentrant {
        uint256 ethBalance = address(this).balance;

        if (ethBalance == 0) revert PriceFeed_ZeroBalance();

        // Bonus fee to the arbitrageur
        uint256 settlementReward = Oracle.calculateSettlementFee(ethBalance, settlementFee);

        uint256 conversionAmount = ethBalance - settlementReward;

        ISwapRouter uniswapRouter = ISwapRouter(UNISWAP_V3_ROUTER);

        IWETH(WETH).deposit{value: conversionAmount}();
        IWETH(WETH).approve(address(uniswapRouter), conversionAmount);

        address[] memory path = new address[](2);
        path[0] = WETH;
        path[1] = LINK;

        uint24 feeTier = 3000;

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

        SafeTransferLib.safeTransferETH(payable(msg.sender), settlementReward);

        emit LinkBalanceSettled(settlementReward);
    }

    /**
     * ================================== Private Functions ==================================
     */

    /// @dev Needed to re-request any failed requests to ensure they're fulfilled
    function _recreateRequest(bytes32 _oldRequestId) private {
        RequestData memory failedRequestData = requestData.get(_oldRequestId);

        bytes32 requestKey = idToKey[_oldRequestId];

        if (numberOfRetries[requestKey] > maxRetries) {
            requestData.remove(_oldRequestId);
            delete idToKey[_oldRequestId];
            requestKeys.remove(requestKey);
            delete keyToId[requestKey];
        } else {
            ++numberOfRetries[requestKey];

            bytes32 newRequestId =
                _requestFulfillment(failedRequestData.args, failedRequestData.requestType == RequestType.PRICE_UPDATE);

            requestData.remove(_oldRequestId);
            delete idToKey[_oldRequestId];
            idToKey[newRequestId] = requestKey;
            keyToId[requestKey] = newRequestId;

            requestData.set(newRequestId, failedRequestData);
        }
    }

    function _requestFulfillment(string[] memory _args, bool _isPrice) private returns (bytes32 requestId) {
        FunctionsRequest.Request memory req;

        req.initializeRequestForInlineJavaScript(_isPrice ? priceUpdateSource : cumulativePnlSource);

        if (_args.length > 0) req.setArgs(_args);

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

            if (!Oracle.validatePrice(this, price)) return;

            prices[price.ticker.fromSmallString()][price.timestamp] = price;

            unchecked {
                ++i;
            }
        }
    }

    function _decodeAndStorePnl(bytes memory _encodedPnl) private {
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
    function encodePrices(
        string[] calldata _tickers,
        uint8[] calldata _precisions,
        uint16[] calldata _variances,
        uint48[] calldata _timestamps,
        uint64[] calldata _meds
    ) external pure returns (bytes memory) {
        uint16 len = uint16(_tickers.length);

        bytes32[] memory encodedPrices = new bytes32[](len);

        for (uint16 i = 0; i < len;) {
            bytes32 encodedPrice = bytes32(
                abi.encodePacked(bytes15(bytes(_tickers[i])), _precisions[i], _variances[i], _timestamps[i], _meds[i])
            );

            encodedPrices[i] = encodedPrice;

            unchecked {
                ++i;
            }
        }

        return abi.encodePacked(encodedPrices);
    }

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
        if (signedPrices.timestamp == 0) revert PriceFeed_PriceRequired(_ticker);
        if (signedPrices.timestamp + MIN_EXPIRATION_TIME < block.timestamp) revert PriceFeed_PriceExpired();
    }

    function getCumulativePnl(address _market, uint48 _timestamp) external view returns (Pnl memory pnl) {
        pnl = cumulativePnl[_market][_timestamp];
        if (pnl.market == address(0)) revert PriceFeed_PnlNotSigned();
    }

    function getSecondaryStrategy(string memory _ticker) external view returns (SecondaryStrategy memory) {
        return strategies[_ticker];
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

    function getPythId(string memory _ticker) external view returns (bytes32) {
        return strategies[_ticker].feedId;
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
