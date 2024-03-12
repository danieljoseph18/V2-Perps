// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.23;

import {MockPyth} from "@pythnetwork/pyth-sdk-solidity/MockPyth.sol";
import {IPriceFeed} from "../../src/oracle/interfaces/IPriceFeed.sol";
import {Oracle} from "../../src/oracle/Oracle.sol";
import {PythStructs} from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract MockPriceFeed is MockPyth, IPriceFeed {
    uint256 public constant PRICE_PRECISION = 1e30;

    // shift the 1s by (256 - 32) to get (256 - 32) 0s followed by 32 1s
    uint256 public constant BITMASK_32 = type(uint256).max >> (256 - 32);

    uint256 public constant BASIS_POINTS_DIVISOR = 10000;

    uint256 public constant MAX_PRICE_DURATION = 30 minutes;

    uint256 public constant MAX_PRICE_PER_WORD = 10;

    uint256 public constant PRICE_DECIMALS = 30;

    uint256 public constant DEFAULT_SPREAD = 0.001e18; // 0.1%

    bytes32 public longTokenId;
    bytes32 public shortTokenId;
    uint256 public updateFee;
    uint256 public lastUpdateBlock; // Used to get cached prices
    address public sequencerUptimeFeed;

    mapping(bytes32 assetId => Oracle.Asset asset) private assets;
    // To Store Price Data
    mapping(bytes32 assetId => mapping(uint256 block => Oracle.Price price)) public prices;

    constructor(
        uint256 _validTimePeriod,
        uint256 _singleUpdateFeeInWei,
        bytes32 _longTokenId,
        bytes32 _shortTokenId,
        Oracle.Asset memory _longAsset,
        Oracle.Asset memory _shortAsset
    ) MockPyth(_validTimePeriod, _singleUpdateFeeInWei) {
        longTokenId = _longTokenId;
        assets[_longTokenId] = _longAsset;
        priceFeeds[_longAsset.priceId] = PythStructs.PriceFeed({
            id: _longAsset.priceId,
            price: PythStructs.Price({price: 0, conf: 0, expo: 0, publishTime: 0}),
            emaPrice: PythStructs.Price({price: 0, conf: 0, expo: 0, publishTime: 0})
        });
        shortTokenId = _shortTokenId;
        assets[_shortTokenId] = _shortAsset;
        priceFeeds[_shortAsset.priceId] = PythStructs.PriceFeed({
            id: _shortAsset.priceId,
            price: PythStructs.Price({price: 0, conf: 0, expo: 0, publishTime: 0}),
            emaPrice: PythStructs.Price({price: 0, conf: 0, expo: 0, publishTime: 0})
        });
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

    function updateSequenceUptimeFeed(address _sequencerUptimeFeed) external {
        sequencerUptimeFeed = _sequencerUptimeFeed;
    }

    function signPrimaryPrice(bytes32 _assetId, bytes[] calldata _priceUpdateData) external payable {
        // If already signed, no need to sign again
        if (prices[_assetId][block.number].price != 0) return;

        // Check if the sequencer is up
        Oracle.isSequencerUp(this);

        // Fetch the Asset
        Oracle.Asset memory asset = assets[_assetId];
        if (!asset.isValid) revert PriceFeed_InvalidToken();

        // Parse the update data based on the settlement strategy
        if (asset.primaryStrategy == Oracle.PrimaryStrategy.PYTH) {
            // Pyth Update Data: [bytes32 id, int64 price, uint64 conf, int32 expo, int64 emaPrice, uint64 emaConf, uint64 publishTime, uint64 prevPublishTime]
            updatePriceFeeds(_priceUpdateData);

            // Parse the Update Data
            PythStructs.Price memory data = queryPriceFeed(asset.priceId).price;
            Oracle.Price memory indexPrice = Oracle.parsePythData(data);

            // Validate the parsed data
            uint256 indexRefPrice = Oracle.getReferencePrice(asset);
            if (asset.secondaryStrategy != Oracle.SecondaryStrategy.NONE) {
                // Check the Price is within range if it has a reference
                Oracle.validatePriceRange(asset, indexPrice, indexRefPrice);
            }

            // Store the signed price in the prices mapping
            prices[_assetId][block.number] = indexPrice;

            // Sign the Long/Short prices if not already signed
            if (prices[longTokenId][block.number].price == 0) {
                Oracle.Asset memory longAsset = assets[longTokenId];
                PythStructs.Price memory longData = queryPriceFeed(longAsset.priceId).price;
                Oracle.Price memory longPrice = Oracle.parsePythData(longData);
                // Reference price should always exist
                uint256 longRefPrice = Oracle.getReferencePrice(longAsset);
                Oracle.validatePriceRange(longAsset, longPrice, longRefPrice);
                // Get ref price and validate price is within range
                prices[longTokenId][block.number] = longPrice;
            }

            if (prices[shortTokenId][block.number].price == 0) {
                Oracle.Asset memory shortAsset = assets[shortTokenId];
                PythStructs.Price memory shortData = queryPriceFeed(shortAsset.priceId).price;
                Oracle.Price memory shortPrice = Oracle.parsePythData(shortData);
                // Reference price should always exist
                uint256 shortRefPrice = Oracle.getReferencePrice(shortAsset);
                Oracle.validatePriceRange(shortAsset, shortPrice, shortRefPrice);
                // Get ref price and validate price is within range
                prices[shortTokenId][block.number] = shortPrice;
            }

            // Pay the update fee to post the data
            // TODO: Implement the fee payment logic
        } else if (asset.primaryStrategy == Oracle.PrimaryStrategy.OFFCHAIN) {
            // Parse the Update Data
            (Oracle.Price memory indexPrice, Oracle.Price memory longPrice, Oracle.Price memory shortPrice) =
                Oracle.parsePriceData(_priceUpdateData[0]);

            // Validate the parsed data
            if (asset.secondaryStrategy != Oracle.SecondaryStrategy.NONE) {
                uint256 indexRefPrice = Oracle.getReferencePrice(asset);
                // Check the Price is within range if it has a reference
                Oracle.validatePriceRange(asset, indexPrice, indexRefPrice);
            }

            // Store the signed price in the prices mapping
            prices[_assetId][block.number] = indexPrice; // 100% Confidence

            if (prices[longTokenId][block.number].price == 0) {
                Oracle.Asset memory longAsset = assets[longTokenId];
                // Reference price should always exist
                uint256 longRefPrice = Oracle.getReferencePrice(longAsset);
                Oracle.validatePriceRange(longAsset, longPrice, longRefPrice);
                // Get ref price and validate price is within range
                prices[longTokenId][block.number] = longPrice;
            }

            if (prices[shortTokenId][block.number].price == 0) {
                Oracle.Asset memory shortAsset = assets[shortTokenId];
                // Reference price should always exist
                uint256 shortRefPrice = Oracle.getReferencePrice(shortAsset);
                Oracle.validatePriceRange(shortAsset, shortPrice, shortRefPrice);
                // Get ref price and validate price is within range
                prices[shortTokenId][block.number] = shortPrice;
            }
        } else {
            revert PriceFeed_InvalidPrimaryStrategy();
        }
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
        PythStructs.Price memory longData = queryPriceFeed(assets[longTokenId].priceId).price;
        PythStructs.Price memory shortData = queryPriceFeed(assets[shortTokenId].priceId).price;
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

    // For Off-Chain Settlement Strategy
    function encodePriceData(uint64 _indexPrice, uint64 _longPrice, uint64 _shortPrice, uint8 _decimals)
        external
        pure
        returns (bytes memory offchainPriceData)
    {
        offchainPriceData = abi.encode(_indexPrice, _longPrice, _shortPrice, _decimals);
    }

    /////////////
    // GETTERS //
    /////////////

    function getPrice(bytes32 _assetId, uint256 _block) external view returns (Oracle.Price memory) {
        return prices[_assetId][_block];
    }

    function getAsset(bytes32 _assetId) external view returns (Oracle.Asset memory) {
        return assets[_assetId];
    }
}
