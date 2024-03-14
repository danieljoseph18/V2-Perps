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

    address public sequencerUptimeFeed;
    // Asset ID is the Hash of the ticker symbol -> e.g keccak256(abi.encode("ETH"));
    mapping(bytes32 assetId => Oracle.Asset asset) private assets;
    // To Store Price Data
    mapping(bytes32 assetId => Oracle.Price price) public prices;

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

    receive() external payable {}

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
    function signPrimaryPrice(bytes32 _assetId, bytes[] calldata _priceUpdateData)
        external
        payable
        onlyKeeper
        nonReentrant
    {
        // Check if the sequencer is up (move this check outside the function if possible)
        Oracle.isSequencerUp(this);

        // Check if the asset price has already been signed
        if (_assetId != bytes32(0) && prices[_assetId].price != 0) return;

        // Default to Pyth for Market Tokens
        if (_assetId == bytes32(0)) {
            // Update prices for long and short assets
            uint256 fee = pyth.getUpdateFee(_priceUpdateData);
            if (msg.value < fee) revert PriceFeed_InsufficientFee();
            pyth.updatePriceFeeds{value: fee}(_priceUpdateData);
            if (prices[longTokenId].price == 0) {
                _updatePythPrice(longTokenId, assets[longTokenId]);
            }
            if (prices[shortTokenId].price == 0) {
                _updatePythPrice(shortTokenId, assets[shortTokenId]);
            }
        } else {
            // Fetch the asset
            Oracle.Asset memory asset = assets[_assetId];
            if (!asset.isValid) revert PriceFeed_InvalidToken();

            // Update price based on the primary strategy
            if (asset.primaryStrategy == Oracle.PrimaryStrategy.PYTH) {
                // Check if the fee is sufficient and update price feeds
                uint256 fee = pyth.getUpdateFee(_priceUpdateData);
                if (msg.value < fee) revert PriceFeed_InsufficientFee();
                pyth.updatePriceFeeds{value: fee}(_priceUpdateData);
                // Asset
                _updatePythPrice(_assetId, asset);
                // Long Token
                if (prices[longTokenId].price == 0) {
                    _updatePythPrice(longTokenId, assets[longTokenId]);
                }
                // Short Token
                if (prices[shortTokenId].price == 0) {
                    _updatePythPrice(shortTokenId, assets[shortTokenId]);
                }
            } else if (asset.primaryStrategy == Oracle.PrimaryStrategy.OFFCHAIN) {
                // Asset
                _updateOffchainPrice(_assetId, asset, _priceUpdateData[0]);
                // Long Token
                if (prices[longTokenId].price == 0) {
                    _updateOffchainPrice(longTokenId, assets[longTokenId], _priceUpdateData[1]);
                }
                // Short Token
                if (prices[shortTokenId].price == 0) {
                    _updateOffchainPrice(shortTokenId, assets[shortTokenId], _priceUpdateData[2]);
                }
            } else {
                revert PriceFeed_InvalidPrimaryStrategy();
            }
        }
    }

    function clearPrimaryPrice(bytes32 _assetId) external onlyKeeper {
        if (_assetId != bytes32(0)) delete prices[_assetId];
        delete prices[longTokenId];
        delete prices[shortTokenId];
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

    function _updatePythPrice(bytes32 _assetId, Oracle.Asset memory _asset) internal {
        PythStructs.Price memory data = pyth.getPrice(_asset.priceId);
        Oracle.Price memory price = Oracle.parsePythData(data);

        if (_asset.secondaryStrategy != Oracle.SecondaryStrategy.NONE) {
            uint256 refPrice = Oracle.getReferencePrice(_asset);
            Oracle.validatePriceRange(_asset, price, refPrice);
        }

        prices[_assetId] = price;
    }

    function _updateOffchainPrice(bytes32 _assetId, Oracle.Asset memory _asset, bytes memory _priceData) internal {
        (Oracle.Price memory price,,) = Oracle.parsePriceData(_priceData);

        if (_asset.secondaryStrategy != Oracle.SecondaryStrategy.NONE) {
            uint256 refPrice = Oracle.getReferencePrice(_asset);
            Oracle.validatePriceRange(_asset, price, refPrice);
        }

        prices[_assetId] = price;
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
