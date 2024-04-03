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

    function getPrice(IPriceFeed priceFeed, bytes32 _requestId, string calldata _ticker)
        external
        view
        returns (uint256 price)
    {
        price = priceFeed.getPrices(_requestId, _ticker).med;
        if (price == 0) revert Oracle_PriceNotSet();
    }

    function getMaxPrice(IPriceFeed priceFeed, bytes32 _requestId, string calldata _ticker)
        external
        view
        returns (uint256 maxPrice)
    {
        maxPrice = priceFeed.getPrices(_requestId, _ticker).max;
        if (maxPrice == 0) revert Oracle_PriceNotSet();
    }

    function getMinPrice(IPriceFeed priceFeed, bytes32 _requestId, string calldata _ticker)
        external
        view
        returns (uint256 minPrice)
    {
        minPrice = priceFeed.getPrices(_requestId, _ticker).min;
        if (minPrice == 0) revert Oracle_PriceNotSet();
    }

    function getMarketTokenPrices(IPriceFeed priceFeed, bytes32 _requestId, bool _maximise)
        external
        view
        returns (uint256 longPrice, uint256 shortPrice)
    {
        (IPriceFeed.Price memory longPrices, IPriceFeed.Price memory shortPrices) =
            getMarketTokenPrices(priceFeed, _requestId);
        if (_maximise) {
            longPrice = longPrices.max;
            shortPrice = shortPrices.max;
        } else {
            longPrice = longPrices.min;
            shortPrice = shortPrices.min;
        }
        if (longPrice == 0 || shortPrice == 0) revert Oracle_PriceNotSet();
    }

    function getMarketTokenPrices(IPriceFeed priceFeed, bytes32 _requestId)
        public
        view
        returns (IPriceFeed.Price memory _longPrices, IPriceFeed.Price memory _shortPrices)
    {
        _longPrices = priceFeed.getPrices(_requestId, LONG_TICKER);
        _shortPrices = priceFeed.getPrices(_requestId, SHORT_TICKER);
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
