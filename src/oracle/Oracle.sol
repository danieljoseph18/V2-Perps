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
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {IPyth} from "@pyth/contracts/IPyth.sol";
import {PythStructs} from "@pyth/contracts/PythStructs.sol";
import {ERC20, IERC20, IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {MathUtils} from "../libraries/MathUtils.sol";
import {mulDiv} from "@prb/math/Common.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {ud, UD60x18, unwrap} from "@prb/math/UD60x18.sol";

library Oracle {
    using SignedMath for int256;
    using SignedMath for int64;
    using SignedMath for int32;
    using MathUtils for uint256;
    using SafeCast for uint256;
    using Strings for uint256;

    error Oracle_SequencerDown();
    error Oracle_PriceNotSet();
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
    uint16 private constant MAX_VARIANCE = 10_000;
    uint64 private constant MAX_PRICE_DEVIATION = 0.1e18;
    uint64 private constant OVERESTIMATION_FACTOR = 0.1e18;
    uint64 private constant LINK_BASE_UNIT = 1e18;
    uint64 private constant PREMIUM_FEE = 0.2e18; // 20%

    /**
     * ====================================== Validation Functions ======================================
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

    /// @dev - Wrapper around `getRequestTimestamp` with an additional validation step
    function getRequestTimestamp(IPriceFeed priceFeed, bytes32 _requestKey)
        external
        view
        returns (uint48 requestTimestamp)
    {
        // Validate the Price Request
        requestTimestamp = priceFeed.getRequestTimestamp(_requestKey);
        if (block.timestamp > requestTimestamp + priceFeed.timeToExpiration()) revert Oracle_RequestExpired();
    }

    function isValidChainlinkFeed(FeedRegistryInterface feedRegistry, address _feedAddress) external view {
        if (!feedRegistry.isFeedEnabled(_feedAddress)) revert Oracle_InvalidSecondaryStrategy();
    }

    function isValidUniswapV3Pool(
        IUniswapV3Factory factory,
        address _poolAddress,
        IPriceFeed.FeedType _feedType,
        bytes32[] calldata _merkleProof,
        bytes32 _merkleRoot
    ) external view {
        IUniswapV3Pool pool = IUniswapV3Pool(_poolAddress);
        // Check if the pool address matches the one returned by the factory
        address token0 = pool.token0();
        address token1 = pool.token1();
        address expectedPoolAddress = factory.getPool(token0, token1, pool.fee());
        if (expectedPoolAddress != _poolAddress) revert Oracle_InvalidSecondaryStrategy();
        if (_feedType == IPriceFeed.FeedType.UNI_V30) {
            // If feed type is token0, check if the token1 (stablecoin) is stored in the Merkle Tree
            bytes32 leaf = keccak256(abi.encodePacked(token1));
            if (!MerkleProof.verify(_merkleProof, _merkleRoot, leaf)) {
                revert Oracle_InvalidSecondaryStrategy();
            }
        } else {
            // If feed type is token1, check if the token0 (stablecoin) is stored in the Merkle Tree
            bytes32 leaf = keccak256(abi.encodePacked(token0));
            if (!MerkleProof.verify(_merkleProof, _merkleRoot, leaf)) {
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
    ) external view {
        IUniswapV2Pair pair = IUniswapV2Pair(_poolAddress);
        // Check if the pair address matches the one returned by the factory
        address expectedPoolAddress = factory.getPair(pair.token0(), pair.token1());
        if (expectedPoolAddress != _poolAddress) revert Oracle_InvalidSecondaryStrategy();
        if (_feedType == IPriceFeed.FeedType.UNI_V20) {
            // If feed type is token0, check if the token1 (stablecoin) is stored in the Merkle Tree
            bytes32 leaf = keccak256(abi.encodePacked(pair.token1()));
            if (!MerkleProof.verify(_merkleProof, _merkleRoot, leaf)) {
                revert Oracle_InvalidSecondaryStrategy();
            }
        } else {
            // If feed type is token1, check if the token0 (stablecoin) is stored in the Merkle Tree
            bytes32 leaf = keccak256(abi.encodePacked(pair.token0()));
            if (!MerkleProof.verify(_merkleProof, _merkleRoot, leaf)) {
                revert Oracle_InvalidSecondaryStrategy();
            }
        }
    }

    function isValidPythFeed(bytes32[] calldata _merkleProof, bytes32 _merkleRoot, bytes32 _priceId) external pure {
        // Check if the Pyth feed is stored within the Merkle Tree as a whitelisted feed.
        // No need to check for bytes32(0) is this case will revert with this check.
        if (!MerkleProof.verify(_merkleProof, _merkleRoot, _priceId)) {
            revert Oracle_InvalidSecondaryStrategy();
        }
    }

    function validateFeedType(IPriceFeed.FeedType _feedType) external pure {
        if (
            _feedType != IPriceFeed.FeedType.CHAINLINK && _feedType != IPriceFeed.FeedType.UNI_V30
                && _feedType != IPriceFeed.FeedType.UNI_V31 && _feedType != IPriceFeed.FeedType.UNI_V20
                && _feedType != IPriceFeed.FeedType.UNI_V21 && _feedType != IPriceFeed.FeedType.PYTH
        ) {
            revert Oracle_InvalidPoolType();
        }
    }

    /**
     * ====================================== Helper Functions ======================================
     */
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

    /// @dev - Prepend the timestamp to the arguments before sending to the DON
    function constructPriceArguments(string calldata _ticker) external view returns (string[] memory args) {
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

    function constructMultiPriceArgs(IMarket market) external view returns (string[] memory args) {
        // Get the stringified timestamp
        string memory timestamp = block.timestamp.toString();
        // Return an array with the stringified timestamp appended before the tickers
        string[] memory tickers = market.getTickers();
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
    function constructPnlArguments(IMarket market) external view returns (string[] memory args) {
        // Get the tickers
        string[] memory tickers = market.getTickers();
        // Get the stringified timestamp
        string memory timestamp = block.timestamp.toString();
        // Return an array with the stringified timestamp appended before the tickers
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
        } else if (
            tokenData.feedType == IPriceFeed.FeedType.UNI_V30 || tokenData.feedType == IPriceFeed.FeedType.UNI_V21
        ) {
            price = _getUniswapV3Price(tokenData);
        } else if (
            tokenData.feedType == IPriceFeed.FeedType.UNI_V20 || tokenData.feedType == IPriceFeed.FeedType.UNI_V21
        ) {
            price = _getUniswapV2Price(tokenData);
        } else {
            revert Oracle_InvalidReferenceQuery();
        }
        if (price == 0) revert Oracle_InvalidReferenceQuery();
    }

    function _getUniswapV3Price(IPriceFeed.TokenData memory _tokenData) private view returns (uint256 price) {
        if (_tokenData.feedType != IPriceFeed.FeedType.UNI_V30 && _tokenData.feedType != IPriceFeed.FeedType.UNI_V31) {
            revert Oracle_InvalidReferenceQuery();
        }
        IUniswapV3Pool pool = IUniswapV3Pool(_tokenData.secondaryFeed);
        (uint160 sqrtPriceX96,,,,,,) = pool.slot0();

        address indexToken;
        address stableToken;
        if (_tokenData.feedType == IPriceFeed.FeedType.UNI_V30) {
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

    function _getUniswapV2Price(IPriceFeed.TokenData memory _tokenData) private view returns (uint256 price) {
        IUniswapV2Pair pair = IUniswapV2Pair(_tokenData.secondaryFeed);
        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();

        address volatileToken;
        address stablecoinToken;
        if (_tokenData.feedType == IPriceFeed.FeedType.UNI_V20) {
            volatileToken = pair.token0();
            stablecoinToken = pair.token1();
        } else if (_tokenData.feedType == IPriceFeed.FeedType.UNI_V21) {
            volatileToken = pair.token1();
            stablecoinToken = pair.token0();
        } else {
            revert Oracle_InvalidReferenceQuery();
        }

        (bool successVolatile, uint256 volatileDecimals) = _tryGetAssetDecimals(IERC20(volatileToken));
        (bool successStable, uint256 stablecoinDecimals) = _tryGetAssetDecimals(IERC20(stablecoinToken));
        if (!successVolatile || !successStable) revert Oracle_InvalidAmmDecimals();

        if (_tokenData.feedType == IPriceFeed.FeedType.UNI_V20) {
            price = mulDiv(
                uint256(reserve1), 10 ** (PRICE_DECIMALS + volatileDecimals - stablecoinDecimals), uint256(reserve0)
            );
        } else {
            price = mulDiv(
                uint256(reserve0), 10 ** (PRICE_DECIMALS + volatileDecimals - stablecoinDecimals), uint256(reserve1)
            );
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
