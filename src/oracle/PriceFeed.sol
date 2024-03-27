// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IPyth} from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import {PythStructs} from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";
import {IPriceFeed} from "./interfaces/IPriceFeed.sol";
import {RoleValidation} from "../access/RoleValidation.sol";
import {Oracle} from "./Oracle.sol";
import {ReentrancyGuard} from "@solmate/utils/ReentrancyGuard.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

contract PriceFeed is IPriceFeed, RoleValidation, ReentrancyGuard {
    using EnumerableSet for EnumerableSet.Bytes32Set;

    IPyth pyth;

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
        address _pythContract,
        bytes32 _longAssetId,
        bytes32 _shortAssetId,
        Oracle.Asset memory _longAsset,
        Oracle.Asset memory _shortAsset,
        address _sequencerUptimeFeed,
        address _roleStorage
    ) RoleValidation(_roleStorage) {
        pyth = IPyth(_pythContract);
        sequencerUptimeFeed = _sequencerUptimeFeed;
        // Set up Long Asset
        longAssetId = _longAssetId;
        assets[_longAssetId] = _longAsset;
        // Set up Short Asset
        shortAssetId = _shortAssetId;
        assets[_shortAssetId] = _shortAsset;
    }

    receive() external payable {}

    modifier sequencerUp() {
        Oracle.isSequencerUp(this);
        _;
    }

    function setAverageGasParameters(uint256 _averagePriceUpdateCost, uint256 _additionalCostPerAsset)
        external
        onlyAdmin
    {
        if (_averagePriceUpdateCost == 0 || _additionalCostPerAsset == 0) revert PriceFeed_InvalidGasParams();
        averagePriceUpdateCost = _averagePriceUpdateCost;
        additionalCostPerAsset = _additionalCostPerAsset;
    }

    function supportAsset(bytes32 _assetId, Oracle.Asset memory _asset) external onlyMarketMaker {
        if (assets[_assetId].baseUnit != 0) return; // Return if already supported
        assets[_assetId] = _asset;
    }

    function unsupportAsset(bytes32 _assetId) external onlyAdmin {
        delete assets[_assetId];
    }

    function updateSequencerUptimeFeed(address _sequencerUptimeFeed) external onlyAdmin {
        sequencerUptimeFeed = _sequencerUptimeFeed;
    }

    /**
     * @param _compactedPriceData - Array of uint256 containing the compacted price data
     * Data is stored in uint64 slots inside each uint256. Each uint64 contains the price data for an asset
     * Data should be stored in the same order as the asset array.
     * As some assets will inevitably be priced using Pyth, there will be empty gaps in the
     * compacted price data array where this is the case.
     *
     * Example:
     * - Asset ID's = [ETH, BTC, SOL, TIA]
     * - Pyth Price Data = [ETH, BTC]
     * - Compacted Price Data = [uint64(0), uint64(0), uint64(SOL PRICE + DECIMALS), uint64(TIA PRICE + DECIMALS)]
     *
     * Pyth prices are updated together through the call to updatePriceFeeds.
     *
     * Compacted prices are fetched by mutliplying the asset id's index by 64, and extracting
     * , then unpacking the subsequent 64 bits.
     *
     * E.g SOL = 2 * 64 = 128 - 191
     * E.g TIA = 3 * 64 = 192 - 255
     */
    function setPrimaryPrices(
        bytes32[] calldata _assetIds,
        bytes[] calldata _pythPriceData,
        uint256[] calldata _compactedPriceData
    ) external payable onlyKeeper nonReentrant sequencerUp {
        // If any Pyth price array contains data
        if (_pythPriceData.length != 0) {
            // Get the Update Fee
            uint256 pythFee = pyth.getUpdateFee(_pythPriceData);
            if (msg.value < pythFee) revert PriceFeed_InsufficientFee();
            // Update the Price Fees with the Data
            pyth.updatePriceFeeds{value: pythFee}(_pythPriceData);
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
                PythStructs.Price memory data = pyth.getPrice(asset.priceId);
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

    function clearPrimaryPrices() external onlyKeeper {
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
        PythStructs.Price memory longData = pyth.getPriceUnsafe(assets[longAssetId].priceId);
        PythStructs.Price memory shortData = pyth.getPriceUnsafe(assets[shortAssetId].priceId);
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

    function packPriceData(uint8[] calldata _indexes, uint256[] calldata _prices, uint8[] calldata _decimals)
        external
        pure
        returns (uint256[] memory packedPrices)
    {
        require(_indexes.length == _prices.length && _indexes.length == _decimals.length, "Array lengths must match");

        uint256 maxIndex = 0;
        for (uint256 i = 0; i < _indexes.length; i++) {
            require(_indexes[i] < 4, "Index must be less than 4");
            require(_prices[i] < (1 << 56), "Price exceeds maximum value (2^56 - 1)");
            require(_decimals[i] < (1 << 8), "Decimal exceeds maximum value (2^8 - 1)");
            maxIndex = _indexes[i] > maxIndex ? _indexes[i] : maxIndex;
        }

        packedPrices = new uint256[]((maxIndex + 1 + 3) / 4);

        for (uint256 i = 0; i < _indexes.length; i++) {
            uint256 index = _indexes[i];
            uint256 price = _prices[i];
            uint256 decimal = _decimals[i];

            uint256 arrayIndex = index / 4;
            uint256 bitOffset = (index % 4) * 64;

            uint256 packedValue = (price << bitOffset) | (decimal << (bitOffset + 56));
            packedPrices[arrayIndex] |= packedValue;
        }
    }

    function getAsset(bytes32 _assetId) external view returns (Oracle.Asset memory) {
        return assets[_assetId];
    }

    function getPrimaryPrice(bytes32 _assetId) external view returns (Oracle.Price memory) {
        return prices[_assetId];
    }

    function updateFee(bytes[] calldata _priceUpdateData) external view returns (uint256) {
        return pyth.getUpdateFee(_priceUpdateData);
    }
}
