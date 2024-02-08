// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {Market, IMarket} from "../Market.sol";

interface IMarketMaker {
    struct MarketConfig {
        uint256 maxFundingVelocity;
        uint256 skewScale;
        uint256 maxFundingRate;
        uint256 minFundingRate;
        uint256 borrowingFactor;
        uint256 borrowingExponent;
        uint256 priceImpactFactor;
        uint256 priceImpactExponent;
        uint256 maxPnlFactor;
        uint256 targetPnlFactor;
        bool feeForSmallerSide;
        bool adlFlaggedLong;
        bool adlFlaggedShort;
    }

    event MarketMakerInitialised(address dataOracle, address priceOracle);
    event MarketCreated(address market, address indexToken, address priceFeed);
    event DefaultConfigSet(MarketConfig defaultConfig);

    function initialise(MarketConfig memory _defaultConfig, address _dataOracle, address _priceOracle) external;
    function setDefaultConfig(MarketConfig memory _defaultConfig) external;
    function createNewMarket(address _indexToken, address _priceFeed, uint256 _baseUnit)
        external
        returns (Market market);

    function tokenToMarkets(address _indexToken) external view returns (address market);
}
