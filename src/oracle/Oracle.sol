// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IPriceFeed} from "./interfaces/IPriceFeed.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {IChainlinkFeed} from "./interfaces/IChainlinkFeed.sol";
import {AggregatorV2V3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV2V3Interface.sol";
import {IUniswapV3Pool} from "./interfaces/IUniswapV3Pool.sol";
import {IUniswapV2Pair} from "./interfaces/IUniswapV2Pair.sol";
import {IUniswapV3Factory} from "./interfaces/IUniswapV3Factory.sol";
import {IUniswapV2Factory} from "./interfaces/IUniswapV2Factory.sol";
import {FeedRegistryInterface} from "@chainlink/contracts/src/v0.8/interfaces/FeedRegistryInterface.sol";
import {MerkleProofLib} from "../libraries/MerkleProofLib.sol";
import {IPyth} from "@pyth/contracts/IPyth.sol";
import {PythStructs} from "@pyth/contracts/PythStructs.sol";
import {IERC20} from "../tokens/interfaces/IERC20.sol";
import {IERC20Metadata} from "../tokens/interfaces/IERC20Metadata.sol";
import {MathUtils} from "../libraries/MathUtils.sol";
import {Casting} from "../libraries/Casting.sol";
import {Units} from "../libraries/Units.sol";
import {LibString} from "../libraries/LibString.sol";
import {ud, UD60x18, unwrap} from "@prb/math/UD60x18.sol";
import {MarketId, MarketIdLibrary} from "../types/MarketId.sol";

library Oracle {
    using MathUtils for uint256;
    using MathUtils for int256;
    using Units for uint256;
    using Casting for uint256;
    using Casting for int256;
    using Casting for int32;
    using Casting for int64;
    using LibString for uint256;

    error Oracle_SequencerDown();
    error Oracle_InvalidAmmDecimals();
    error Oracle_InvalidPoolType();
    error Oracle_InvalidReferenceQuery();
    error Oracle_InvalidPriceRetrieval();
    error Oracle_InvalidSecondaryStrategy();
    error Oracle_RequestExpired();

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
    uint8 private constant MAX_STRATEGY = 5;
    uint16 private constant MAX_VARIANCE = 10_000;
    uint64 private constant MAX_PRICE_DEVIATION = 0.1e18;
    uint64 private constant OVERESTIMATION_FACTOR = 0.1e18;
    uint64 private constant PREMIUM_FEE = 0.2e18; // 20%

    /**
     * =========================================== Validation Functions ===========================================
     */
    function isSequencerUp(IPriceFeed priceFeed) internal view {
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

    function isValidChainlinkFeed(FeedRegistryInterface feedRegistry, address _feedAddress) internal view {
        if (!feedRegistry.isFeedEnabled(_feedAddress)) revert Oracle_InvalidSecondaryStrategy();
    }

    function isValidUniswapV3Pool(
        IUniswapV3Factory factory,
        address _poolAddress,
        IPriceFeed.FeedType _feedType,
        bytes32[] calldata _merkleProof,
        bytes32 _merkleRoot
    ) internal view {
        IUniswapV3Pool pool = IUniswapV3Pool(_poolAddress);

        address token0 = pool.token0();
        address token1 = pool.token1();

        address expectedPoolAddress = factory.getPool(token0, token1, pool.fee());

        if (expectedPoolAddress != _poolAddress) revert Oracle_InvalidSecondaryStrategy();

        // The pair must contain a stablecoin within the Merkle Tree whitelist
        if (_feedType == IPriceFeed.FeedType.UNI_V30) {
            bytes32 leaf = keccak256(abi.encodePacked(token1));
            if (!MerkleProofLib.verify(_merkleProof, _merkleRoot, leaf)) {
                revert Oracle_InvalidSecondaryStrategy();
            }
        } else {
            bytes32 leaf = keccak256(abi.encodePacked(token0));
            if (!MerkleProofLib.verify(_merkleProof, _merkleRoot, leaf)) {
                revert Oracle_InvalidSecondaryStrategy();
            }
        }
    }

    function isValidUniswapV2Pool(
        IUniswapV2Factory factory,
        address _poolAddress,
        IPriceFeed.FeedType _feedType,
        bytes32[] calldata _merkleProof,
        bytes32 _merkleRoot
    ) internal view {
        IUniswapV2Pair pair = IUniswapV2Pair(_poolAddress);

        address expectedPoolAddress = factory.getPair(pair.token0(), pair.token1());

        if (expectedPoolAddress != _poolAddress) revert Oracle_InvalidSecondaryStrategy();

        // The pair must contain a stablecoin within the Merkle Tree whitelist
        if (_feedType == IPriceFeed.FeedType.UNI_V20) {
            bytes32 leaf = keccak256(abi.encodePacked(pair.token1()));
            if (!MerkleProofLib.verify(_merkleProof, _merkleRoot, leaf)) {
                revert Oracle_InvalidSecondaryStrategy();
            }
        } else {
            bytes32 leaf = keccak256(abi.encodePacked(pair.token0()));
            if (!MerkleProofLib.verify(_merkleProof, _merkleRoot, leaf)) {
                revert Oracle_InvalidSecondaryStrategy();
            }
        }
    }

    function isValidPythFeed(bytes32[] calldata _merkleProof, bytes32 _merkleRoot, bytes32 _priceId) internal pure {
        // Check if the Pyth feed is stored within the Merkle Tree as a whitelisted feed.
        // No need to check for bytes32(0) as this case will revert with this check.
        if (!MerkleProofLib.verify(_merkleProof, _merkleRoot, _priceId)) {
            revert Oracle_InvalidSecondaryStrategy();
        }
    }

    function validateFeedType(IPriceFeed.FeedType _feedType) internal pure {
        if (uint8(_feedType) > MAX_STRATEGY) revert Oracle_InvalidPoolType();
    }

    /**
     * =========================================== Helper Functions ===========================================
     */
    function estimateRequestCost(IPriceFeed priceFeed) internal view returns (uint256 cost) {
        uint256 gasPrice = tx.gasprice;

        uint256 overestimatedGasPrice = gasPrice + gasPrice.percentage(OVERESTIMATION_FACTOR);

        uint256 totalEstimatedGasCost = overestimatedGasPrice * (priceFeed.gasOverhead() + priceFeed.callbackGasLimit());

        uint256 premiumFee = totalEstimatedGasCost.percentage(PREMIUM_FEE);

        cost = totalEstimatedGasCost + premiumFee;
    }

    function calculateSettlementFee(uint256 _ethAmount, uint256 _settlementFeePercentage)
        internal
        pure
        returns (uint256)
    {
        return _ethAmount.percentage(_settlementFeePercentage);
    }

    /// @dev - Prepend the timestamp to the arguments before sending to the DON
    function constructPriceArguments(string memory _ticker) internal view returns (string[] memory args) {
        if (bytes(_ticker).length == 0) {
            // Only prices for Long and Short Tokens
            args = new string[](3);
            args[0] = block.timestamp.toString();
            args[1] = LONG_TICKER;
            args[2] = SHORT_TICKER;
        } else {
            // Prices for index token, long token, and short token
            args = new string[](4);
            args[0] = block.timestamp.toString();
            args[1] = _ticker;
            args[2] = LONG_TICKER;
            args[3] = SHORT_TICKER;
        }
    }

    function constructMultiPriceArgs(MarketId _id, IMarket market) internal view returns (string[] memory args) {
        string memory timestamp = block.timestamp.toString();

        string[] memory tickers = market.getTickers(_id);

        uint256 len = tickers.length;

        args = new string[](len + 3);

        args[0] = timestamp;
        args[1] = LONG_TICKER;
        args[2] = SHORT_TICKER;

        for (uint8 i = 0; i < len;) {
            args[i + 3] = tickers[i];

            unchecked {
                ++i;
            }
        }
    }

    /// @dev - Prepend the timestamp to the arguments before sending to the DON
    /// Use of loop not desirable, but the maximum possible loops is ~ 102
    function constructPnlArguments(MarketId _id, IMarket market) internal view returns (string[] memory args) {
        string[] memory tickers = market.getTickers(_id);

        string memory timestamp = block.timestamp.toString();

        uint256 len = tickers.length;

        args = new string[](tickers.length + 1);

        args[0] = timestamp;

        for (uint8 i = 0; i < len;) {
            args[i + 1] = tickers[i];

            unchecked {
                ++i;
            }
        }
    }

    /**
     * =========================================== Price Retrieval ===========================================
     */
    function getPrice(IPriceFeed priceFeed, string memory _ticker, uint48 _blockTimestamp)
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

        maxPrice = medPrice + medPrice.mulDiv(price.variance, MAX_VARIANCE);
    }

    function getMinPrice(IPriceFeed priceFeed, string memory _ticker, uint48 _blockTimestamp)
        public
        view
        returns (uint256 minPrice)
    {
        IPriceFeed.Price memory price = priceFeed.getPrices(_ticker, _blockTimestamp);

        uint256 medPrice = price.med * (10 ** (PRICE_DECIMALS - price.precision));

        minPrice = medPrice - medPrice.mulDiv(price.variance, MAX_VARIANCE);
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

        prices.min = prices.med - prices.med.mulDiv(signedPrice.variance, MAX_VARIANCE);

        prices.max = prices.med + prices.med.mulDiv(signedPrice.variance, MAX_VARIANCE);
    }

    function getMaxVaultPrices(IPriceFeed priceFeed, uint48 _blockTimestamp)
        internal
        view
        returns (uint256 longPrice, uint256 shortPrice)
    {
        longPrice = getMaxPrice(priceFeed, LONG_TICKER, _blockTimestamp);
        shortPrice = getMaxPrice(priceFeed, SHORT_TICKER, _blockTimestamp);
    }

    function getMinVaultPrices(IPriceFeed priceFeed, uint48 _blockTimestamp)
        internal
        view
        returns (uint256 longPrice, uint256 shortPrice)
    {
        longPrice = getMinPrice(priceFeed, LONG_TICKER, _blockTimestamp);
        shortPrice = getMinPrice(priceFeed, SHORT_TICKER, _blockTimestamp);
    }

    /**
     * =========================================== Pnl ===========================================
     */
    function getCumulativePnl(IPriceFeed priceFeed, address _market, uint48 _blockTimestamp)
        internal
        view
        returns (int256 cumulativePnl)
    {
        IPriceFeed.Pnl memory pnl = priceFeed.getCumulativePnl(_market, _blockTimestamp);

        uint256 multiplier = 10 ** (PRICE_DECIMALS - pnl.precision);

        cumulativePnl = pnl.cumulativePnl * multiplier.toInt256();
    }

    /**
     * =========================================== Auxillary ===========================================
     */
    function getBaseUnit(IPriceFeed priceFeed, string memory _ticker) internal view returns (uint256 baseUnit) {
        baseUnit = 10 ** priceFeed.tokenDecimals(_ticker);
    }

    /// @dev - Wrapper around `getRequestTimestamp` with an additional validation step
    function getRequestTimestamp(IPriceFeed priceFeed, bytes32 _requestKey)
        internal
        view
        returns (uint48 requestTimestamp)
    {
        requestTimestamp = priceFeed.getRequestTimestamp(_requestKey);

        if (block.timestamp > requestTimestamp + priceFeed.timeToExpiration()) revert Oracle_RequestExpired();
    }

    function validatePrice(IPriceFeed priceFeed, IPriceFeed.Price memory _priceData) internal view returns (bool) {
        uint256 referencePrice = _getReferencePrice(priceFeed, string(abi.encodePacked(_priceData.ticker)));

        // If no secondary price feed, return true by default
        if (referencePrice == 0) return true;

        uint256 medPrice = _priceData.med * (10 ** (PRICE_DECIMALS - _priceData.precision));

        return medPrice.absDiff(referencePrice) <= referencePrice.percentage(MAX_PRICE_DEVIATION);
    }

    /**
     * =========================================== Reference Prices ===========================================
     */

    /* ONLY EVER USED FOR REFERENCE PRICES: PRICES RETURNED MAY BE HIGH-LATENCY, OR MANIPULATABLE.  */

    /**
     * In order of most common to least common reference feeds to save on gas:
     * - Chainlink
     * - Pyth
     * - Uniswap V3
     * - Uniswap V2
     */
    function _getReferencePrice(IPriceFeed priceFeed, string memory _ticker) private view returns (uint256 price) {
        IPriceFeed.SecondaryStrategy memory strategy = priceFeed.getSecondaryStrategy(_ticker);
        if (!strategy.exists) return 0;
        if (strategy.feedType == IPriceFeed.FeedType.CHAINLINK) {
            price = _getChainlinkPrice(strategy);
        } else if (strategy.feedType == IPriceFeed.FeedType.PYTH) {
            price = _getPythPrice(priceFeed, strategy, _ticker);
        } else if (strategy.feedType == IPriceFeed.FeedType.UNI_V30 || strategy.feedType == IPriceFeed.FeedType.UNI_V31)
        {
            price = _getUniswapV3Price(strategy);
        } else if (strategy.feedType == IPriceFeed.FeedType.UNI_V20 || strategy.feedType == IPriceFeed.FeedType.UNI_V21)
        {
            price = _getUniswapV2Price(strategy);
        } else {
            revert Oracle_InvalidReferenceQuery();
        }
        if (price == 0) revert Oracle_InvalidReferenceQuery();
    }

    function _getUniswapV3Price(IPriceFeed.SecondaryStrategy memory _strategy) private view returns (uint256 price) {
        if (_strategy.feedType != IPriceFeed.FeedType.UNI_V30 && _strategy.feedType != IPriceFeed.FeedType.UNI_V31) {
            revert Oracle_InvalidReferenceQuery();
        }
        IUniswapV3Pool pool = IUniswapV3Pool(_strategy.feedAddress);
        (uint160 sqrtPriceX96,,,,,,) = pool.slot0();

        address indexToken;
        address stableToken;
        if (_strategy.feedType == IPriceFeed.FeedType.UNI_V30) {
            indexToken = pool.token0();
            stableToken = pool.token1();
        } else {
            indexToken = pool.token1();
            stableToken = pool.token0();
        }

        (bool successStable, uint256 stablecoinDecimals) = _tryGetAssetDecimals(IERC20(stableToken));
        if (!successStable) revert Oracle_InvalidAmmDecimals();

        uint256 baseUnit = 10 ** stablecoinDecimals;
        UD60x18 numerator = ud(uint256(sqrtPriceX96)).powu(2).mul(ud(baseUnit));
        UD60x18 denominator = ud(2).powu(192);

        // Scale and return the price to 30 decimal places
        price = unwrap(numerator.div(denominator)) * (10 ** (PRICE_DECIMALS - stablecoinDecimals));
    }

    function _getUniswapV2Price(IPriceFeed.SecondaryStrategy memory _strategy) private view returns (uint256 price) {
        IUniswapV2Pair pair = IUniswapV2Pair(_strategy.feedAddress);
        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();

        address volatileToken;
        address stablecoinToken;
        if (_strategy.feedType == IPriceFeed.FeedType.UNI_V20) {
            volatileToken = pair.token0();
            stablecoinToken = pair.token1();
        } else if (_strategy.feedType == IPriceFeed.FeedType.UNI_V21) {
            volatileToken = pair.token1();
            stablecoinToken = pair.token0();
        } else {
            revert Oracle_InvalidReferenceQuery();
        }

        (bool successVolatile, uint256 volatileDecimals) = _tryGetAssetDecimals(IERC20(volatileToken));
        (bool successStable, uint256 stablecoinDecimals) = _tryGetAssetDecimals(IERC20(stablecoinToken));
        if (!successVolatile || !successStable) revert Oracle_InvalidAmmDecimals();

        if (_strategy.feedType == IPriceFeed.FeedType.UNI_V20) {
            price = uint256(reserve1).mulDiv(
                10 ** (PRICE_DECIMALS + volatileDecimals - stablecoinDecimals), uint256(reserve0)
            );
        } else {
            price = uint256(reserve0).mulDiv(
                10 ** (PRICE_DECIMALS + volatileDecimals - stablecoinDecimals), uint256(reserve1)
            );
        }
    }

    function _getChainlinkPrice(IPriceFeed.SecondaryStrategy memory _strategy) private view returns (uint256 price) {
        if (_strategy.feedType != IPriceFeed.FeedType.CHAINLINK) revert Oracle_InvalidReferenceQuery();
        // Get the price feed address from the ticker
        AggregatorV2V3Interface chainlinkFeed = AggregatorV2V3Interface(_strategy.feedAddress);
        // Query the feed for the price
        int256 signedPrice = chainlinkFeed.latestAnswer();
        // Convert the price from int256 to uint256 and expand decimals to 30 d.p
        price = signedPrice.abs() * (10 ** (PRICE_DECIMALS - CHAINLINK_DECIMALS));
    }

    // Need the Pyth address and the bytes32 id for the ticker
    function _getPythPrice(IPriceFeed priceFeed, IPriceFeed.SecondaryStrategy memory _strategy, string memory _ticker)
        private
        view
        returns (uint256 price)
    {
        if (_strategy.feedType != IPriceFeed.FeedType.PYTH) revert Oracle_InvalidReferenceQuery();
        // Query the Pyth feed for the price
        IPyth pythFeed = IPyth(_strategy.feedAddress);
        PythStructs.Price memory pythData = pythFeed.getEmaPriceUnsafe(priceFeed.getPythId(_ticker));
        // Expand the price to 30 d.p
        uint256 exponent = PRICE_DECIMALS - pythData.expo.abs();
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
