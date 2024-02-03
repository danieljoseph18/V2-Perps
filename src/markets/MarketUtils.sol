// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {IMarketMaker} from "./interfaces/IMarketMaker.sol";
import {IDataOracle} from "../oracle/interfaces/IDataOracle.sol";
import {IPriceOracle} from "../oracle/interfaces/IPriceOracle.sol";
import {IMarket} from "./interfaces/IMarket.sol";

library MarketUtils {
    function getLongOpenInterestUSD(IMarket _market, uint256 _price, uint256 _baseUnit)
        external
        view
        returns (uint256 longOIUSD)
    {
        return (_market.longOpenInterest() * _price) / _baseUnit;
    }

    function getShortOpenInterestUSD(IMarket _market, uint256 _price, uint256 _baseUnit)
        external
        view
        returns (uint256 shortOIUSD)
    {
        return (_market.shortOpenInterest() * _price) / _baseUnit;
    }

    function getTotalOpenInterestUSD(IMarket _market, uint256 _price, uint256 _baseUnit)
        external
        view
        returns (uint256 totalOIUSD)
    {
        uint256 longOIUSD = (_market.longOpenInterest() * _price) / _baseUnit;
        uint256 shortOIUSD = (_market.shortOpenInterest() * _price) / _baseUnit;
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

        entryValueUsd = (totalWAEP * indexOI) / _indexBaseUnit;
    }

    function getPoolBalanceUSD(
        IMarket _market,
        uint256 _longTokenPrice,
        uint256 _shortTokenPrice,
        uint256 _longBaseUnit,
        uint256 _shortBaseUnit
    ) external view returns (uint256 poolBalanceUSD) {
        uint256 longBalanceUSD = _market.longTokenAllocation() * _longTokenPrice / _longBaseUnit;
        uint256 shortBalance = _market.shortTokenAllocation() * _shortTokenPrice / _shortBaseUnit;
        poolBalanceUSD = longBalanceUSD + shortBalance;
    }
}
