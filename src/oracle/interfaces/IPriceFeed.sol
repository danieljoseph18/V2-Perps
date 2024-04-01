// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IMarket} from "../../markets/interfaces/IMarket.sol";
import {IMarketMaker} from "../../markets/interfaces/IMarketMaker.sol";

interface IPriceFeed {
    struct Price {
        uint256 timestamp;
        uint256 minPrice;
        uint256 medPrice;
        uint256 maxPrice;
    }

    enum RequestType {
        PRICE_UPDATE,
        CUMULATIVE_PNL
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
    error UnexpectedRequestID(bytes32 requestId);
    error PriceFeed_PriceUpdateLength();
    error FulfillmentFailed(string err);
    error PriceFeed_InvalidGasParams();
    error PriceFeed_AssetSupportFailed();
    error PriceFeed_AssetRemovalFailed();
    error PriceFeed_InvalidMarket();

    // Event to log responses
    event Response(bytes32 indexed requestId, RequestType requestType, bytes response, bytes err);

    function marketMaker() external view returns (IMarketMaker);
    function PRICE_DECIMALS() external pure returns (uint256);
    function sequencerUptimeFeed() external view returns (address);
    function averagePriceUpdateCost() external view returns (uint256);
    function additionalCostPerAsset() external view returns (uint256);
    function getPrices(bytes32 _assetId) external view returns (Price memory);
    function cumulativePnl(address market) external view returns (int256);

    function updateSubscriptionId(uint64 _subId) external;
    function updateGasLimits(uint32 _priceGasLimit, uint32 _cumulativePnlGasLimit) external;
    function setAverageGasParameters(uint256 _averagePriceUpdateCost, uint256 _additionalCostPerAsset) external;
    function supportAsset(string memory _ticker) external;
    function unsupportAsset(string memory _ticker) external;
    function updateSequencerUptimeFeed(address _sequencerUptimeFeed) external;
    function requestPriceUpdate(string[] calldata args) external returns (bytes32 requestId);
    function requestGetCumulativeMarketPnl(IMarket market) external returns (bytes32 requestId);
    function LONG_ASSET_ID() external view returns (bytes32);
    function SHORT_ASSET_ID() external view returns (bytes32);
}
