// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {Oracle} from "../Oracle.sol";

interface IPriceFeed {
    event PriceDataSigned(bytes32 assetId, uint256 block, bytes priceData);

    error PriceFeed_InsufficientFee();
    error PriceFeed_InvalidToken();
    error PriceFeed_InvalidPrimaryStrategy();

    function supportAsset(bytes32 _assetId, Oracle.Asset memory _asset) external;
    function unsupportAsset(bytes32 _assetId) external;
    function updateSequenceUptimeFeed(address _sequencerUptimeFeed) external;
    function signPrimaryPrice(bytes32 _assetId, bytes[] calldata _priceUpdateData) external payable;
    function clearPrimaryPrice(bytes32 _assetId) external;
    function getAsset(bytes32 _assetId) external view returns (Oracle.Asset memory);
    function longTokenId() external view returns (bytes32);
    function shortTokenId() external view returns (bytes32);
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
    function encodePriceData(uint64 _indexPrice, uint64 _longPrice, uint64 _shortPrice, uint8 _decimals)
        external
        pure
        returns (bytes memory offchainPriceData);
    function getAssetPricesUnsafe()
        external
        view
        returns (Oracle.Price memory longPrice, Oracle.Price memory shortPrice);
    function getPrimaryPrice(bytes32 _assetId) external view returns (Oracle.Price memory);
    function updateFee(bytes[] calldata _priceUpdateData) external view returns (uint256);
}
