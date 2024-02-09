// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {IPriceFeed} from "./interfaces/IPriceFeed.sol";
import {IPyth} from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import {PythStructs} from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {UD60x18, unwrap, ud, powu} from "@prb/math/UD60x18.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {Pricing} from "../libraries/Pricing.sol";

library Oracle {
    using SignedMath for int64;
    using SignedMath for int32;

    struct Asset {
        bool isValid;
        bytes32 priceId;
        uint256 baseUnit;
        PriceProvider priceProvider;
    }

    enum PriceProvider {
        PYTH,
        CHAINLINK,
        SECONDARY
    }

    uint256 private constant PRICE_DECIMALS = 18;

    function isValidAsset(IPriceFeed _priceFeed, address _token) external view returns (bool) {
        return _priceFeed.getAsset(_token).isValid;
    }

    function getPrices(IPriceFeed _priceFeed, address _token, uint256 _block)
        public
        view
        returns (uint256 blockPrice, uint256 maxPrice, uint256 minPrice)
    {
        // fetch the price data
        PythStructs.Price memory priceData = _priceFeed.getPriceData(_block, _token);
        // convert the price to a uint256 using math lib
        uint256 absPrice = priceData.price.abs();
        uint256 absExponent = priceData.expo.abs();
        // return the price at the top of the confidence interval
        UD60x18 price = ud(absPrice).mul(powu(ud(10), PRICE_DECIMALS - absExponent));
        UD60x18 confidence = ud(priceData.conf).mul(powu(ud(10), PRICE_DECIMALS - absExponent));
        blockPrice = unwrap(price);
        maxPrice = unwrap(price.add(confidence));
        minPrice = unwrap(price.sub(confidence));
    }

    function getMaxPrice(IPriceFeed _priceFeed, address _token, uint256 _block)
        public
        view
        returns (uint256 maxPrice)
    {
        (, maxPrice,) = getPrices(_priceFeed, _token, _block);
    }

    function getMinPrice(IPriceFeed _priceFeed, address _token, uint256 _block)
        public
        view
        returns (uint256 minPrice)
    {
        (,, minPrice) = getPrices(_priceFeed, _token, _block);
    }

    function getPrice(IPriceFeed _priceFeed, address _token, uint256 _block) public view returns (uint256 price) {
        Asset memory asset = _priceFeed.getAsset(_token);
        require(asset.isValid, "Oracle: invalid asset");
        if (asset.priceProvider == PriceProvider.PYTH) {
            (price,,) = getPrices(_priceFeed, _token, _block);
        } else {
            price = _priceFeed.getSecondaryPrice(_token, _block);
        }
    }

    function getMarketTokenPrices(IPriceFeed _priceFeed, uint256 _blockNumber)
        public
        view
        returns (uint256 longPrice, uint256 shortPrice)
    {
        address longToken = _priceFeed.longToken();
        address shortToken = _priceFeed.shortToken();
        longPrice = getPrice(_priceFeed, longToken, _blockNumber);
        shortPrice = getPrice(_priceFeed, shortToken, _blockNumber);
        require(longPrice > 0 && shortPrice > 0, "Oracle: invalid token prices");
    }

    function getLastMarketTokenPrices(IPriceFeed _priceFeed)
        external
        view
        returns (uint256 longPrice, uint256 shortPrice)
    {
        uint256 lastUpdateBlock = _priceFeed.lastUpdateBlock();
        longPrice = getPrice(_priceFeed, _priceFeed.longToken(), lastUpdateBlock);
        shortPrice = getPrice(_priceFeed, _priceFeed.shortToken(), lastUpdateBlock);
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
    function getNetPnl(IPriceFeed _priceFeed, IMarket _market, uint256 _blockNumber)
        public
        view
        returns (int256 netPnl)
    {
        address indexToken = _market.indexToken();
        (uint256 indexPrice,,) = getPrices(_priceFeed, indexToken, _blockNumber);
        require(indexPrice != 0, "Oracle: Invalid Index Price");
        uint256 indexBaseUnit = getBaseUnit(_priceFeed, indexToken);
        netPnl = Pricing.getNetPnl(_market, indexPrice, indexBaseUnit);
    }
}
