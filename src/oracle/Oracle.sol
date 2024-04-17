// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IPriceFeed} from "./interfaces/IPriceFeed.sol";
import {IChainlinkFeed} from "./interfaces/IChainlinkFeed.sol";
import {AggregatorV2V3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV2V3Interface.sol";
import {IUniswapV3Pool} from "./interfaces/IUniswapV3Pool.sol";
import {IUniswapV2Pair} from "./interfaces/IUniswapV2Pair.sol";
import {IPyth} from "@pyth/contracts/IPyth.sol";
import {PythStructs} from "@pyth/contracts/PythStructs.sol";
import {ERC20, IERC20, IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {MathUtils} from "../libraries/MathUtils.sol";
import {mulDiv} from "@prb/math/Common.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ud, UD60x18, unwrap} from "@prb/math/UD60x18.sol";

library Oracle {
    using SignedMath for int256;
    using SignedMath for int64;
    using MathUtils for uint256;
    using SafeCast for uint256;

    error Oracle_SequencerDown();
    error Oracle_PriceNotSet();
    error Oracle_InvalidAmmDecimals();
    error Oracle_InvalidPoolType();
    error Oracle_InvalidReferenceQuery();
    error Oracle_InvalidPriceRetrieval();

    struct UniswapPool {
        address token0;
        address token1;
        address poolAddress;
        PoolType poolType;
    }

    struct Prices {
        uint256 min;
        uint256 med;
        uint256 max;
    }

    enum PoolType {
        V3,
        V2
    }

    string private constant LONG_TICKER = "ETH";
    string private constant SHORT_TICKER = "USDC";
    uint8 private constant PRICE_DECIMALS = 30;
    uint8 private constant CHAINLINK_DECIMALS = 8;
    uint16 private constant MAX_VARIANCE = 10_000;
    uint64 private constant MAX_PRICE_DEVIATION = 0.1e18;
    uint64 private constant OVERESTIMATION_FACTOR = 0.1e18;
    uint64 private constant LINK_BASE_UNIT = 1e18;
    uint64 private constant PREMIUM_FEE = 0.2e18; // 20%

    /**
     * ====================================== Helper Functions ======================================
     */
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

    function estimateRequestCost(IPriceFeed priceFeed) external view returns (uint256 cost) {
        // Get the current gas price
        uint256 gasPrice = tx.gasprice;

        // Calculate the overestimated gas price (overestimated by 10%)
        uint256 overestimatedGasPrice = gasPrice + gasPrice.percentage(OVERESTIMATION_FACTOR);

        // Calculate the total estimated gas cost for the functions call
        uint256 totalEstimatedGasCost = overestimatedGasPrice * (priceFeed.gasOverhead() + priceFeed.callbackGasLimit());
        uint256 premiumFee = totalEstimatedGasCost.percentage(PREMIUM_FEE);

        // Calculate the total cost -> gas cost + premium fee
        cost = totalEstimatedGasCost + premiumFee;
    }

    function calculateSettlementFee(uint256 _ethAmount, uint256 _settlementFeePercentage)
        external
        pure
        returns (uint256)
    {
        return _ethAmount.percentage(_settlementFeePercentage);
    }

    /**
     * enum FeedType {
     *     CHAINLINK,
     *     UNI_V3,
     *     UNI_V2_T0, // Uniswap V2 token0
     *     UNI_V2_T1, // Uniswap V2 token1
     *     PYTH
     * }
     */
    function validateFeedType(IPriceFeed.FeedType _feedType) external pure {
        if (
            _feedType != IPriceFeed.FeedType.CHAINLINK && _feedType != IPriceFeed.FeedType.UNI_V3
                && _feedType != IPriceFeed.FeedType.UNI_V2_T0 && _feedType != IPriceFeed.FeedType.UNI_V2_T1
                && _feedType != IPriceFeed.FeedType.PYTH
        ) {
            revert Oracle_InvalidPoolType();
        }
    }

    /**
     * ====================================== Price Retrieval ======================================
     */
    function getPrice(IPriceFeed priceFeed, string calldata _ticker, uint48 _blockTimestamp)
        external
        view
        returns (uint256 medPrice)
    {
        IPriceFeed.Price memory price = priceFeed.getPrices(_ticker, _blockTimestamp);
        medPrice = price.med * (10 ** (PRICE_DECIMALS - price.precision));
    }

    function getMaxPrice(IPriceFeed priceFeed, string memory _ticker, uint48 _blockTimestamp)
        public
        view
        returns (uint256 maxPrice)
    {
        IPriceFeed.Price memory price = priceFeed.getPrices(_ticker, _blockTimestamp);
        uint256 medPrice = price.med * (10 ** (PRICE_DECIMALS - price.precision));
        maxPrice = medPrice + mulDiv(medPrice, price.variance, MAX_VARIANCE);
    }

    function getMinPrice(IPriceFeed priceFeed, string memory _ticker, uint48 _blockTimestamp)
        public
        view
        returns (uint256 minPrice)
    {
        IPriceFeed.Price memory price = priceFeed.getPrices(_ticker, _blockTimestamp);
        uint256 medPrice = price.med * (10 ** (PRICE_DECIMALS - price.precision));
        minPrice = medPrice - mulDiv(medPrice, price.variance, MAX_VARIANCE);
    }

    function getVaultPrices(IPriceFeed priceFeed, uint48 _blockTimestamp)
        public
        view
        returns (Prices memory longPrices, Prices memory shortPrices)
    {
        longPrices = getVaultPricesForSide(priceFeed, _blockTimestamp, true);
        shortPrices = getVaultPricesForSide(priceFeed, _blockTimestamp, false);
    }

    function getVaultPricesForSide(IPriceFeed priceFeed, uint48 _blockTimestamp, bool _isLong)
        public
        view
        returns (Prices memory prices)
    {
        IPriceFeed.Price memory signedPrice = priceFeed.getPrices(_isLong ? LONG_TICKER : SHORT_TICKER, _blockTimestamp);
        prices.med = signedPrice.med * (10 ** (PRICE_DECIMALS - signedPrice.precision));
        prices.min = prices.med - mulDiv(prices.med, signedPrice.variance, MAX_VARIANCE);
        prices.max = prices.med + mulDiv(prices.med, signedPrice.variance, MAX_VARIANCE);
    }

    function getMaxVaultPrices(IPriceFeed priceFeed, uint48 _blockTimestamp)
        external
        view
        returns (uint256 longPrice, uint256 shortPrice)
    {
        longPrice = getMaxPrice(priceFeed, LONG_TICKER, _blockTimestamp);
        shortPrice = getMaxPrice(priceFeed, SHORT_TICKER, _blockTimestamp);
    }

    function getMinVaultPrices(IPriceFeed priceFeed, uint48 _blockTimestamp)
        external
        view
        returns (uint256 longPrice, uint256 shortPrice)
    {
        longPrice = getMinPrice(priceFeed, LONG_TICKER, _blockTimestamp);
        shortPrice = getMinPrice(priceFeed, SHORT_TICKER, _blockTimestamp);
    }

    /**
     * ====================================== Pnl ======================================
     */
    function getCumulativePnl(IPriceFeed priceFeed, address _market, uint48 _blockTimestamp)
        external
        view
        returns (int256 cumulativePnl)
    {
        IPriceFeed.Pnl memory pnl = priceFeed.getCumulativePnl(_market, _blockTimestamp);
        uint256 multiplier = 10 ** (PRICE_DECIMALS - pnl.precision);
        cumulativePnl = pnl.cumulativePnl * multiplier.toInt256();
    }

    /**
     * ====================================== Auxillary ======================================
     */
    function getBaseUnit(IPriceFeed priceFeed, string calldata _ticker) external view returns (uint256 baseUnit) {
        baseUnit = 10 ** priceFeed.getTokenData(_ticker).tokenDecimals;
    }

    function validatePriceRange(IPriceFeed priceFeed, string calldata _ticker, uint256 _signedPrice) external view {
        uint256 referencePrice = getReferencePrice(priceFeed, _ticker);
        if (_signedPrice.delta(referencePrice) > referencePrice.percentage(MAX_PRICE_DEVIATION)) {
            revert Oracle_InvalidPriceRetrieval();
        }
    }

    function validateMarketTokenPriceRanges(IPriceFeed priceFeed, uint256 _longPrice, uint256 _shortPrice)
        external
        view
    {
        uint256 longReferencePrice = getReferencePrice(priceFeed, LONG_TICKER);
        uint256 shortReferencePrice = getReferencePrice(priceFeed, SHORT_TICKER);
        if (_longPrice.delta(longReferencePrice) > longReferencePrice.percentage(MAX_PRICE_DEVIATION)) {
            revert Oracle_InvalidPriceRetrieval();
        }
        if (_shortPrice.delta(shortReferencePrice) > shortReferencePrice.percentage(MAX_PRICE_DEVIATION)) {
            revert Oracle_InvalidPriceRetrieval();
        }
    }

    /**
     * ====================================== Reference Prices ======================================
     */

    /* ONLY EVER USED FOR REFERENCE PRICES: PRICES RETURNED MAY BE HIGH-LATENCY, OR MANIPULATABLE.  */

    /**
     * In order of most common to least common reference feeds to save on gas:
     * - Chainlink
     * - Pyth
     * - Uniswap V3
     * - Uniswap V2
     */
    function getReferencePrice(IPriceFeed priceFeed, string memory _ticker) public view returns (uint256 price) {
        IPriceFeed.TokenData memory tokenData = priceFeed.getTokenData(_ticker);
        if (tokenData.feedType == IPriceFeed.FeedType.CHAINLINK) {
            price = _getChainlinkPrice(tokenData);
        } else if (tokenData.feedType == IPriceFeed.FeedType.PYTH) {
            price = _getPythPrice(priceFeed, tokenData, _ticker);
        } else if (tokenData.feedType == IPriceFeed.FeedType.UNI_V3) {
            price = _getUniswapV3Price(tokenData);
        } else if (
            tokenData.feedType == IPriceFeed.FeedType.UNI_V2_T0 || tokenData.feedType == IPriceFeed.FeedType.UNI_V2_T1
        ) {
            price = _getUniswapV2Price(tokenData);
        } else {
            revert Oracle_InvalidReferenceQuery();
        }
        if (price == 0) revert Oracle_InvalidReferenceQuery();
    }

    // @audit - implement a function to check the uniswap v3 pool is valid from the factory contract
    // need to implement this to check the pool creator isn't providing a spoofed pool
    // same for chainlink feeds and potentially pyth feeds

    // @audit - needs 30 dp
    function _getUniswapV3Price(IPriceFeed.TokenData memory _tokenData) private view returns (uint256 price) {
        if (_tokenData.feedType != IPriceFeed.FeedType.UNI_V3) revert Oracle_InvalidReferenceQuery();
        IUniswapV3Pool pool = IUniswapV3Pool(_tokenData.secondaryFeed);
        (uint160 sqrtPriceX96,,,,,,) = pool.slot0();
        address token0 = pool.token0();
        (bool success, uint256 token0Decimals) = _tryGetAssetDecimals(IERC20(token0));
        if (!success) revert Oracle_InvalidAmmDecimals();
        uint256 baseUnit = 10 ** token0Decimals;
        UD60x18 numerator = ud(uint256(sqrtPriceX96)).powu(2).mul(ud(baseUnit));
        UD60x18 denominator = ud(2).powu(192);
        price = unwrap(numerator.div(denominator));
    }

    // @audit - needs 30 dp
    function _getUniswapV2Price(IPriceFeed.TokenData memory _tokenData) private view returns (uint256 price) {
        IUniswapV2Pair pair = IUniswapV2Pair(_tokenData.secondaryFeed);
        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        (bool success0, uint256 token0Decimals) = _tryGetAssetDecimals(IERC20(pair.token0()));
        (bool success1, uint256 token1Decimals) = _tryGetAssetDecimals(IERC20(pair.token1()));
        if (!success0 || !success1) revert Oracle_InvalidAmmDecimals();
        if (_tokenData.feedType == IPriceFeed.FeedType.UNI_V2_T0) {
            price = mulDiv(uint256(reserve1), 10 ** token0Decimals, uint256(reserve0));
        } else if (_tokenData.feedType == IPriceFeed.FeedType.UNI_V2_T1) {
            price = mulDiv(uint256(reserve0), 10 ** token1Decimals, uint256(reserve1));
        } else {
            revert Oracle_InvalidReferenceQuery();
        }
    }

    function _getChainlinkPrice(IPriceFeed.TokenData memory _tokenData) private view returns (uint256 price) {
        if (_tokenData.feedType != IPriceFeed.FeedType.CHAINLINK) revert Oracle_InvalidReferenceQuery();
        // Get the price feed address from the ticker
        AggregatorV2V3Interface chainlinkFeed = AggregatorV2V3Interface(_tokenData.secondaryFeed);
        // Query the feed for the price
        int256 signedPrice = chainlinkFeed.latestAnswer();
        // Convert the price from int256 to uint256 and expand decimals to 30 d.p
        price = signedPrice.abs() * (10 ** (PRICE_DECIMALS - CHAINLINK_DECIMALS));
    }

    // Need the Pyth address and the bytes32 id for the ticker
    // @audit - can exponent or price be negative?
    function _getPythPrice(IPriceFeed priceFeed, IPriceFeed.TokenData memory _tokenData, string memory _ticker)
        private
        view
        returns (uint256 price)
    {
        if (_tokenData.feedType != IPriceFeed.FeedType.PYTH) revert Oracle_InvalidReferenceQuery();
        // Query the Pyth feed for the price
        IPyth pythFeed = IPyth(_tokenData.secondaryFeed);
        PythStructs.Price memory pythData = pythFeed.getEmaPriceUnsafe(priceFeed.pythIds(_ticker));
        // Expand the price to 30 d.p
        uint256 exponent = PRICE_DECIMALS - uint32(pythData.expo);
        price = pythData.price.abs() * (10 ** exponent);
    }

    function _tryGetAssetDecimals(IERC20 _asset) private view returns (bool, uint256) {
        (bool success, bytes memory encodedDecimals) =
            address(_asset).staticcall(abi.encodeCall(IERC20Metadata.decimals, ()));
        if (success && encodedDecimals.length >= 32) {
            uint256 returnedDecimals = abi.decode(encodedDecimals, (uint256));
            if (returnedDecimals <= type(uint8).max) {
                return (true, uint8(returnedDecimals));
            }
        }
        return (false, 0);
    }
}
