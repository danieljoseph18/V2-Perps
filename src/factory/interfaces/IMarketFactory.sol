// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IPriceFeed} from "../../oracle/interfaces/IPriceFeed.sol";
import {Pool} from "../../markets/Pool.sol";

interface IMarketFactory {
    event MarketFactoryInitialized(address priceStorage);
    event MarketCreated(address market, string ticker);
    event DefaultConfigSet();
    event MarketRequested(bytes32 indexed requestKey, string indexed indexTokenTicker);
    event AssetSupported(string indexed ticker);
    event AssetRequested(string indexed ticker);

    error MarketFactory_AlreadyInitialized();
    error MarketFactory_FailedToAddMarket();
    error MarketFactory_InvalidOwner();
    error MarketFactory_InvalidFee();
    error MarketFactory_RequestDoesNotExist();
    error MarketFactory_FailedToRemoveRequest();
    error MarketFactory_InvalidDecimals();
    error MarketFactory_InvalidTicker();
    error MarketFactory_SelfExecution();
    error MarketFactory_InvalidTimestamp();
    error MarketFactory_RequestExists();
    error MarketFactory_FailedToAddRequest();

    struct Request {
        Input input;
        uint48 requestTimestamp;
        address requester;
    }

    struct Input {
        bool isMultiAsset;
        string indexTokenTicker;
        string marketTokenName;
        string marketTokenSymbol;
        IPriceFeed.SecondaryStrategy strategy;
    }

    struct PythData {
        bytes32 id;
        bytes32[] merkleProof;
    }

    function initialize(
        Pool.Config memory _defaultConfig,
        address _priceFeed,
        address _referralStorage,
        address _positionManager,
        address _router,
        address _feeDistributor,
        address _feeReceiver,
        uint256 _marketCreationFee,
        uint256 _marketExecutionFee
    ) external;
    function setDefaultConfig(Pool.Config memory _defaultConfig) external;
    function updatePriceFeed(IPriceFeed _priceFeed) external;
    function createNewMarket(Input calldata _input) external payable;
    function executeMarketRequest(bytes32 _requestKey) external;
    function getRequest(bytes32 _requestKey) external view returns (Request memory);
    function marketCreationFee() external view returns (uint256);
    function markets(uint256 index) external view returns (address);
    function isMarket(address _market) external view returns (bool);
}
