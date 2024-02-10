// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {IPyth} from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import {PythStructs} from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";
import {IPriceFeed} from "./interfaces/IPriceFeed.sol";
import {RoleValidation} from "../access/RoleValidation.sol";
import {Oracle} from "./Oracle.sol";

contract PriceFeed is IPriceFeed, RoleValidation {
    IPyth pyth;

    uint256 public constant PRICE_PRECISION = 1e18;
    // uint256(~0) is 256 bits of 1s
    // shift the 1s by (256 - 32) to get (256 - 32) 0s followed by 32 1s
    uint256 public constant BITMASK_32 = type(uint256).max >> (256 - 32);

    uint256 public constant BASIS_POINTS_DIVISOR = 10000;

    uint256 public constant MAX_PRICE_DURATION = 30 minutes;

    address public longToken;
    address public shortToken;
    uint256 public secondaryPriceFee; // Fee for updating secondary prices
    uint256 public lastUpdateBlock; // Used to get cached prices

    mapping(address token => Oracle.Asset asset) private assets;
    // To Store Pyth Price Data
    mapping(uint256 block => mapping(address token => PythStructs.Price price)) private pythPriceData;
    // To Store Secondary Price Data
    mapping(address token => mapping(uint256 block => uint256 price)) public secondaryPrices;
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
        bytes32 _longPriceId,
        uint256 _longBaseUnit,
        address _shortToken,
        bytes32 _shortPriceId,
        uint256 _shortBaseUnit,
        address _roleStorage
    ) RoleValidation(_roleStorage) {
        pyth = IPyth(_pythContract);
        longToken = _longToken;
        shortToken = _shortToken;
        // Construct Long and Short Token Assets
        assets[_longToken] = Oracle.Asset(true, _longPriceId, _longBaseUnit, Oracle.PriceProvider.PYTH);
        assets[_shortToken] = Oracle.Asset(true, _shortPriceId, _shortBaseUnit, Oracle.PriceProvider.PYTH);
    }

    function supportAsset(address _token, bytes32 _priceId, uint256 _baseUnit, Oracle.PriceProvider _provider)
        external
        onlyMarketMaker
    {
        assets[_token] = Oracle.Asset(true, _priceId, _baseUnit, _provider);
    }

    function unsupportAsset(address _token) external onlyAdmin {
        assets[_token].isValid = false;
    }

    // @audit - how do we check the validity of price update data
    // who can call?
    function signPriceData(address _token, bytes[] calldata _priceUpdateData)
        external
        payable
        validFee(_priceUpdateData)
    {
        // Check if the token is whitelisted
        require(assets[_token].isValid, "Oracle: Invalid Token");
        uint256 currentBlock = block.number;
        // Check if the price has already been signed for _token
        if (pythPriceData[currentBlock][_token].price != 0) {
            // No need to check for Long / Short Token here
            // If _token has been signed, it's safe to assume so have the Long/Short Tokens
            return;
        }
        // Update Storage
        lastUpdateBlock = currentBlock;
        // Update the Price Feeds
        pyth.updatePriceFeeds{value: msg.value}(_priceUpdateData);

        // Store the price for the current block
        PythStructs.Price memory data = pyth.getPrice(assets[_token].priceId);
        pythPriceData[currentBlock][_token] = data;

        // Check if the Long/Short Tokens have been signed
        if (pythPriceData[currentBlock][longToken].price == 0) {
            PythStructs.Price memory longPrice = pyth.getPrice(assets[longToken].priceId);
            pythPriceData[currentBlock][longToken] = longPrice;
        }

        if (pythPriceData[currentBlock][shortToken].price == 0) {
            PythStructs.Price memory shortPrice = pyth.getPrice(assets[shortToken].priceId);
            pythPriceData[currentBlock][shortToken] = shortPrice;
        }

        emit PriceDataSigned(_token, currentBlock, data);
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

    function setSecondaryPrices(address[] memory _secondaryTokens, uint256[] memory _prices, uint256 _block)
        external
        onlyKeeper
    {
        for (uint256 i = 0; i < _secondaryTokens.length; i++) {
            address token = _secondaryTokens[i];
            _setPrice(token, _prices[i], _block);
        }
    }

    function setPricesWithBits(uint256 _priceBits, uint256 _block) external onlyKeeper {
        _setPricesWithBits(_priceBits, _block);
    }

    function _setPricesWithBits(uint256 _priceBits, uint256 _block) private {
        for (uint256 j = 0; j < 8; j++) {
            uint256 index = j;
            if (index >= secondaryTokens.length) return;

            uint256 startBit = 32 * j;
            uint256 price = (_priceBits >> startBit) & BITMASK_32;

            address token = secondaryTokens[j];
            uint256 tokenPrecision = tokenPrecisions[j];
            uint256 adjustedPrice = (price * PRICE_PRECISION) / tokenPrecision;

            _setPrice(token, adjustedPrice, _block);
        }
    }

    function _setPrice(address _token, uint256 _price, uint256 _block) private {
        lastSecondaryUpdateBlock[_token] = _block;
        secondaryPrices[_token][_block] = _price;
    }

    /////////////
    // GETTERS //
    /////////////

    function getPriceData(uint256 _block, address _token) external view returns (PythStructs.Price memory) {
        return pythPriceData[_block][_token];
    }

    function getSecondaryPrice(address _token, uint256 _block) external view returns (uint256) {
        return secondaryPrices[_token][_block];
    }

    function getAsset(address _token) external view returns (Oracle.Asset memory) {
        return assets[_token];
    }

    function getPrimaryUpdateFee(bytes[] calldata _priceUpdateData) external view returns (uint256) {
        return pyth.getUpdateFee(_priceUpdateData);
    }
}
