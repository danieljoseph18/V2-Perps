// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {IPriceFeed} from "./interfaces/IPriceFeed.sol";
import {IPyth} from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import {PythStructs} from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {Pricing} from "../libraries/Pricing.sol";
import {IChainlinkFeed} from "./interfaces/IChainlinkFeed.sol";
import {IUniswapV3Pool} from "./interfaces/IUniswapV3Pool.sol";
import {IUniswapV2Pair} from "./interfaces/IUniswapV2Pair.sol";
import {mulDiv} from "@prb/math/Common.sol";
import {ud, UD60x18, unwrap} from "@prb/math/UD60x18.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

library Oracle {
    using SignedMath for int64;
    using SignedMath for int32;

    // @gas - use smaller data types
    struct Asset {
        bool isValid;
        address chainlinkPriceFeed; // Chainlink Price Feed Address
        bytes32 priceId; // Pyth Price ID
        uint64 baseUnit; // 1 Unit of the Token e.g 1e18 for ETH
        uint32 heartbeatDuration; // Duration after which the price is considered stale
        uint256 maxPriceDeviation; // Max Price Deviation from Reference Price
        uint256 priceSpread; // Spread to Apply to Price if Alternative Asset (e.g $0.1 = 0.1e18)
        PriceProvider priceProvider;
        AssetType assetType;
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

    enum PriceProvider {
        PYTH,
        CHAINLINK,
        SECONDARY
    }

    enum AssetType {
        CRYPTO,
        FX,
        EQUITY,
        COMMODITY,
        PREDICTION
    }

    enum PoolType {
        UNISWAP_V3,
        UNISWAP_V2
    }

    struct TradingEnabled {
        bool forex;
        bool equity;
        bool commodity;
        bool prediction;
    }

    uint64 private constant MAX_PERCENTAGE = 1e18; // 100%
    uint64 private constant SCALING_FACTOR = 1e18;
    uint8 private constant PRICE_DECIMALS = 18;
    uint8 private constant CHAINLINK_PRICE_DECIMALS = 8;

    function isValidAsset(IPriceFeed priceFeed, address _token) external view returns (bool) {
        return priceFeed.getAsset(_token).isValid;
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
                revert("Oracle: Sequencer is down");
            }
        }
    }

    function validateTradingHours(IPriceFeed priceFeed, address _token, TradingEnabled memory _isEnabled)
        external
        view
    {
        Asset memory asset = priceFeed.getAsset(_token);
        if (asset.assetType == AssetType.CRYPTO) {
            return;
        } else if (asset.assetType == AssetType.FX) {
            require(_isEnabled.forex, "Oracle: Forex Trading Disabled");
        } else if (asset.assetType == AssetType.EQUITY) {
            require(_isEnabled.equity, "Oracle: Equity Trading Disabled");
        } else if (asset.assetType == AssetType.COMMODITY) {
            require(_isEnabled.commodity, "Oracle: Commodity Trading Disabled");
        } else if (asset.assetType == AssetType.PREDICTION) {
            require(_isEnabled.prediction, "Oracle: Prediction Trading Disabled");
        } else {
            revert("Oracle: Unrecognised Asset Type");
        }
    }

    function deconstructPythPrice(PythStructs.Price memory _priceData)
        external
        pure
        returns (Price memory deconstructedPrice)
    {
        (deconstructedPrice.price, deconstructedPrice.confidence) = convertPythParams(_priceData);
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

    function getPrice(IPriceFeed priceFeed, address _token, uint256 _block) public view returns (uint256 price) {
        return priceFeed.getPrice(_token, _block).price;
    }

    function getMaxPrice(IPriceFeed priceFeed, address _token, uint256 _block) public view returns (uint256 maxPrice) {
        Price memory priceData = priceFeed.getPrice(_token, _block);
        maxPrice = priceData.price + priceData.confidence;
    }

    function getMinPrice(IPriceFeed priceFeed, address _token, uint256 _block) public view returns (uint256 minPrice) {
        Price memory priceData = priceFeed.getPrice(_token, _block);
        minPrice = priceData.price - priceData.confidence;
    }

    // Get the price for the current block
    function getLatestPrice(IPriceFeed priceFeed, address _token, bool _maximise)
        external
        view
        returns (uint256 price)
    {
        return _maximise ? getMaxPrice(priceFeed, _token, block.number) : getMinPrice(priceFeed, _token, block.number);
    }

    function getMarketTokenPrices(IPriceFeed priceFeed, uint256 _blockNumber, bool _maximise)
        external
        view
        returns (uint256 longPrice, uint256 shortPrice)
    {
        (Price memory longPrices, Price memory shortPrices) = getMarketTokenPrices(priceFeed, _blockNumber);
        if (_maximise) {
            longPrice = longPrices.price + longPrices.confidence;
            shortPrice = shortPrices.price + shortPrices.confidence;
        } else {
            longPrice = longPrices.price - longPrices.confidence;
            shortPrice = shortPrices.price - shortPrices.confidence;
        }
        require(longPrice > 0 && shortPrice > 0, "Oracle: invalid token prices");
    }

    function getMarketTokenPrices(IPriceFeed priceFeed, uint256 _blockNumber)
        public
        view
        returns (Price memory _longPrices, Price memory _shortPrices)
    {
        _longPrices = priceFeed.getPrice(priceFeed.longToken(), _blockNumber);
        _shortPrices = priceFeed.getPrice(priceFeed.shortToken(), _blockNumber);
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
        Asset memory longToken = priceFeed.getAsset(priceFeed.longToken());
        Asset memory shortToken = priceFeed.getAsset(priceFeed.shortToken());
        (uint256 longBasePrice, uint256 longConfidence) = priceFeed.getPriceUnsafe(longToken);
        (uint256 shortBasePrice, uint256 shortConfidence) = priceFeed.getPriceUnsafe(shortToken);
        if (_maximise) {
            longPrice = longBasePrice + longConfidence;
            shortPrice = shortBasePrice + shortConfidence;
        } else {
            longPrice = longBasePrice - longConfidence;
            shortPrice = shortBasePrice - shortConfidence;
        }
        require(longPrice > 0 && shortPrice > 0, "Oracle: invalid token prices");
    }

    function validatePriceRange(Asset memory _asset, Price memory _priceData, uint256 _refPrice) external pure {
        // check the price is within the range
        uint256 maxPriceDeviation = mulDiv(_refPrice, _asset.maxPriceDeviation, MAX_PERCENTAGE);
        require(_priceData.price + _priceData.confidence <= _refPrice + maxPriceDeviation, "Oracle: Price too high");
        require(_priceData.price - _priceData.confidence >= _refPrice - maxPriceDeviation, "Oracle: Price too low");
    }

    function getReferencePrice(IPriceFeed priceFeed, address _token) public view returns (uint256 referencePrice) {
        Asset memory asset = priceFeed.getAsset(_token);
        return getReferencePrice(priceFeed, asset);
    }

    function getLongReferencePrice(IPriceFeed priceFeed) external view returns (uint256 referencePrice) {
        return getReferencePrice(priceFeed, priceFeed.longToken());
    }

    function getShortReferencePrice(IPriceFeed priceFeed) external view returns (uint256 referencePrice) {
        return getReferencePrice(priceFeed, priceFeed.shortToken());
    }

    // Use chainlink price feed if available
    // @audit - VERY SENSITIVE - needs to ALWAYS return a valid price
    // @audit - what about limit orders?
    // Use AMM price for reference if no chainlink price
    function getReferencePrice(IPriceFeed priceFeed, Asset memory _asset)
        public
        view
        returns (uint256 referencePrice)
    {
        if (_asset.chainlinkPriceFeed != address(0)) {
            IChainlinkFeed chainlinkFeed = IChainlinkFeed(_asset.chainlinkPriceFeed);
            (, int256 _price,, uint256 timestamp,) = chainlinkFeed.latestRoundData();
            require(_price > 0, "Oracle: Invalid Chainlink Price");
            require(timestamp > block.timestamp - _asset.heartbeatDuration, "Oracle: Stale Chainlink Price");
            referencePrice = mulDiv(uint256(_price), _asset.baseUnit, 10 ** CHAINLINK_PRICE_DECIMALS);
        } else if (_asset.pool.poolAddress != address(0)) {
            referencePrice = getAmmPrice(_asset.pool);
        } else if (_asset.priceProvider == PriceProvider.PYTH) {
            (referencePrice,) = priceFeed.getPriceUnsafe(_asset);
        } else {
            revert("Oracle: Invalid Ref Price");
        }
    }

    function getBaseUnit(IPriceFeed priceFeed, address _token) public view returns (uint256) {
        return priceFeed.getAsset(_token).baseUnit;
    }

    function getLongBaseUnit(IPriceFeed priceFeed) external view returns (uint256) {
        return getBaseUnit(priceFeed, priceFeed.longToken());
    }

    function getShortBaseUnit(IPriceFeed priceFeed) external view returns (uint256) {
        return getBaseUnit(priceFeed, priceFeed.shortToken());
    }

    function priceWasSigned(IPriceFeed priceFeed, address _token, uint256 _block) external view returns (bool) {
        return priceFeed.getPrice(_token, _block).price != 0;
    }

    // @audit - where is this used? should we max or min the price?
    function getNetPnl(IPriceFeed priceFeed, IMarket market, address _indexToken, uint256 _blockNumber, bool _maximise)
        external
        view
        returns (int256 netPnl)
    {
        uint256 indexPrice;
        if (_maximise) {
            indexPrice = getMaxPrice(priceFeed, _indexToken, _blockNumber);
        } else {
            indexPrice = getMinPrice(priceFeed, _indexToken, _blockNumber);
        }
        require(indexPrice != 0, "Oracle: Invalid Index Price");
        uint256 indexBaseUnit = getBaseUnit(priceFeed, _indexToken);
        netPnl = Pricing.getNetPnl(market, _indexToken, indexPrice, indexBaseUnit);
    }

    /// @dev _baseUnit is the base unit of the token0
    function getAmmPrice(UniswapPool memory _pool) public view returns (uint256 price) {
        if (_pool.poolType == PoolType.UNISWAP_V3) {
            IUniswapV3Pool pool = IUniswapV3Pool(_pool.poolAddress);
            (uint160 sqrtPriceX96,,,,,,) = pool.slot0();
            // Convert the sqrtPriceX96 to price with 18 decimals
            // price = sqrtPriceX96^2 / 2^192 to convert to token0 per token1 price
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
            revert("Oracle: Invalid Pool Type");
        }
    }
}
