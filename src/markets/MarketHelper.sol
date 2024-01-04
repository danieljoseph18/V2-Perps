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

import {IMarketStorage} from "./interfaces/IMarketStorage.sol";
import {IMarket} from "./interfaces/IMarket.sol";
import {IDataOracle} from "../oracle/interfaces/IDataOracle.sol";
import {IPriceOracle} from "../oracle/interfaces/IPriceOracle.sol";
import {Types} from "../libraries/Types.sol";

// Helper functions for market related logic
library MarketHelper {
    uint256 public constant PRICE_DECIMALS = 1e18;

    function getMarketFromIndexToken(address _marketStorage, address _indexToken)
        external
        view
        returns (Types.Market memory market)
    {
        bytes32 _key = keccak256(abi.encode(_indexToken));
        market = IMarketStorage(_marketStorage).markets(_key);
    }

    function getIndexOpenInterest(address _marketStorage, address _indexToken, bool _isLong)
        public
        view
        returns (uint256 indexOI)
    {
        bytes32 _key = keccak256(abi.encode(_indexToken));
        indexOI = _isLong
            ? IMarketStorage(_marketStorage).indexTokenLongOpenInterest(_key)
            : IMarketStorage(_marketStorage).indexTokenShortOpenInterest(_key);
    }

    function getTotalIndexOpenInterest(address _marketStorage, address _indexToken)
        external
        view
        returns (uint256 totalOI)
    {
        totalOI = getIndexOpenInterest(_marketStorage, _indexToken, true)
            + getIndexOpenInterest(_marketStorage, _indexToken, false);
    }

    function getIndexOpenInterestUSD(
        address _marketStorage,
        address _dataOracle,
        address _priceOracle,
        address _indexToken,
        bool _isLong
    ) public view returns (uint256 indexOIUsd) {
        uint256 indexOI = getIndexOpenInterest(_marketStorage, _indexToken, _isLong);
        uint256 baseUnit = IDataOracle(_dataOracle).getBaseUnits(_indexToken);
        uint256 indexPrice = IPriceOracle(_priceOracle).getPrice(_indexToken);
        indexOIUsd = (indexOI * indexPrice) / baseUnit;
    }

    function getTotalIndexOpenInterestUSD(
        address _marketStorage,
        address _dataOracle,
        address _priceOracle,
        address _indexToken
    ) external view returns (uint256 totalIndexOIUsd) {
        totalIndexOIUsd = getIndexOpenInterestUSD(_marketStorage, _dataOracle, _indexToken, _priceOracle, true)
            + getIndexOpenInterestUSD(_marketStorage, _dataOracle, _indexToken, _priceOracle, false);
    }

    function getTotalEntryValueUsd(address _market, address _marketStorage, address _dataOracle, bool _isLong)
        external
        view
        returns (uint256 entryValueUsd)
    {
        uint256 totalWAEP = _isLong ? IMarket(_market).longTotalWAEP() : IMarket(_market).shortTotalWAEP();
        address indexToken = IMarket(_market).indexToken();
        uint256 indexOI = getIndexOpenInterest(_marketStorage, indexToken, _isLong);

        entryValueUsd = (totalWAEP * indexOI) / IDataOracle(_dataOracle).getBaseUnits(indexToken);
    }

    function getPoolBalance(address _marketStorage, bytes32 _marketKey) public view returns (uint256) {
        return IMarketStorage(_marketStorage).marketAllocations(_marketKey);
    }

    function getPoolBalanceUSD(address _marketStorage, bytes32 _marketKey, address _priceOracle)
        external
        view
        returns (uint256)
    {
        return (getPoolBalance(_marketStorage, _marketKey) * IPriceOracle(_priceOracle).getCollateralPrice())
            / PRICE_DECIMALS;
    }
}
