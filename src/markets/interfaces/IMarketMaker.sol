// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IMarket} from "./IMarket.sol";
import {Oracle} from "../../oracle/Oracle.sol";
import {IPriceFeed} from "../../oracle/interfaces/IPriceFeed.sol";

interface IMarketMaker {
    event MarketMakerInitialized(address priceStorage);
    event MarketCreated(address market, bytes32 assetId, bytes32 priceId);
    event TokenAddedToMarket(address market, bytes32 assetId, bytes32 priceId);
    event DefaultConfigSet(IMarket.Config defaultConfig);

    error MarketMaker_AlreadyInitialized();
    error MarketMaker_InvalidAsset();
    error MarketMaker_InvalidPriceId();
    error MarketMaker_InvalidBaseUnit();
    error MarketMaker_MarketExists();
    error MarketMaker_InvalidPriceFeed();
    error MarketMaker_InvalidPositionManager();
    error MarketMaker_MarketDoesNotExist();
    error MarketMaker_FailedToAddMarket();
    error MarketMaker_InvalidPoolOwner();
    error MarketMaker_InvalidFeeDistributor();
    error MarketMaker_InvalidTimeToExpiration();
    error MarketMaker_InvalidTokensOrBaseUnits();
    error MarketMaker_InvalidFeeConfig();
    error MarketMaker_InvalidHeartbeatDuration();
    error MarketMaker_InvalidMaxPriceDeviation();
    error MarketMaker_InvalidPriceSpread();
    error MarketMaker_InvalidPrimaryStrategy();
    error MarketMaker_InvalidSecondaryStrategy();
    error MarketMaker_InvalidPoolType();
    error MarketMaker_InvalidPoolTokens();
    error MarketMaker_InvalidPoolAddress();

    function initialize(
        IMarket.Config memory _defaultConfig,
        address _priceFeed,
        address _referralStorage,
        address _feeDistributor,
        address _positionManager,
        address _weth,
        address _usdc
    ) external;
    function setDefaultConfig(IMarket.Config memory _defaultConfig) external;
    function updatePriceFeed(IPriceFeed _priceFeed) external;
    function createNewMarket(
        IMarket.VaultConfig memory _config,
        bytes32 _assetId,
        bytes32 _priceId,
        Oracle.Asset memory _asset
    ) external returns (address marketAddress);

    function tokenToMarkets(bytes32 _assetId) external view returns (address market);
    function getMarkets() external view returns (address[] memory);
    function isMarket(address _market) external view returns (bool);
}
