// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IMarket} from "../../markets/interfaces/IMarket.sol";
import {IMarketFactory} from "../../markets/interfaces/IMarketFactory.sol";

interface IPriceFeed {
    struct Price {
        uint256 expirationTimestamp;
        uint256 min;
        uint256 med;
        uint256 max;
    }

    struct Pnl {
        bool wasSigned;
        int256 cumulativePnl;
    }

    enum RequestType {
        PRICE_UPDATE,
        CUMULATIVE_PNL
    }

    struct RequestData {
        address requester;
        RequestType requestType;
    }

    struct UnpackedPriceResponse {
        string ticker; // e.g ETH -> keccak hash of ticker = assetId
        uint256 compactedPrices; // e.g uint48 timestamp, uint64 minPrice, uint64 medPrice, uint64 maxPrice
    }

    struct UnpackedPnlResponse {
        address market;
        int256 cumulativePnl;
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

    // Event to log responses
    event Response(bytes32 indexed requestId, RequestData requestData, bytes response, bytes err);
    event AssetPricesCleared();
    event PnlCleared(address indexed market);
    event AssetSupported(string indexed ticker, uint256 baseUnit);
    event SupportRemoved(string indexed ticker);
    event LinkReceived(uint256 indexed amount);

    function marketFactory() external view returns (IMarketFactory);
    function PRICE_DECIMALS() external pure returns (uint256);
    function sequencerUptimeFeed() external view returns (address);
    function getPrices(bytes32 _requestId, string memory _ticker) external view returns (Price memory signedPrices);
    function getCumulativePnl(bytes32 _requestId) external view returns (int256);

    function updateSubscriptionId(uint64 _subId) external;
    function updateBillingParameters(
        uint256 _gasOverhead,
        uint32 _callbackGasLimit,
        uint256 _premiumFee,
        uint256 _fallbackWeiToLinkRatio,
        address _nativeLinkPriceFeed
    ) external;
    function supportAsset(string memory _ticker, uint256 _baseUnit) external;
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
    function clearSignedPrices(IMarket market, bytes32 _requestId) external;
    function clearCumulativePnl(IMarket market, bytes32 _requestId) external;
    function estimateRequestCost() external view returns (uint256);
    function baseUnits(string memory _ticker) external view returns (uint256);
    function priceUpdateRequested(bytes32 _requestId) external view returns (bool);
    function getRequester(bytes32 _requestId) external view returns (address);
}
