// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {IPyth} from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import {PythStructs} from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";
import {IPriceFeed} from "./interfaces/IPriceFeed.sol";
import {RoleValidation} from "../access/RoleValidation.sol";
import {Oracle} from "./Oracle.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@solmate/utils/ReentrancyGuard.sol";

contract PriceFeed is IPriceFeed, RoleValidation, ReentrancyGuard {
    IPyth pyth;

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
    // Asset ID is the Hash of the ticker symbol -> e.g keccak256(abi.encode("ETH"));
    mapping(bytes32 assetId => Oracle.Asset asset) private assets;
    // To Store Price Data
    mapping(bytes32 assetId => mapping(uint256 block => Oracle.Price price)) public prices;

    constructor(
        address _pythContract,
        bytes32 _longTokenId,
        bytes32 _shortTokenId,
        Oracle.Asset memory _longAsset,
        Oracle.Asset memory _shortAsset,
        address _sequencerUptimeFeed,
        address _roleStorage
    ) RoleValidation(_roleStorage) {
        pyth = IPyth(_pythContract);
        longTokenId = _longTokenId;
        shortTokenId = _shortTokenId;
        assets[_longTokenId] = _longAsset;
        assets[_shortTokenId] = _shortAsset;
        sequencerUptimeFeed = _sequencerUptimeFeed;
    }

    function supportAsset(bytes32 _assetId, Oracle.Asset memory _asset) external onlyMarketMaker {
        assets[_assetId] = _asset;
    }

    function unsupportAsset(bytes32 _assetId) external onlyAdmin {
        delete assets[_assetId];
    }

    function updateSequenceUptimeFeed(address _sequencerUptimeFeed) external onlyAdmin {
        sequencerUptimeFeed = _sequencerUptimeFeed;
    }

    /**
     * Asset ID = Keccak256(Asset Ticker) -> e.g keccak256(abi.encode("ETH"));
     * Update Data -> Data to update price for either Pyth strategy or Off-chain strategy
     * Argument Format:
     * - Pyth Update Data: [bytes32 id, int64 price, uint64 conf, int32 expo, int64 emaPrice, uint64 emaConf, uint64 publishTime, uint64 prevPublishTime]
     * - Off-chain Update Data: [uint64 indexPrice, uint64 longPrice, uint64 shortPrice, uint8 decimals]
     * - Should be in the order (AssetUpdateData, LongTokenUpdateData, ShortTokenUpdateData)
     */
    // @audit - add gas rebates & payments to keepers
    function signPrimaryPrice(bytes32 _assetId, bytes[] calldata _priceUpdateData) external payable onlyKeeper {
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
            if (msg.value < pyth.getUpdateFee(_priceUpdateData)) revert PriceFeed_InsufficientFee();
            pyth.updatePriceFeeds{value: msg.value}(_priceUpdateData);

            // Parse the Update Data
            PythStructs.Price memory data = pyth.getPrice(asset.priceId);
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
                PythStructs.Price memory longData = pyth.getPrice(longAsset.priceId);
                Oracle.Price memory longPrice = Oracle.parsePythData(longData);
                // Reference price should always exist
                uint256 longRefPrice = Oracle.getReferencePrice(longAsset);
                Oracle.validatePriceRange(longAsset, longPrice, longRefPrice);
                // Get ref price and validate price is within range
                prices[longTokenId][block.number] = longPrice;
            }

            if (prices[shortTokenId][block.number].price == 0) {
                Oracle.Asset memory shortAsset = assets[shortTokenId];
                PythStructs.Price memory shortData = pyth.getPrice(shortAsset.priceId);
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

    // Only used as Reference
    function getPriceUnsafe(Oracle.Asset memory _asset) external view returns (uint256 price, uint256 confidence) {
        PythStructs.Price memory data = pyth.getPriceUnsafe(_asset.priceId);
        (price, confidence) = Oracle.convertPythParams(data);
    }

    function getAssetPricesUnsafe()
        external
        view
        returns (Oracle.Price memory longPrice, Oracle.Price memory shortPrice)
    {
        PythStructs.Price memory longData = pyth.getPriceUnsafe(assets[longTokenId].priceId);
        PythStructs.Price memory shortData = pyth.getPriceUnsafe(assets[shortTokenId].priceId);
        longPrice = Oracle.parsePythData(longData);
        shortPrice = Oracle.parsePythData(shortData);
    }

    // For Pyth Settlement Strategy
    function createPriceFeedUpdateData(
        bytes32 id,
        int64 price,
        uint64 conf,
        int32 expo,
        int64 emaPrice,
        uint64 emaConf,
        uint64 publishTime,
        uint64 prevPublishTime
    ) external pure returns (bytes memory priceFeedData) {
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

    function getPrice(bytes32 _assetId, uint256 _block) external view returns (Oracle.Price memory) {
        return prices[_assetId][_block];
    }

    function getAsset(bytes32 _assetId) external view returns (Oracle.Asset memory) {
        return assets[_assetId];
    }
}
