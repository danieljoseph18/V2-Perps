// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {IMarket} from "./IMarket.sol";
import {Oracle} from "../../oracle/Oracle.sol";

interface IMarketMaker {
    event MarketMakerInitialised(address priceStorage);
    event MarketCreated(address market, address indexToken, bytes32 priceId);
    event DefaultConfigSet(IMarket.Config defaultConfig);

    function initialise(IMarket.Config memory _defaultConfig, address _priceFeed, address _liquidityVault) external;
    function setDefaultConfig(IMarket.Config memory _defaultConfig) external;
    function createNewMarket(address _indexToken, bytes32 _priceId, Oracle.Asset memory _asset)
        external
        returns (address market);

    function tokenToMarkets(address _indexToken) external view returns (address market);
}
