// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IMarket} from "../../markets/interfaces/IMarket.sol";
import {IMarketFactory} from "../../markets/interfaces/IMarketFactory.sol";

interface IPriceFeed {
    enum RequestType {
        PRICE_UPDATE,
        CUMULATIVE_PNL
    }

    struct RequestData {
        address requester;
        uint48 blockTimestamp;
        RequestType requestType;
    }

    struct TokenData {
        address secondaryFeed;
        uint8 tokenDecimals;
        FeedType feedType;
        bool hasSecondaryFeed;
    }

    enum FeedType {
        CHAINLINK,
        UNI_V30, // Uniswap V3 token0
        UNI_V31, // Uniswap V3 token1
        UNI_V20, // Uniswap V2 token0
        UNI_V21, // Uniswap V2 token1
        PYTH
    }

    struct Price {
        /**
         * The ticker of the asset. Used to identify the asset.
         * Limited to a maximum of 15 bytes to ensure the struct fits in a 32-byte word.
         */
        bytes15 ticker;
        /**
         * Number of decimal places the price result is accurate to. Let's us expand
         * the price to the correct number of decimal places.
         */
        uint8 precision;
        /**
         * Percentage of variance in the price. Used to determine upper and lower bound prices.
         * Min and max prices are calculated as : med +- (med * variance / 10,000)
         */
        uint16 variance;
        /**
         * Timestamp the price is set for.
         */
        uint48 timestamp;
        /**
         * The median aggregated price (not including outliers) fetched from the price data sources.
         */
        uint64 med;
    }

    struct Pnl {
        uint8 precision;
        address market;
        uint48 timestamp;
        int40 cumulativePnl;
    }

    // Custom error type
    error PriceFeed_UnexpectedRequestID(bytes32 requestId);
    error PriceFeed_PriceUpdateLength();
    error PriceFeed_FulfillmentFailed(string err);
    error PriceFeed_InvalidGasParams();
    error PriceFeed_AssetSupportFailed();
    error PriceFeed_AssetRemovalFailed();
    error PriceFeed_InvalidMarket();
    error PriceFeed_InvalidRequestType();
    error PriceFeed_FailedToClearPrice();
    error PriceFeed_FailedToClearPnl();
    error PriceFeed_PriceNotSigned();
    error PriceFeed_PnlNotSigned();
    error PriceFeed_AlreadyInitialized();
    error PriceFeed_PriceExpired();
    error PriceFeed_FailedToClearRequest();
    error PriceFeed_SwapFailed();
    error PriceFeed_InvalidResponseLength();
    error PriceFeed_ZeroBalance();

    // Event to log responses
    event Response(bytes32 indexed requestId, RequestData requestData, bytes response, bytes err);
    event AssetPricesCleared();
    event PnlCleared(address indexed market);
    event AssetSupported(string indexed ticker, uint8 tokenDecimals);
    event SupportRemoved(string indexed ticker);
    event LinkReceived(uint256 indexed amount);
    event LinkBalanceSettled(uint256 indexed amount);

    function marketFactory() external view returns (IMarketFactory);
    function PRICE_DECIMALS() external pure returns (uint256);
    function sequencerUptimeFeed() external view returns (address);
    function getPrices(string memory _ticker, uint48 _timestamp) external view returns (Price memory signedPrices);
    function getCumulativePnl(address _market, uint48 _timestamp) external view returns (Pnl memory pnl);

    function updateSubscriptionId(uint64 _subId) external;
    function updateBillingParameters(
        uint256 _gasOverhead,
        uint32 _callbackGasLimit,
        uint256 _premiumFee,
        uint64 _settlementFee,
        address _nativeLinkPriceFeed
    ) external;
    function supportAsset(string memory _ticker, TokenData memory _tokenData, bytes32 _pythId) external;
    function unsupportAsset(string memory _ticker) external;
    function updateSequencerUptimeFeed(address _sequencerUptimeFeed) external;
    function requestPriceUpdate(string[] calldata args, address _requester)
        external
        payable
        returns (bytes32 requestId);
    function requestCumulativeMarketPnl(IMarket market, address _requester)
        external
        payable
        returns (bytes32 requestId);
    function getTokenData(string memory _ticker) external view returns (TokenData memory);
    function priceUpdateRequested(bytes32 _requestId) external view returns (bool);
    function getRequestData(bytes32 _requestId) external view returns (RequestData memory);
    function getRequester(bytes32 _requestId) external view returns (address);
    function pythIds(string memory _ticker) external view returns (bytes32);
    function nativeLinkPriceFeed() external view returns (address);
    function callbackGasLimit() external view returns (uint32);
    function gasOverhead() external view returns (uint256);
    function getRequestTimestamp(bytes32 _requestId) external view returns (uint48);
    function timeToExpiration() external view returns (uint48);
}
