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
pragma solidity 0.8.21;

import {MarketStructs} from "./MarketStructs.sol";
import {IMarketStorage} from "./interfaces/IMarketStorage.sol";
import {IMarket} from "./interfaces/IMarket.sol";
import {IDataOracle} from "../oracle/interfaces/IDataOracle.sol";
import {IPriceOracle} from "../oracle/interfaces/IPriceOracle.sol";

// Helper functions for market related logic
library MarketHelper {
    uint256 public constant PRICE_DECIMALS = 1e18;

    function getMarket(address _marketStorage, bytes32 _key) external view returns (MarketStructs.Market memory) {
        return IMarketStorage(_marketStorage).markets(_key);
    }

    function getMarketFromIndexToken(address _marketStorage, address _indexToken)
        external
        view
        returns (MarketStructs.Market memory)
    {
        bytes32 _key = keccak256(abi.encodePacked(_indexToken));
        return IMarketStorage(_marketStorage).markets(_key);
    }

    function getIndexOpenInterest(address _marketStorage, address _indexToken, bool _isLong)
        public
        view
        returns (uint256)
    {
        bytes32 _key = keccak256(abi.encodePacked(_indexToken));
        return _isLong
            ? IMarketStorage(_marketStorage).indexTokenLongOpenInterest(_key)
            : IMarketStorage(_marketStorage).indexTokenShortOpenInterest(_key);
    }

    function getTotalIndexOpenInterest(address _marketStorage, address _indexToken)
        public
        view
        returns (uint256 _totalOI)
    {
        return getIndexOpenInterest(_marketStorage, _indexToken, true)
            + getIndexOpenInterest(_marketStorage, _indexToken, false);
    }

    function getIndexOpenInterestUSD(
        address _marketStorage,
        address _dataOracle,
        address _priceOracle,
        address _indexToken,
        bool _isLong
    ) public view returns (uint256) {
        uint256 indexOI = getIndexOpenInterest(_marketStorage, _indexToken, _isLong);
        uint256 baseUnit = IDataOracle(_dataOracle).getBaseUnits(_indexToken);
        uint256 indexPrice = IPriceOracle(_priceOracle).getPrice(_indexToken);
        return (indexOI * indexPrice) / baseUnit;
    }

    function getTotalIndexOpenInterestUSD(
        address _marketStorage,
        address _dataOracle,
        address _priceOracle,
        address _indexToken
    ) external view returns (uint256) {
        return getIndexOpenInterestUSD(_marketStorage, _dataOracle, _indexToken, _priceOracle, true)
            + getIndexOpenInterestUSD(_marketStorage, _dataOracle, _indexToken, _priceOracle, false);
    }

    function getCollateralOpenInterest(address _marketStorage, address _collateralToken, bool _isLong)
        public
        view
        returns (uint256)
    {
        bytes32 _key = keccak256(abi.encodePacked(_collateralToken));
        return _isLong
            ? IMarketStorage(_marketStorage).collatTokenLongOpenInterest(_key)
            : IMarketStorage(_marketStorage).collatTokenShortOpenInterest(_key);
    }

    function getTotalCollateralOpenInterest(address _marketStorage, address _collateralToken)
        public
        view
        returns (uint256)
    {
        return getCollateralOpenInterest(_marketStorage, _collateralToken, true)
            + getCollateralOpenInterest(_marketStorage, _collateralToken, false);
    }

    function getCollateralOpenInterestUSD(
        address _marketStorage,
        address _priceOracle,
        address _collateralToken,
        bool _isLong
    ) public view returns (uint256) {
        uint256 collateralOI = getCollateralOpenInterest(_marketStorage, _collateralToken, _isLong);
        uint256 collateralPrice = IPriceOracle(_priceOracle).getPrice(_collateralToken);
        return (collateralOI * collateralPrice) / PRICE_DECIMALS;
    }

    function getTotalCollateralOpenInterestUSD(address _marketStorage, address _priceOracle, address _collateralToken)
        external
        view
        returns (uint256)
    {
        return getCollateralOpenInterestUSD(_marketStorage, _collateralToken, _priceOracle, true)
            + getCollateralOpenInterestUSD(_marketStorage, _collateralToken, _priceOracle, false);
    }

    function getTotalEntryValue(address _market, address _marketStorage, address _dataOracle, bool _isLong)
        public
        view
        returns (uint256)
    {
        uint256 totalWAEP = _isLong ? IMarket(_market).longTotalWAEP() : IMarket(_market).shortTotalWAEP();
        address indexToken = IMarket(_market).indexToken();
        uint256 indexOI = getIndexOpenInterest(_marketStorage, indexToken, _isLong);
        uint256 baseUnit = IDataOracle(_dataOracle).getBaseUnits(indexToken);
        return (totalWAEP * indexOI) / baseUnit;
    }

    function getPoolBalance(address _marketStorage, bytes32 _marketKey) public view returns (uint256) {
        return IMarketStorage(_marketStorage).marketAllocations(_marketKey);
    }

    function getPoolBalanceUSD(address _marketStorage, bytes32 _marketKey, address _priceOracle, address _usdc)
        external
        view
        returns (uint256)
    {
        return
            (getPoolBalance(_marketStorage, _marketKey) * IPriceOracle(_priceOracle).getPrice(_usdc)) / PRICE_DECIMALS;
    }
}
