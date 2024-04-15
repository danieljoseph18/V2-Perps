// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IPriceFeed} from "./interfaces/IPriceFeed.sol";
import {IChainlinkFeed} from "./interfaces/IChainlinkFeed.sol";
import {IUniswapV3Pool} from "./interfaces/IUniswapV3Pool.sol";
import {IUniswapV2Pair} from "./interfaces/IUniswapV2Pair.sol";
import {ERC20, IERC20, IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {mulDiv} from "@prb/math/Common.sol";
import {ud, UD60x18, unwrap} from "@prb/math/UD60x18.sol";

library Oracle {
    error Oracle_SequencerDown();
    error Oracle_PriceNotSet();
    error Oracle_InvalidAmmDecimals();
    error Oracle_InvalidPoolType();

    struct UniswapPool {
        address token0;
        address token1;
        address poolAddress;
        PoolType poolType;
    }

    enum PoolType {
        V3,
        V2
    }

    string private constant LONG_TICKER = "ETH";
    string private constant SHORT_TICKER = "USDC";
    uint8 private constant PRICE_DECIMALS = 30;
    uint16 private constant MAX_VARIANCE = 10_000;

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

    function getMarketTokenPrices(IPriceFeed priceFeed, bool _maximise, uint48 _blockTimestamp)
        external
        view
        returns (uint256 longPrice, uint256 shortPrice)
    {
        if (_maximise) {
            longPrice = getMaxPrice(priceFeed, LONG_TICKER, _blockTimestamp);
            shortPrice = getMaxPrice(priceFeed, SHORT_TICKER, _blockTimestamp);
        } else {
            longPrice = getMinPrice(priceFeed, LONG_TICKER, _blockTimestamp);
            shortPrice = getMinPrice(priceFeed, SHORT_TICKER, _blockTimestamp);
        }
    }

    function getMarketTokenPrices(IPriceFeed priceFeed, uint48 _blockTimestamp)
        public
        view
        returns (IPriceFeed.Price memory _longPrices, IPriceFeed.Price memory _shortPrices)
    {
        _longPrices = priceFeed.getPrices(LONG_TICKER, _blockTimestamp);
        _shortPrices = priceFeed.getPrices(SHORT_TICKER, _blockTimestamp);
    }

    function getBaseUnit(IPriceFeed priceFeed, string calldata _ticker) external view returns (uint256 baseUnit) {
        baseUnit = priceFeed.baseUnits(_ticker);
    }

    /**
     * ====================================== In case I want to implement Ref Price ======================================
     */

    /// @dev _baseUnit is the base unit of the token0
    // ONLY EVER USED FOR REFERENCE PRICE -> PRICE IS MANIPULATABLE
    function getAmmPrice(UniswapPool memory _pool) public view returns (uint256 price) {
        if (_pool.poolType == PoolType.V3) {
            IUniswapV3Pool pool = IUniswapV3Pool(_pool.poolAddress);
            (uint160 sqrtPriceX96,,,,,,) = pool.slot0();
            (bool success, uint256 token0Decimals) = _tryGetAssetDecimals(IERC20(_pool.token0));
            if (!success) revert Oracle_InvalidAmmDecimals();
            uint256 baseUnit = 10 ** token0Decimals;
            UD60x18 numerator = ud(uint256(sqrtPriceX96)).powu(2).mul(ud(baseUnit));
            UD60x18 denominator = ud(2).powu(192);
            price = unwrap(numerator.div(denominator));
            return price;
        } else if (_pool.poolType == PoolType.V2) {
            IUniswapV2Pair pair = IUniswapV2Pair(_pool.poolAddress);
            (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
            address pairToken0 = pair.token0();
            (bool success0, uint256 token0Decimals) = _tryGetAssetDecimals(IERC20(_pool.token0));
            (bool success1, uint256 token1Decimals) = _tryGetAssetDecimals(IERC20(_pool.token1));
            if (!success0 || !success1) revert Oracle_InvalidAmmDecimals();
            if (_pool.token0 == pairToken0) {
                uint256 baseUnit = 10 ** token0Decimals;
                price = mulDiv(uint256(reserve1), baseUnit, uint256(reserve0));
            } else {
                uint256 baseUnit = 10 ** token1Decimals;
                price = mulDiv(uint256(reserve0), baseUnit, uint256(reserve1));
            }
            return price;
        } else {
            revert Oracle_InvalidPoolType();
        }
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
