// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {IMarket} from "./IMarket.sol";
import {IVault} from "./IVault.sol";
import {Oracle} from "../../oracle/Oracle.sol";
import {IPriceFeed} from "../../oracle/interfaces/IPriceFeed.sol";

interface IMarketMaker {
    event MarketMakerInitialised(address priceStorage);
    event MarketCreated(address market, bytes32 assetId, bytes32 priceId);
    event TokenAddedToMarket(address market, bytes32 assetId, bytes32 priceId);
    event DefaultConfigSet(IMarket.Config defaultConfig);

    error MarketMaker_AlreadyInitialised();
    error MarketMaker_InvalidAsset();
    error MarketMaker_InvalidPriceId();
    error MarketMaker_InvalidBaseUnit();
    error MarketMaker_MarketExists();
    error MarketMaker_InvalidPriceFeed();
    error MarketMaker_InvalidProcessor();
    error MarketMaker_MarketDoesNotExist();
    error MarketMaker_FailedToAddMarket();

    function initialise(IMarket.Config memory _defaultConfig, address _priceFeed, address _processor) external;
    function setDefaultConfig(IMarket.Config memory _defaultConfig) external;
    function updatePriceFeed(IPriceFeed _priceFeed) external;
    function createNewMarket(
        IVault.VaultConfig memory _config,
        bytes32 _assetId,
        bytes32 _priceId,
        Oracle.Asset memory _asset
    ) external returns (address marketAddress);

    function tokenToMarkets(bytes32 _assetId) external view returns (address market);
    function getMarkets() external view returns (address[] memory);
    function isMarket(address _market) external view returns (bool);
}
