// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {IPyth} from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import {PythStructs} from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";
import {IPriceFeed} from "./interfaces/IPriceFeed.sol";
import {RoleValidation} from "../access/RoleValidation.sol";
import {Oracle} from "./Oracle.sol";
import {IChainlinkFeed} from "./interfaces/IChainlinkFeed.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract PriceFeed is IPriceFeed, RoleValidation {
    IPyth pyth;

    uint256 public constant PRICE_PRECISION = 1e18;

    // shift the 1s by (256 - 32) to get (256 - 32) 0s followed by 32 1s
    uint256 public constant BITMASK_32 = type(uint256).max >> (256 - 32);

    uint256 public constant BASIS_POINTS_DIVISOR = 10000;

    uint256 public constant MAX_PRICE_DURATION = 30 minutes;

    uint256 public constant MAX_PRICE_PER_WORD = 10;

    uint256 public constant PRICE_DECIMALS = 18;

    address public longToken;
    address public shortToken;
    uint256 public secondaryPriceFee; // Fee for updating secondary prices
    uint256 public lastUpdateBlock; // Used to get cached prices
    address public sequencerUptimeFeed;

    mapping(address token => Oracle.Asset asset) private assets;
    // To Store Price Data
    mapping(address token => mapping(uint256 block => Oracle.Price price)) public prices;
    // Not sure if need - review
    mapping(address token => uint256 block) public lastSecondaryUpdateBlock;

    // Array of tokens whose pricing comes from external nodes
    address[] public alternativeAssets;
    // array of tokenPrecision used in setCompactedPrices, saves L1 calldata gas costs
    // if the token price will be sent with 3 decimals, then tokenPrecision for that token
    // should be 10 ** 3
    uint256 public tokenPrecision;

    modifier validFee(bytes[] calldata _priceUpdateData) {
        require(msg.value >= pyth.getUpdateFee(_priceUpdateData), "PriceFeed: Insufficient fee");
        _;
    }

    constructor(
        address _pythContract,
        address _longToken,
        address _shortToken,
        Oracle.Asset memory _longAsset,
        Oracle.Asset memory _shortAsset,
        address _sequencerUptimeFeed,
        address _roleStorage
    ) RoleValidation(_roleStorage) {
        pyth = IPyth(_pythContract);
        longToken = _longToken;
        shortToken = _shortToken;
        assets[_longToken] = _longAsset;
        assets[_shortToken] = _shortAsset;
        sequencerUptimeFeed = _sequencerUptimeFeed;
        tokenPrecision = 1000;
    }

    function supportAsset(address _token, Oracle.Asset memory _asset) external onlyMarketMaker {
        assets[_token] = _asset;
    }

    function unsupportAsset(address _token) external onlyAdmin {
        delete assets[_token];
    }

    function updateSequenceUptimeFeed(address _sequencerUptimeFeed) external onlyAdmin {
        sequencerUptimeFeed = _sequencerUptimeFeed;
    }

    // @audit - how do we check the validity of price update data
    // who can call?
    // if status is unknown, invalidate
    function signPriceData(address _token, bytes[] calldata _priceUpdateData)
        external
        payable
        validFee(_priceUpdateData)
    {
        // Check if the token is whitelisted
        Oracle.Asset memory indexAsset = assets[_token];
        require(indexAsset.isValid, "Oracle: Invalid Token");
        // Check Sequencer Uptime
        Oracle.isSequencerUp(this);
        uint256 currentBlock = block.number;
        // Check if the price has already been signed for _token
        if (prices[_token][currentBlock].max != 0) {
            // No need to check for Long / Short Token here
            // If _token has been signed, it's safe to assume so have the Long/Short Tokens
            return;
        }
        // Update Storage
        lastUpdateBlock = currentBlock;
        // Update the Price Feeds
        pyth.updatePriceFeeds{value: msg.value}(_priceUpdateData);

        // Store the price for the current block
        PythStructs.Price memory data = pyth.getPrice(indexAsset.priceId);
        Oracle.Price memory indexPrice = Oracle.deconstructPythPrice(data);
        uint256 indexRefPrice = Oracle.getReferencePrice(this, indexAsset);
        if (indexRefPrice > 0) {
            // Check the Price is within range
            Oracle.validatePriceRange(indexAsset, indexPrice, indexRefPrice);
        }
        // Deconstruct the price into an Oracle.Price struct
        // Store the Price Data in the Price Mapping
        prices[_token][currentBlock] = indexPrice;

        // Check if the Long/Short Tokens have been signed
        if (prices[longToken][currentBlock].max == 0) {
            Oracle.Asset memory longAsset = assets[longToken];
            PythStructs.Price memory longData = pyth.getPrice(longAsset.priceId);
            Oracle.Price memory longPrice = Oracle.deconstructPythPrice(longData);
            // Reference price should always exist
            uint256 longRefPrice = Oracle.getReferencePrice(this, longAsset);
            Oracle.validatePriceRange(longAsset, longPrice, longRefPrice);
            // Get ref price and validate price is within range
            prices[longToken][currentBlock] = longPrice;
        }

        if (prices[shortToken][currentBlock].max == 0) {
            Oracle.Asset memory shortAsset = assets[shortToken];
            PythStructs.Price memory shortData = pyth.getPrice(shortAsset.priceId);
            Oracle.Price memory shortPrice = Oracle.deconstructPythPrice(shortData);
            // Reference price should always exist
            uint256 shortRefPrice = Oracle.getReferencePrice(this, shortAsset);
            Oracle.validatePriceRange(shortAsset, shortPrice, shortRefPrice);
            // Get ref price and validate price is within range
            prices[shortToken][currentBlock] = shortPrice;
        }

        emit PriceDataSigned(_token, currentBlock, data);
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
        PythStructs.Price memory longData = pyth.getPriceUnsafe(assets[longToken].priceId);
        PythStructs.Price memory shortData = pyth.getPriceUnsafe(assets[shortToken].priceId);
        longPrice = Oracle.deconstructPythPrice(longData);
        shortPrice = Oracle.deconstructPythPrice(shortData);
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
    ) public pure returns (bytes memory priceFeedData) {
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

    ////////////////////////
    // ALTERNATIVE ASSETS //
    ////////////////////////

    function setAlternativeAssets(address[] memory _alternativeAssets) external onlyAdmin {
        alternativeAssets = _alternativeAssets;
    }

    function setTokenPrecision(uint256 _tokenPrecision) external onlyAdmin {
        tokenPrecision = _tokenPrecision;
    }

    // Set Prices for Alternative Assets - Gas Inefficient
    function setAssetPrices(Oracle.Price[] memory _prices, uint256 _block) external onlyKeeper {
        address[] memory tokens = alternativeAssets;
        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            _setPrice(token, _prices[i].max, _prices[i].min, _block);
        }
    }

    // @audit - gas
    function setPricesWithBits(uint256[] calldata _priceBits, uint256 _block) external onlyKeeper {
        uint256 len = alternativeAssets.length;
        uint256 loops = Math.ceilDiv(len, 4);
        for (uint256 i = 0; i < loops; i++) {
            uint256 start = i * 4;
            uint256 end = start + 4;
            if (end > len) {
                end = len;
            }
            address[] memory assetsToSet = new address[](end - start);
            for (uint256 j = start; j < end; j++) {
                assetsToSet[j - start] = alternativeAssets[j];
            }
            _setPricesWithBits(assetsToSet, _priceBits[i], _block);
        }
    }

    function _setPricesWithBits(address[] memory _assets, uint256 _priceBits, uint256 _block) private {
        for (uint256 i = 0; i < 4; ++i) {
            uint256 index = i;
            if (index >= _assets.length) return;

            uint256 startBit = i * 64;
            uint256 maxPrice = (_priceBits >> startBit) & BITMASK_32;
            uint256 minPrice = (_priceBits >> (startBit + 32)) & BITMASK_32;

            address token = _assets[index];
            _setPrice(
                token,
                (maxPrice * PRICE_PRECISION) / tokenPrecision,
                (minPrice * PRICE_PRECISION) / tokenPrecision,
                _block
            );
        }
    }

    function _setPrice(address _token, uint256 _maxPrice, uint256 _minPrice, uint256 _block) private {
        lastSecondaryUpdateBlock[_token] = _block;
        Oracle.Price memory price = Oracle.Price({max: _maxPrice, min: _minPrice});
        prices[_token][_block] = price;
    }

    /////////////
    // GETTERS //
    /////////////

    function getPrice(uint256 _block, address _token) external view returns (Oracle.Price memory) {
        return prices[_token][_block];
    }

    function getAsset(address _token) external view returns (Oracle.Asset memory) {
        return assets[_token];
    }

    function getPrimaryUpdateFee(bytes[] calldata _priceUpdateData) external view returns (uint256) {
        return pyth.getUpdateFee(_priceUpdateData);
    }
}
