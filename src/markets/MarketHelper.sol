//  ,----,------------------------------,------.
//   | ## |                              |    - |
//   | ## |                              |    - |
//   |    |------------------------------|    - |
//   |    ||............................||      |
//   |    ||,-                        -.||      |
//   |    ||___                      ___||    ##|
//   |    ||---`--------------------'---||      |
//   `--mb'|_|______________________==__|`------'

//    ____  ____  ___ _   _ _____ _____ ____
//   |  _ \|  _ \|_ _| \ | |_   _|___ /|  _ \
//   | |_) | |_) || ||  \| | | |   |_ \| |_) |
//   |  __/|  _ < | || |\  | | |  ___) |  _ <
//   |_|   |_| \_\___|_| \_| |_| |____/|_| \_\

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {IMarketMaker} from "./interfaces/IMarketMaker.sol";
import {IDataOracle} from "../oracle/interfaces/IDataOracle.sol";
import {IPriceOracle} from "../oracle/interfaces/IPriceOracle.sol";
import {Market} from "../structs/Market.sol";

// Helper functions for market related logic
library MarketHelper {
    uint256 public constant PRICE_DECIMALS = 1e18;

    function getMarketFromIndexToken(address _marketMaker, address _indexToken)
        external
        view
        returns (Market.Data memory market)
    {
        bytes32 _key = keccak256(abi.encode(_indexToken));
        market = IMarketMaker(_marketMaker).markets(_key);
    }

    function getIndexOpenInterest(address _marketMaker, address _indexToken, bool _isLong)
        public
        view
        returns (uint256 indexOI)
    {
        bytes32 _key = keccak256(abi.encode(_indexToken));
        indexOI = _isLong
            ? IMarketMaker(_marketMaker).indexTokenLongOpenInterest(_key)
            : IMarketMaker(_marketMaker).indexTokenShortOpenInterest(_key);
    }

    function getTotalIndexOpenInterest(address _marketMaker, address _indexToken)
        external
        view
        returns (uint256 totalOI)
    {
        totalOI = getIndexOpenInterest(_marketMaker, _indexToken, true)
            + getIndexOpenInterest(_marketMaker, _indexToken, false);
    }

    function getIndexOpenInterestUSD(
        address _marketMaker,
        address _dataOracle,
        address _priceOracle,
        address _indexToken,
        bool _isLong
    ) public view returns (uint256 indexOIUsd) {
        uint256 indexOI = getIndexOpenInterest(_marketMaker, _indexToken, _isLong);
        uint256 baseUnit = IDataOracle(_dataOracle).getBaseUnits(_indexToken);
        uint256 indexPrice = IPriceOracle(_priceOracle).getPrice(_indexToken);
        indexOIUsd = (indexOI * indexPrice) / baseUnit;
    }

    function getTotalIndexOpenInterestUSD(
        address _marketMaker,
        address _dataOracle,
        address _priceOracle,
        address _indexToken
    ) external view returns (uint256 totalIndexOIUsd) {
        totalIndexOIUsd = getIndexOpenInterestUSD(_marketMaker, _dataOracle, _indexToken, _priceOracle, true)
            + getIndexOpenInterestUSD(_marketMaker, _dataOracle, _indexToken, _priceOracle, false);
    }

    function getTotalEntryValueUsd(address _indexToken, address _marketMaker, address _dataOracle, bool _isLong)
        external
        view
        returns (uint256 entryValueUsd)
    {
        bytes32 marketKey = keccak256(abi.encode(_indexToken));
        Market.Data memory market = IMarketMaker(_marketMaker).markets(marketKey);
        uint256 totalWAEP = _isLong ? market.pricing.longTotalWAEP : market.pricing.shortTotalWAEP;
        address indexToken = _indexToken;
        uint256 indexOI = getIndexOpenInterest(_marketMaker, indexToken, _isLong);

        entryValueUsd = (totalWAEP * indexOI) / IDataOracle(_dataOracle).getBaseUnits(indexToken);
    }

    function getPoolBalance(address _marketMaker, bytes32 _marketKey) public view returns (uint256) {
        return IMarketMaker(_marketMaker).marketAllocations(_marketKey);
    }

    function getPoolBalanceUSD(address _marketMaker, bytes32 _marketKey, address _priceOracle)
        external
        view
        returns (uint256)
    {
        return (getPoolBalance(_marketMaker, _marketKey) * IPriceOracle(_priceOracle).getCollateralPrice())
            / PRICE_DECIMALS;
    }
}
