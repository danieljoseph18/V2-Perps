// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {IPriceFeed} from "./interfaces/IPriceFeed.sol";
import {IPyth} from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import {PythStructs} from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {UD60x18, unwrap, ud, powu} from "@prb/math/UD60x18.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {Pricing} from "../libraries/Pricing.sol";
import {IChainlinkFeed} from "./interfaces/IChainlinkFeed.sol";
import {mulDiv} from "@prb/math/Common.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

library Oracle {
    using SignedMath for int64;
    using SignedMath for int32;
    using SafeCast for int256;

    struct Asset {
        bool isValid;
        address chainlinkPriceFeed;
        bytes32 priceId;
        uint256 baseUnit;
        uint256 heartbeatDuration;
        uint256 maxPriceDeviation; // %
        PriceProvider priceProvider;
        AssetType assetType;
    }

    struct Price {
        uint256 max;
        uint256 min;
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

    uint256 private constant MAX_PERCENTAGE = 1e18; // 100%
    uint256 private constant PRICE_DECIMALS = 18;
    uint256 private constant CHAINLINK_PRICE_DECIMALS = 8;

    function isValidAsset(IPriceFeed _priceFeed, address _token) external view returns (bool) {
        return _priceFeed.getAsset(_token).isValid;
    }

    function isSequencerUp(IPriceFeed _priceFeed) external view {
        address sequencerUptimeFeed = _priceFeed.sequencerUptimeFeed();
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

    /**
     * Market Hours:
     * 1. Crypto: 24/7
     * 2. US Equities 9:30 AM - 4:00 PM ET
     * 3. FX Sunday 5:00 PM - Friday 5:00 PM ET
     * 4. Commodities Sunday 5:00 PM - Friday 5:00 PM ET
     * 5. Rates Weekdays 8AM - 5PM ET
     *
     * For 2 and 5
     * Holidays are: New Year's Day, Martin Luther King Jr. Day, Washington Bday,
     * Good Friday, Memorial Day, Juneteenth National Independence Day, Independence Day, Labor Day, Thanksgiving, Christmas
     *
     * For Commodities, follows CME holidays
     */
    function isTradingEnabled(Asset memory _asset) external view returns (bool) {
        // get the asset type
        // get the opening hours for that asset type
        // check if the current time is within the opening hours
    }

    function deconstructPythPrice(PythStructs.Price memory _priceData)
        public
        pure
        returns (Price memory deconstructedPrice)
    {
        (uint256 price, uint256 confidence) = convertPythParams(_priceData);
        deconstructedPrice.max = price + confidence;
        deconstructedPrice.min = price - confidence;
    }

    function convertPythParams(PythStructs.Price memory _priceData)
        public
        view
        returns (uint256 price, uint256 confidence)
    {
        uint256 absPrice = _priceData.price.abs();
        uint256 absExponent = _priceData.expo.abs();
        price = absPrice * (10 ** (PRICE_DECIMALS - absExponent));
        confidence = _priceData.conf * (10 ** (PRICE_DECIMALS - absExponent));
    }

    function getMaxPrice(IPriceFeed _priceFeed, address _token, uint256 _block)
        public
        view
        returns (uint256 maxPrice)
    {
        maxPrice = _priceFeed.getPrice(_block, _token).max;
    }

    function getMinPrice(IPriceFeed _priceFeed, address _token, uint256 _block)
        public
        view
        returns (uint256 minPrice)
    {
        minPrice = _priceFeed.getPrice(_block, _token).min;
    }

    function getMarketTokenPrices(IPriceFeed _priceFeed, uint256 _blockNumber, bool _maximise)
        public
        view
        returns (uint256 longPrice, uint256 shortPrice)
    {
        address longToken = _priceFeed.longToken();
        address shortToken = _priceFeed.shortToken();
        if (_maximise) {
            longPrice = getMaxPrice(_priceFeed, longToken, _blockNumber);
            shortPrice = getMaxPrice(_priceFeed, shortToken, _blockNumber);
        } else {
            longPrice = getMinPrice(_priceFeed, longToken, _blockNumber);
            shortPrice = getMinPrice(_priceFeed, shortToken, _blockNumber);
        }
        require(longPrice > 0 && shortPrice > 0, "Oracle: invalid token prices");
    }

    function getLastMarketTokenPrices(IPriceFeed _priceFeed, bool _maximise)
        external
        view
        returns (uint256 longPrice, uint256 shortPrice)
    {
        uint256 lastUpdateBlock = _priceFeed.lastUpdateBlock();
        if (_maximise) {
            longPrice = getMaxPrice(_priceFeed, _priceFeed.longToken(), lastUpdateBlock);
            shortPrice = getMaxPrice(_priceFeed, _priceFeed.shortToken(), lastUpdateBlock);
        } else {
            longPrice = getMinPrice(_priceFeed, _priceFeed.longToken(), lastUpdateBlock);
            shortPrice = getMinPrice(_priceFeed, _priceFeed.shortToken(), lastUpdateBlock);
        }
    }

    function validatePriceRange(Asset memory _asset, Price memory _price, uint256 _refPrice) external view {
        // check the price is within the range
        uint256 maxPriceDeviation = mulDiv(_refPrice, _asset.maxPriceDeviation, MAX_PERCENTAGE);
        require(_price.max <= _refPrice + maxPriceDeviation, "Oracle: Price too high");
        require(_price.min >= _refPrice - maxPriceDeviation, "Oracle: Price too low");
    }

    // Use chainlink price feed if available
    function getReferencePrice(IPriceFeed _priceFeed, Asset memory _asset)
        public
        view
        returns (uint256 referencePrice)
    {
        // get chainlink feed address
        // if address = 0 -> return false, 0
        if (_asset.chainlinkPriceFeed == address(0)) {
            if (_asset.priceProvider == PriceProvider.PYTH) {
                return _priceFeed.getPriceUnsafe(_asset);
            }
            return 0;
        }
        // get interface
        IChainlinkFeed chainlinkFeed = IChainlinkFeed(_asset.chainlinkPriceFeed);
        // call latest round data
        (
            /* uint80 roundID */
            ,
            int256 _price,
            /* uint256 startedAt */
            ,
            uint256 timestamp,
            /* uint80 answeredInRound */
        ) = chainlinkFeed.latestRoundData();
        // validate price -> shouldn't be <= 0, shouldn't be stale
        require(_price > 0, "Oracle: Invalid Chainlink Price");
        require(timestamp > block.timestamp - _asset.heartbeatDuration, "Oracle: Stale Chainlink Price");
        // adjust and return
        referencePrice = mulDiv(_price.toUint256(), _asset.baseUnit, 10 ** CHAINLINK_PRICE_DECIMALS);
    }

    function getBaseUnit(IPriceFeed _priceFeed, address _token) public view returns (uint256) {
        return _priceFeed.getAsset(_token).baseUnit;
    }

    function getLongBaseUnit(IPriceFeed _priceFeed) public view returns (uint256) {
        return getBaseUnit(_priceFeed, _priceFeed.longToken());
    }

    function getShortBaseUnit(IPriceFeed _priceFeed) public view returns (uint256) {
        return getBaseUnit(_priceFeed, _priceFeed.shortToken());
    }

    // @audit - where is this used? should we max or min the price?
    function getNetPnl(IPriceFeed _priceFeed, IMarket _market, uint256 _blockNumber, bool _maximise)
        public
        view
        returns (int256 netPnl)
    {
        address indexToken = _market.indexToken();
        uint256 indexPrice;
        if (_maximise) {
            indexPrice = getMaxPrice(_priceFeed, indexToken, _blockNumber);
        } else {
            indexPrice = getMinPrice(_priceFeed, indexToken, _blockNumber);
        }
        require(indexPrice != 0, "Oracle: Invalid Index Price");
        uint256 indexBaseUnit = getBaseUnit(_priceFeed, indexToken);
        netPnl = Pricing.getNetPnl(_market, indexPrice, indexBaseUnit);
    }
}
