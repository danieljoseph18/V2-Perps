// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IMarket} from "./IMarket.sol";
import {IPriceFeed} from "../../oracle/interfaces/IPriceFeed.sol";

interface IMarketFactory {
    event MarketFactoryInitialized(address priceStorage);
    event MarketCreated(address market, string ticker);
    event TokenAddedToMarket(address market, string ticker);
    event DefaultConfigSet();
    event MarketRequested(bytes32 requestKey, string indexTokenTicker);

    error MarketFactory_AlreadyInitialized();
    error MarketFactory_InvalidAsset();
    error MarketFactory_InvalidPriceId();
    error MarketFactory_InvalidBaseUnit();
    error MarketFactory_MarketExists();
    error MarketFactory_InvalidPriceFeed();
    error MarketFactory_MarketDoesNotExist();
    error MarketFactory_FailedToAddMarket();
    error MarketFactory_InvalidMaxPriceDeviation();
    error MarketFactory_InvalidPrimaryStrategy();
    error MarketFactory_InvalidSecondaryStrategy();
    error MarketFactory_InvalidPoolType();
    error MarketFactory_InvalidPoolTokens();
    error MarketFactory_InvalidPoolAddress();
    error MarketFactory_InvalidOwner();
    error MarketFactory_InvalidFee();
    error MarketFactory_RequestDoesNotExist();
    error MarketFactory_AccessDenied();
    error MarketFactory_FailedToRemoveRequest();

    struct DeployRequest {
        bool isMultiAsset;
        address owner;
        string indexTokenTicker;
        string marketTokenName;
        string marketTokenSymbol;
        uint256 baseUnit;
    }

    function initialize(
        IMarket.Config memory _defaultConfig,
        address _priceFeed,
        address _referralStorage,
        address _positionManager,
        address _feeDistributor,
        address _feeReceiver,
        uint256 _marketCreationFee
    ) external;
    function setDefaultConfig(IMarket.Config memory _defaultConfig) external;
    function updatePriceFeed(IPriceFeed _priceFeed) external;
    function requestNewMarket(DeployRequest calldata _request) external payable;
    function executeNewMarket(bytes32 _requestKey) external returns (address);
    function getRequest(bytes32 _requestKey) external view returns (DeployRequest memory);
    function marketCreationFee() external view returns (uint256);
    function markets(uint256 index) external view returns (address);
    function isMarket(address _market) external view returns (bool);
}
