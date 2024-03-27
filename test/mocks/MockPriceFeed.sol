// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.23;

import {MockPyth, AbstractPyth} from "@pythnetwork/pyth-sdk-solidity/MockPyth.sol";
import {IPriceFeed} from "../../src/oracle/interfaces/IPriceFeed.sol";
import {Oracle} from "../../src/oracle/Oracle.sol";
import {PythStructs} from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

contract MockPriceFeed is MockPyth, IPriceFeed {
    using EnumerableSet for EnumerableSet.Bytes32Set;

    uint256 public constant PRICE_PRECISION = 1e30;

    uint256 public constant PRICE_DECIMALS = 30;

    uint256 public constant DEFAULT_SPREAD = 0.001e18; // 0.1%

    bytes32 public longAssetId;
    bytes32 public shortAssetId;
    uint256 public averagePriceUpdateCost;
    uint256 public additionalCostPerAsset;
    address public sequencerUptimeFeed;
    // Asset ID is the Hash of the ticker symbol -> e.g keccak256(abi.encode("ETH"));
    mapping(bytes32 assetId => Oracle.Asset asset) private assets;
    // To Store Price Data
    mapping(bytes32 assetId => Oracle.Price price) public prices;
    // Keep track of assets with prices set to clear them post-execution
    EnumerableSet.Bytes32Set private assetsWithPrices;

    constructor(
        uint256 _validTimePeriod,
        uint256 _singleUpdateFeeInWei,
        bytes32 _longAssetId,
        bytes32 _shortAssetId,
        Oracle.Asset memory _longAsset,
        Oracle.Asset memory _shortAsset
    ) MockPyth(_validTimePeriod, _singleUpdateFeeInWei) {
        longAssetId = _longAssetId;
        assets[_longAssetId] = _longAsset;
        priceFeeds[_longAsset.priceId] = PythStructs.PriceFeed({
            id: _longAsset.priceId,
            price: PythStructs.Price({price: 0, conf: 0, expo: 0, publishTime: 0}),
            emaPrice: PythStructs.Price({price: 0, conf: 0, expo: 0, publishTime: 0})
        });
        shortAssetId = _shortAssetId;
        assets[_shortAssetId] = _shortAsset;
        priceFeeds[_shortAsset.priceId] = PythStructs.PriceFeed({
            id: _shortAsset.priceId,
            price: PythStructs.Price({price: 0, conf: 0, expo: 0, publishTime: 0}),
            emaPrice: PythStructs.Price({price: 0, conf: 0, expo: 0, publishTime: 0})
        });
    }

    receive() external payable {}

    function setAverageGasParameters(uint256 _averagePriceUpdateCost, uint256 _additionalCostPerAsset) external {
        if (_averagePriceUpdateCost == 0 || _additionalCostPerAsset == 0) revert PriceFeed_InvalidGasParams();
        averagePriceUpdateCost = _averagePriceUpdateCost;
        additionalCostPerAsset = _additionalCostPerAsset;
    }

    function supportAsset(bytes32 _assetId, Oracle.Asset memory _asset) external {
        assets[_assetId] = _asset;
        priceFeeds[_asset.priceId] = PythStructs.PriceFeed({
            id: _asset.priceId,
            price: PythStructs.Price({price: 0, conf: 0, expo: 0, publishTime: 0}),
            emaPrice: PythStructs.Price({price: 0, conf: 0, expo: 0, publishTime: 0})
        });
    }

    function unsupportAsset(bytes32 _assetId) external {
        delete assets[_assetId];
    }

    function updateSequencerUptimeFeed(address _sequencerUptimeFeed) external {
        sequencerUptimeFeed = _sequencerUptimeFeed;
    }

    function setPrimaryPrices(
        bytes32[] calldata _assetIds,
        bytes[] calldata _pythPriceData,
        uint256[] calldata _compactedPriceData
    ) external payable {
        // If any Pyth price array contains data
        if (_pythPriceData.length != 0) {
            // Get the Update Fee
            uint256 pythFee = getUpdateFee(_pythPriceData);
            if (msg.value < pythFee) revert PriceFeed_InsufficientFee();
            // Update the Price Fees with the Data
            updatePriceFeeds(_pythPriceData);
        }
        // Loop through assets and set prices
        uint256 assetLen = _assetIds.length;
        // Use Uint16, as max is 10,000 assets
        for (uint16 index = 0; index < assetLen;) {
            bytes32 assetId = _assetIds[index];
            Oracle.Asset memory asset = assets[assetId];
            if (asset.baseUnit == 0) revert PriceFeed_InvalidToken(assetId);
            // Add the Price to the Set
            bool success = assetsWithPrices.add(assetId);
            if (!success) revert PriceFeed_FailedToAddPrice();
            // Set Prices based on strategy
            if (asset.primaryStrategy == Oracle.PrimaryStrategy.PYTH) {
                // Get the Pyth Price Data
                PythStructs.Price memory data = queryPriceFeed(asset.priceId).price;
                // Parse the Data
                Oracle.Price memory price = Oracle.parsePythData(data);
                // Validate the Price
                if (asset.secondaryStrategy != Oracle.SecondaryStrategy.NONE) {
                    uint256 refPrice = Oracle.getReferencePrice(asset);
                    Oracle.validatePriceRange(asset, price, refPrice);
                }
                // Set the Price
                prices[assetId] = price;
            } else if (asset.primaryStrategy == Oracle.PrimaryStrategy.OFFCHAIN) {
                // Get the starting bit index
                uint256 startingBit = index * 64;
                // Get the uint256 containing the compacted price
                uint256 priceData = _compactedPriceData[startingBit / 256];
                // Unpack and get the price
                Oracle.Price memory price = Oracle.unpackAndReturnPrice(priceData, startingBit);
                // Validate and Set the Price
                if (asset.secondaryStrategy != Oracle.SecondaryStrategy.NONE) {
                    uint256 refPrice = Oracle.getReferencePrice(asset);
                    Oracle.validatePriceRange(asset, price, refPrice);
                }
                // Set the Price
                prices[assetId] = price;
            } else {
                revert PriceFeed_InvalidPrimaryStrategy();
            }
            // Increment the Loop Counter
            unchecked {
                ++index;
            }
        }
        emit PrimaryPricesSet(_assetIds);
    }

    function clearPrimaryPrices() external {
        bytes32[] memory keys = assetsWithPrices.values();
        uint256 len = keys.length;
        for (uint256 i = 0; i < len;) {
            delete prices[keys[i]];
            bool success = assetsWithPrices.remove(keys[i]);
            if (!success) revert PriceFeed_FailedToRemovePrice();
            unchecked {
                ++i;
            }
        }
        if (assetsWithPrices.length() != 0) revert PriceFeed_FailedToClearPrices();
        emit PriceFeed_PricesCleared();
    }

    function getPriceUnsafe(Oracle.Asset memory _asset) external view returns (uint256 price, uint256 confidence) {
        PythStructs.Price memory data = queryPriceFeed(_asset.priceId).price;
        (price, confidence) = Oracle.convertPythParams(data);
    }

    function getAssetPricesUnsafe()
        external
        view
        returns (Oracle.Price memory longPrice, Oracle.Price memory shortPrice)
    {
        PythStructs.Price memory longData = queryPriceFeed(assets[longAssetId].priceId).price;
        PythStructs.Price memory shortData = queryPriceFeed(assets[shortAssetId].priceId).price;
        longPrice = Oracle.parsePythData(longData);
        shortPrice = Oracle.parsePythData(shortData);
    }

    function createPriceFeedUpdateData(
        bytes32 id,
        int64 price,
        uint64 conf,
        int32 expo,
        int64 emaPrice,
        uint64 emaConf,
        uint64 publishTime,
        uint64 prevPublishTime
    ) public pure override(IPriceFeed, MockPyth) returns (bytes memory priceFeedData) {
        PythStructs.PriceFeed memory priceFeed;

        priceFeed.id = id;

        priceFeed.price.price = price;
        priceFeed.price.conf = conf;
        priceFeed.price.expo = expo;
        priceFeed.price.publishTime = publishTime;

        priceFeed.emaPrice.price = emaPrice;
        priceFeed.emaPrice.conf = emaConf;
        priceFeed.emaPrice.expo = expo;
        priceFeed.emaPrice.publishTime = publishTime;

        priceFeedData = abi.encode(priceFeed, prevPublishTime);
    }

    function packPriceData(uint8[] calldata _indexes, uint256[] calldata _prices, uint256[] calldata _decimals)
        external
        pure
        returns (uint256[] memory packedPrices)
    {}

    function getAsset(bytes32 _assetId) external view returns (Oracle.Asset memory) {
        return assets[_assetId];
    }

    function getPrimaryPrice(bytes32 _assetId) external view returns (Oracle.Price memory) {
        return prices[_assetId];
    }

    function updateFee(bytes[] calldata _priceUpdateData) external view returns (uint256) {
        return getUpdateFee(_priceUpdateData);
    }
}
