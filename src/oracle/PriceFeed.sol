// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {IPyth} from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import {PythStructs} from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";
import {IPriceFeed} from "./interfaces/IPriceFeed.sol";
import {RoleValidation} from "../access/RoleValidation.sol";
import {Oracle} from "./Oracle.sol";
import {IChainlinkFeed} from "./interfaces/IChainlinkFeed.sol";

contract PriceFeed is IPriceFeed, RoleValidation {
    IPyth pyth;

    uint256 public constant PRICE_PRECISION = 1e18;
    // uint256(~0) is 256 bits of 1s
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

    // array of tokens used in setCompactedPrices, saves L1 calldata gas costs
    address[] public secondaryTokens;
    // array of tokenPrecisions used in setCompactedPrices, saves L1 calldata gas costs
    // if the token price will be sent with 3 decimals, then tokenPrecision for that token
    // should be 10 ** 3
    uint256[] public tokenPrecisions;

    modifier validFee(bytes[] calldata _priceUpdateData) {
        require(msg.value >= pyth.getUpdateFee(_priceUpdateData), "Oracle: Insufficient fee");
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
    function getPriceUnsafe(Oracle.Asset memory _asset) external view returns (uint256 price) {
        PythStructs.Price memory data = pyth.getPriceUnsafe(_asset.priceId);
        (price,) = Oracle.convertPythParams(data);
    }

    ///////////////////////
    // SECONDARY PRICING //
    ///////////////////////

    function setSecondaryTokens(address[] memory _secondaryTokens, uint256[] memory _tokenPrecisions)
        external
        onlyAdmin
    {
        require(_secondaryTokens.length == _tokenPrecisions.length, "SecondaryPriceFeed: invalid lengths");
        secondaryTokens = _secondaryTokens;
        tokenPrecisions = _tokenPrecisions;
    }

    // function setSecondaryPrices(address[] memory _secondaryTokens, uint256[] memory _prices, uint256 _block)
    //     external
    //     onlyKeeper
    // {
    //     for (uint256 i = 0; i < _secondaryTokens.length; i++) {
    //         address token = _secondaryTokens[i];
    //         _setPrice(token, _prices[i], _block);
    //     }
    // }

    // function setPricesWithBits(uint256 _priceBits, uint256 _block) external onlyKeeper {
    //     _setPricesWithBits(_priceBits, _block);
    // }

    // function _setPricesWithBits(uint256 _priceBits, uint256 _block) private {
    //     for (uint256 j = 0; j < 8; j++) {
    //         uint256 index = j;
    //         if (index >= secondaryTokens.length) return;

    //         uint256 startBit = 32 * j;
    //         uint256 price = (_priceBits >> startBit) & BITMASK_32;

    //         address token = secondaryTokens[j];
    //         uint256 tokenPrecision = tokenPrecisions[j];
    //         uint256 adjustedPrice = (price * PRICE_PRECISION) / tokenPrecision;

    //         _setPrice(token, adjustedPrice, _block);
    //     }
    // }

    // function _setPrice(address _token, uint256 _price, uint256 _confidence, uint256 _block) private {
    //     lastSecondaryUpdateBlock[_token] = _block;
    //     Oracle.Price memory price = Oracle.Price({max: _price + _confidence, min: _price - _confidence});
    //     prices[_token][_block] = price;
    // }

    //////////////////
    // CONSTRUCTORS //
    //////////////////

    function constructPriceUpdateData(int24[] calldata _prices)
        external
        pure
        returns (bytes32[] memory _priceUpdateData)
    {
        _priceUpdateData = new bytes32[]((_prices.length + MAX_PRICE_PER_WORD - 1) / MAX_PRICE_PER_WORD);
        for (uint256 i; i < _prices.length; ++i) {
            uint256 outerIndex = i / MAX_PRICE_PER_WORD;
            uint256 innerIndex = i % MAX_PRICE_PER_WORD;
            bytes32 partialWord =
                bytes32(uint256(uint24(_prices[i])) << (24 * (MAX_PRICE_PER_WORD - 1 - innerIndex) + 16));
            _priceUpdateData[outerIndex] |= partialWord;
        }
    }

    function constructPublishTimeUpdateData(uint24[] calldata _publishTimeDiff)
        external
        pure
        returns (bytes32[] memory _publishTimeUpdateData)
    {
        _publishTimeUpdateData = new bytes32[]((_publishTimeDiff.length + MAX_PRICE_PER_WORD - 1) / MAX_PRICE_PER_WORD);
        for (uint256 i; i < _publishTimeDiff.length; ++i) {
            uint256 outerIndex = i / MAX_PRICE_PER_WORD;
            uint256 innerIndex = i % MAX_PRICE_PER_WORD;
            bytes32 partialWord =
                bytes32(uint256(_publishTimeDiff[i]) << (24 * (MAX_PRICE_PER_WORD - 1 - innerIndex) + 16));
            _publishTimeUpdateData[outerIndex] |= partialWord;
        }
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
