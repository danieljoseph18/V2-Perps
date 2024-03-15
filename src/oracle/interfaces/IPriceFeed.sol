// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {Oracle} from "../Oracle.sol";

interface IPriceFeed {
    event PriceDataSigned(bytes32 assetId, uint256 block, bytes priceData);
    event PrimaryPricesSet(bytes32[] assetIds);
    event PriceFeed_PricesCleared();

    error PriceFeed_InsufficientFee();
    error PriceFeed_InvalidToken(bytes32 assetId);
    error PriceFeed_InvalidPrimaryStrategy();
    error PriceFeed_FailedToClearPrices();

    function supportAsset(bytes32 _assetId, Oracle.Asset memory _asset) external;
    function unsupportAsset(bytes32 _assetId) external;
    function updateSequencerUptimeFeed(address _sequencerUptimeFeed) external;
    function setPrimaryPrices(
        bytes32[] calldata _assetIds,
        bytes[] calldata _pythPriceData,
        uint256[] calldata _compactedPriceData
    ) external payable;
    function clearPrimaryPrices() external;
    function getAsset(bytes32 _assetId) external view returns (Oracle.Asset memory);
    function longAssetId() external view returns (bytes32);
    function shortAssetId() external view returns (bytes32);
    function sequencerUptimeFeed() external view returns (address);
    function getPriceUnsafe(Oracle.Asset memory _asset) external view returns (uint256 price, uint256 confidence);
    function createPriceFeedUpdateData(
        bytes32 id,
        int64 price,
        uint64 conf,
        int32 expo,
        int64 emaPrice,
        uint64 emaConf,
        uint64 publishTime,
        uint64 prevPublishTime
    ) external pure returns (bytes memory priceFeedData);
    function getAssetPricesUnsafe()
        external
        view
        returns (Oracle.Price memory longPrice, Oracle.Price memory shortPrice);
    function getPrimaryPrice(bytes32 _assetId) external view returns (Oracle.Price memory);
    function updateFee(bytes[] calldata _priceUpdateData) external view returns (uint256);
}
