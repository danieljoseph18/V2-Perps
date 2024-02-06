// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {IMarketMaker} from "./interfaces/IMarketMaker.sol";
import {IDataOracle} from "../oracle/interfaces/IDataOracle.sol";
import {IPriceOracle} from "../oracle/interfaces/IPriceOracle.sol";
import {IMarket} from "./interfaces/IMarket.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {Pricing} from "../libraries/Pricing.sol";

library MarketUtils {
    using SignedMath for int256;

    uint256 public constant SCALAR = 1e18;

    function getLongOpenInterestUSD(IMarket _market, uint256 _price, uint256 _baseUnit)
        external
        view
        returns (uint256 longOIUSD)
    {
        return Math.mulDiv(_market.longOpenInterest(), _price, _baseUnit);
    }

    function getShortOpenInterestUSD(IMarket _market, uint256 _price, uint256 _baseUnit)
        external
        view
        returns (uint256 shortOIUSD)
    {
        return Math.mulDiv(_market.shortOpenInterest(), _price, _baseUnit);
    }

    function getTotalOpenInterestUSD(IMarket _market, uint256 _price, uint256 _baseUnit)
        public
        view
        returns (uint256 totalOIUSD)
    {
        uint256 longOIUSD = Math.mulDiv(_market.longOpenInterest(), _price, _baseUnit);
        uint256 shortOIUSD = Math.mulDiv(_market.shortOpenInterest(), _price, _baseUnit);
        return longOIUSD + shortOIUSD;
    }

    function getTotalEntryValueUSD(IMarket _market, uint256 _indexBaseUnit, bool _isLong)
        external
        view
        returns (uint256 entryValueUsd)
    {
        uint256 totalWAEP;
        uint256 indexOI;
        if (_isLong) {
            totalWAEP = _market.longTotalWAEP();
            indexOI = _market.longOpenInterest();
        } else {
            totalWAEP = _market.shortTotalWAEP();
            indexOI = _market.shortOpenInterest();
        }

        entryValueUsd = Math.mulDiv(totalWAEP, indexOI, _indexBaseUnit);
    }

    function getPoolBalanceUSD(
        IMarket _market,
        uint256 _longTokenPrice,
        uint256 _shortTokenPrice,
        uint256 _longBaseUnit,
        uint256 _shortBaseUnit
    ) public view returns (uint256 poolBalanceUSD) {
        uint256 longBalanceUSD = Math.mulDiv(_market.longTokenAllocation(), _longTokenPrice, _longBaseUnit);
        uint256 shortBalance = Math.mulDiv(_market.shortTokenAllocation(), _shortTokenPrice, _shortBaseUnit);
        poolBalanceUSD = longBalanceUSD + shortBalance;
    }

    function getPoolAmount(IMarket _market, bool _isLong) public view returns (uint256 poolAmount) {
        if (_isLong) {
            poolAmount = _market.longTokenAllocation();
        } else {
            poolAmount = _market.shortTokenAllocation();
        }
    }

    function getPoolUsd(IMarket _market, uint256 _price, uint256 _baseUnit, bool _isLong)
        public
        view
        returns (uint256 poolUsd)
    {
        uint256 poolAmount = getPoolAmount(_market, _isLong);
        poolUsd = Math.mulDiv(poolAmount, _price, _baseUnit);
    }

    // The pnl factor is the ratio of the pnl to the pool usd
    function getPnlFactor(IMarket _market, uint256 _price, uint256 _baseUnit, bool _isLong)
        external
        view
        returns (int256 pnlFactor)
    {
        // get pool usd ( if 0 return 0)
        uint256 poolUsd = getPoolUsd(_market, _price, _baseUnit, _isLong);
        if (poolUsd == 0) {
            return 0;
        }
        // get pnl
        int256 pnl = Pricing.getPnl(_market, _price, _baseUnit, _isLong);

        uint256 factor = Math.mulDiv(pnl.abs(), SCALAR, poolUsd);
        return pnl > 0 ? int256(factor) : int256(factor) * -1;
    }

    function validateAndRetrievePrices(IDataOracle _dataOracle, uint256 _blockNumber)
        external
        view
        returns (uint256, uint256)
    {
        (bool isValid,,,, uint256 longTokenPrice, uint256 shortTokenPrice) = _dataOracle.blockData(_blockNumber);
        require(isValid, "MarketUtils: invalid block data");
        require(longTokenPrice > 0 && shortTokenPrice > 0, "MarketUtils: invalid token prices");
        return (longTokenPrice, shortTokenPrice);
    }
}
