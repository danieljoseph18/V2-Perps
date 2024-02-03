// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {Market} from "../Market.sol";

interface IMarketMaker {
    event MarketMakerInitialised(address dataOracle, address priceOracle);
    event MarketCreated(address market, address indexToken, address priceFeed);

    function initialise(address _dataOracle, address _priceOracle) external;
    function createNewMarket(address _indexToken, address _priceFeed, uint256 _baseUnit)
        external
        returns (Market market);

    function tokenToMarkets(address _indexToken) external view returns (address market);
}
