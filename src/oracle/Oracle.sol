// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {IPriceFeed} from "./interfaces/IPriceFeed.sol";
import {PythStructs} from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {IChainlinkFeed} from "./interfaces/IChainlinkFeed.sol";
import {IUniswapV3Pool} from "./interfaces/IUniswapV3Pool.sol";
import {IUniswapV2Pair} from "./interfaces/IUniswapV2Pair.sol";
import {mulDiv} from "@prb/math/Common.sol";
import {ud, UD60x18, unwrap} from "@prb/math/UD60x18.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

library Oracle {
    using SignedMath for int64;
    using SignedMath for int32;

    error Oracle_SequencerDown();
    error Oracle_InvalidTokenPrices();
    error Oracle_PriceTooHigh();
    error Oracle_PriceTooLow();
    error Oracle_InvalidChainlinkPrice();
    error Oracle_StaleChainlinkPrice();
    error Oracle_InvalidRefPrice();
    error Oracle_InvalidIndexPrice();
    error Oracle_InvalidPoolType();
    error Oracle_InvalidChainlinkFeed();

    // @gas - use smaller data types
    struct Asset {
        bool isValid;
        address chainlinkPriceFeed; // Chainlink Price Feed Address
        bytes32 priceId; // Pyth Price ID
        uint64 baseUnit; // 1 Unit of the Token e.g 1e18 for ETH
        uint32 heartbeatDuration; // Duration after which the price is considered stale
        uint256 maxPriceDeviation; // Max Price Deviation from Reference Price
        uint256 priceSpread; // Spread to Apply to Price if Alternative Asset (e.g $0.1 = 0.1e18)
        PrimaryStrategy primaryStrategy;
        SecondaryStrategy secondaryStrategy;
        UniswapPool pool; // Uniswap V3 Pool
    }

    struct UniswapPool {
        address token0;
        address token1;
        address poolAddress;
        PoolType poolType;
    }

    struct Price {
        uint256 price;
        uint256 confidence; // @gas - use smaller type
    }

    enum PrimaryStrategy {
        PYTH,
        OFFCHAIN
    }

    enum SecondaryStrategy {
        CHAINLINK,
        AMM,
        NONE
    }

    enum PoolType {
        UNISWAP_V3,
        UNISWAP_V2
    }

    uint64 private constant MAX_PERCENTAGE = 1e18; // 100%
    uint64 private constant SCALING_FACTOR = 1e18;
    uint8 private constant PRICE_DECIMALS = 30;
    uint8 private constant CHAINLINK_PRICE_DECIMALS = 8;

    function isValidAsset(IPriceFeed priceFeed, bytes32 _assetId) external view returns (bool) {
        return priceFeed.getAsset(_assetId).isValid;
    }

    function isSequencerUp(IPriceFeed priceFeed) external view {
        address sequencerUptimeFeed = priceFeed.sequencerUptimeFeed();
        if (sequencerUptimeFeed != address(0)) {
            IChainlinkFeed feed = IChainlinkFeed(sequencerUptimeFeed);
            (
                /*uint80 roundID*/
                ,
                int256 answer,
                /*uint256 startedAt*/
                ,
                /*uint256 updatedAt*/
                ,
                /*uint80 answeredInRound*/
            ) = feed.latestRoundData();

            // Answer == 0: Sequencer is up
            // Answer == 1: Sequencer is down
            bool isUp = answer == 0;
            if (!isUp) {
                revert Oracle_SequencerDown();
            }
        }
    }

    function parsePythData(PythStructs.Price memory _priceData) external pure returns (Price memory data) {
        (data.price, data.confidence) = convertPythParams(_priceData);
    }

    // Data passed in as 32 bytes - uint64, uint64, uint64, uint8
    // Deconstruct the data and return the values
    // Prices should have 30 decimals
    // Decimals just a regular uint
    function parsePriceData(bytes memory _priceData)
        external
        pure
        returns (Price memory indexPrice, Price memory longPrice, Price memory shortPrice)
    {
        (uint64 signedIndexPrice, uint64 signedLongPrice, uint64 signedShortPrice, uint8 decimals) =
            abi.decode(_priceData, (uint64, uint64, uint64, uint8));
        // 100% Confidence
        indexPrice = Price(signedIndexPrice * (10 ** (PRICE_DECIMALS - decimals)), 0);
        longPrice = Price(signedLongPrice * (10 ** (PRICE_DECIMALS - decimals)), 0);
        shortPrice = Price(signedShortPrice * (10 ** (PRICE_DECIMALS - decimals)), 0);
    }

    function convertPythParams(PythStructs.Price memory _priceData)
        public
        pure
        returns (uint256 price, uint256 confidence)
    {
        uint256 absPrice = _priceData.price.abs();
        uint256 absExponent = _priceData.expo.abs();
        price = absPrice * (10 ** (PRICE_DECIMALS - absExponent));
        confidence = _priceData.conf * (10 ** (PRICE_DECIMALS - absExponent));
    }

    function getPrice(IPriceFeed priceFeed, bytes32 _assetId) public view returns (uint256 price) {
        return priceFeed.getPrimaryPrice(_assetId).price;
    }

    function getMaxPrice(IPriceFeed priceFeed, bytes32 _assetId) public view returns (uint256 maxPrice) {
        Price memory priceData = priceFeed.getPrimaryPrice(_assetId);
        maxPrice = priceData.price + priceData.confidence;
    }

    function getMinPrice(IPriceFeed priceFeed, bytes32 _assetId) public view returns (uint256 minPrice) {
        Price memory priceData = priceFeed.getPrimaryPrice(_assetId);
        minPrice = priceData.price - priceData.confidence;
    }

    function getLatestPrice(IPriceFeed priceFeed, bytes32 _assetId, bool _maximise)
        external
        view
        returns (uint256 price)
    {
        return _maximise ? getMaxPrice(priceFeed, _assetId) : getMinPrice(priceFeed, _assetId);
    }

    function getMarketTokenPrices(IPriceFeed priceFeed, bool _maximise)
        external
        view
        returns (uint256 longPrice, uint256 shortPrice)
    {
        (Price memory longPrices, Price memory shortPrices) = getMarketTokenPrices(priceFeed);
        if (_maximise) {
            longPrice = longPrices.price + longPrices.confidence;
            shortPrice = shortPrices.price + shortPrices.confidence;
        } else {
            longPrice = longPrices.price - longPrices.confidence;
            shortPrice = shortPrices.price - shortPrices.confidence;
        }
        if (longPrice == 0 || shortPrice == 0) revert Oracle_InvalidTokenPrices();
    }

    function getMarketTokenPrices(IPriceFeed priceFeed)
        public
        view
        returns (Price memory _longPrices, Price memory _shortPrices)
    {
        _longPrices = priceFeed.getPrimaryPrice(priceFeed.longTokenId());
        _shortPrices = priceFeed.getPrimaryPrice(priceFeed.shortTokenId());
    }

    function getLastMarketTokenPrices(IPriceFeed priceFeed)
        external
        view
        returns (Price memory longPrices, Price memory shortPrices)
    {
        return priceFeed.getAssetPricesUnsafe();
    }

    // Can just use getPriceUnsafe - where do we get the confidence interval?
    function getLastMarketTokenPrices(IPriceFeed priceFeed, bool _maximise)
        external
        view
        returns (uint256 longPrice, uint256 shortPrice)
    {
        Asset memory longToken = priceFeed.getAsset(priceFeed.longTokenId());
        Asset memory shortToken = priceFeed.getAsset(priceFeed.shortTokenId());
        (uint256 longBasePrice, uint256 longConfidence) = priceFeed.getPriceUnsafe(longToken);
        (uint256 shortBasePrice, uint256 shortConfidence) = priceFeed.getPriceUnsafe(shortToken);
        if (_maximise) {
            longPrice = longBasePrice + longConfidence;
            shortPrice = shortBasePrice + shortConfidence;
        } else {
            longPrice = longBasePrice - longConfidence;
            shortPrice = shortBasePrice - shortConfidence;
        }
        if (longPrice == 0 || shortPrice == 0) revert Oracle_InvalidTokenPrices();
    }

    function validatePriceRange(Asset memory _asset, Price memory _priceData, uint256 _refPrice) external pure {
        // check the price is within the range
        uint256 maxPriceDeviation = mulDiv(_refPrice, _asset.maxPriceDeviation, MAX_PERCENTAGE);
        if (_priceData.price + _priceData.confidence > _refPrice + maxPriceDeviation) revert Oracle_PriceTooHigh();
        if (_priceData.price - _priceData.confidence < _refPrice - maxPriceDeviation) revert Oracle_PriceTooLow();
    }

    function getReferencePrice(IPriceFeed priceFeed, bytes32 _assetId) public view returns (uint256 referencePrice) {
        Asset memory asset = priceFeed.getAsset(_assetId);
        return getReferencePrice(asset);
    }

    function getLongReferencePrice(IPriceFeed priceFeed) external view returns (uint256 referencePrice) {
        return getReferencePrice(priceFeed, priceFeed.longTokenId());
    }

    function getShortReferencePrice(IPriceFeed priceFeed) external view returns (uint256 referencePrice) {
        return getReferencePrice(priceFeed, priceFeed.shortTokenId());
    }

    // Use chainlink price feed if available
    // @audit - VERY SENSITIVE - needs to ALWAYS return a valid price
    // @audit - what about limit orders?
    // Use AMM price for reference if no chainlink price
    function getReferencePrice(Asset memory _asset) public view returns (uint256 referencePrice) {
        if (_asset.secondaryStrategy == SecondaryStrategy.CHAINLINK) {
            if (_asset.chainlinkPriceFeed == address(0)) revert Oracle_InvalidChainlinkFeed();
            IChainlinkFeed chainlinkFeed = IChainlinkFeed(_asset.chainlinkPriceFeed);
            (, int256 price,, uint256 timestamp,) = chainlinkFeed.latestRoundData();
            if (price <= 0) revert Oracle_InvalidChainlinkPrice();
            if (timestamp <= block.timestamp - _asset.heartbeatDuration && block.timestamp > timestamp) {
                revert Oracle_StaleChainlinkPrice();
            }
            referencePrice = uint256(price) * (10 ** (PRICE_DECIMALS - CHAINLINK_PRICE_DECIMALS));
        } else if (_asset.secondaryStrategy == SecondaryStrategy.AMM) {
            referencePrice = getAmmPrice(_asset.pool);
        } else if (_asset.secondaryStrategy == SecondaryStrategy.NONE) {
            return 0;
        } else {
            revert Oracle_InvalidRefPrice();
        }
    }

    function getBaseUnit(IPriceFeed priceFeed, bytes32 _assetId) public view returns (uint256) {
        return priceFeed.getAsset(_assetId).baseUnit;
    }

    function getLongBaseUnit(IPriceFeed priceFeed) external view returns (uint256) {
        return getBaseUnit(priceFeed, priceFeed.longTokenId());
    }

    function getShortBaseUnit(IPriceFeed priceFeed) external view returns (uint256) {
        return getBaseUnit(priceFeed, priceFeed.shortTokenId());
    }

    function priceWasSigned(IPriceFeed priceFeed, bool _isLong) external view returns (bool) {
        // If long, get the long asset price, else short asset price
        bytes32 assetId = _isLong ? priceFeed.longTokenId() : priceFeed.shortTokenId();
        return priceFeed.getPrimaryPrice(assetId).price != 0;
    }

    /// @dev _baseUnit is the base unit of the token0
    // ONLY EVER USED FOR REFERENCE PRICE -> PRICE IS MANIPULATABLE
    function getAmmPrice(UniswapPool memory _pool) public view returns (uint256 price) {
        if (_pool.poolType == PoolType.UNISWAP_V3) {
            IUniswapV3Pool pool = IUniswapV3Pool(_pool.poolAddress);
            (uint160 sqrtPriceX96,,,,,,) = pool.slot0();
            uint256 baseUnit = 10 ** ERC20(_pool.token0).decimals();
            UD60x18 numerator = ud(uint256(sqrtPriceX96)).powu(2).mul(ud(baseUnit));
            UD60x18 denominator = ud(2).powu(192);
            price = unwrap(numerator.div(denominator));
            return price;
        } else if (_pool.poolType == PoolType.UNISWAP_V2) {
            IUniswapV2Pair pair = IUniswapV2Pair(_pool.poolAddress);
            (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
            address pairToken0 = pair.token0();

            if (_pool.token0 == pairToken0) {
                uint256 baseUnit = 10 ** ERC20(_pool.token0).decimals();
                price = mulDiv(uint256(reserve1), baseUnit, uint256(reserve0));
            } else {
                uint256 baseUnit = 10 ** ERC20(_pool.token1).decimals();
                price = mulDiv(uint256(reserve0), baseUnit, uint256(reserve1));
            }
            return price;
        } else {
            revert Oracle_InvalidPoolType();
        }
    }
}
