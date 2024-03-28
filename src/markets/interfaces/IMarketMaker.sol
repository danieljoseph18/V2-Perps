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
    event MarketRequested(bytes32 requestKey, string indexTokenTicker);

    error MarketMaker_AlreadyInitialized();
    error MarketMaker_InvalidAsset();
    error MarketMaker_InvalidPriceId();
    error MarketMaker_InvalidBaseUnit();
    error MarketMaker_MarketExists();
    error MarketMaker_InvalidPriceFeed();
    error MarketMaker_MarketDoesNotExist();
    error MarketMaker_FailedToAddMarket();
    error MarketMaker_InvalidMaxPriceDeviation();
    error MarketMaker_InvalidPrimaryStrategy();
    error MarketMaker_InvalidSecondaryStrategy();
    error MarketMaker_InvalidPoolType();
    error MarketMaker_InvalidPoolTokens();
    error MarketMaker_InvalidPoolAddress();
    error MarketMaker_InvalidOwner();
    error MarketMaker_InvalidFee();
    error MarketMaker_RequestDoesNotExist();

    struct MarketRequest {
        address owner;
        string indexTokenTicker;
        string marketTokenName;
        string marketTokenSymbol;
        Oracle.Asset asset;
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
    function requestNewMarket(MarketRequest calldata _request) external payable;
    function executeNewMarket(bytes32 _requestKey) external returns (address);
    function tokenToMarket(bytes32 _assetId) external view returns (address);
    function getMarkets() external view returns (address[] memory);
    function requests(bytes32 _requestKey)
        external
        view
        returns (
            address owner,
            string memory indexTokenTicker,
            string memory marketTokenName,
            string memory marketTokenSymbol,
            Oracle.Asset memory asset
        );
    function marketCreationFee() external view returns (uint256);
    function isMarket(address _market) external view returns (bool);
}
