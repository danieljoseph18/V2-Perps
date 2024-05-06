// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IMarket} from "./IMarket.sol";
import {ITradeStorage} from "../../positions/interfaces/ITradeStorage.sol";
import {Oracle} from "../../oracle/Oracle.sol";
import {IPriceFeed} from "../../oracle/interfaces/IPriceFeed.sol";
import {IVault} from "./IVault.sol";
import {Pool} from "../Pool.sol";
import {MarketId, MarketIdLibrary} from "../../types/MarketId.sol";
import {Execution} from "../../positions/Execution.sol";

interface IMarket {
    /**
     * ================ Errors ================
     */
    error Market_AccessDenied();
    error Market_InvalidKey();
    error Market_InvalidPoolOwner();
    error Market_TokenAlreadyExists();
    error Market_FailedToAddAssetId();
    error Market_FailedToRemoveAssetId();
    error Market_AlreadyInitialized();
    error Market_InvalidETHTransfer();
    error Market_InvalidBorrowScale();
    error Market_SingleAssetMarket();
    error Market_FailedToRemoveRequest();
    error Market_MaxAssetsReached();
    error Market_TokenDoesNotExist();
    error Market_MinimumAssetsReached();
    error Market_AllocationLength();
    error Market_InvalidCumulativeAllocation();
    error Market_InvalidAllocation();
    error Market_NotRequestOwner();
    error Market_RequestNotExpired();
    error Market_FailedToAddRequest();

    /**
     * ================ Events ================
     */
    event TokenAdded(bytes32 indexed assetId);
    event MarketConfigUpdated(bytes32 indexed assetId);
    event Market_Initialized();
    event FeesAccumulated(uint256 amount, bool _isLong);
    event RequestCanceled(bytes32 indexed key, address indexed caller);
    event RequestCreated(bytes32 indexed key, address indexed owner, address tokenIn, uint256 amountIn, bool isDeposit);

    function createRequest(
        MarketId _id,
        address _owner,
        address _transferToken, // Token In for Deposits, Out for Withdrawals
        uint256 _amountIn,
        uint256 _executionFee,
        bytes32 _priceRequestKey,
        bytes32 _pnlRequestKey,
        uint40 _stakeDuration,
        bool _reverseWrap,
        bool _isDeposit
    ) external payable;

    function cancelRequest(MarketId _id, bytes32 _requestKey, address _caller)
        external
        returns (address tokenOut, uint256 amountOut, bool shouldUnwrap);
    function executeDeposit(MarketId _id, IVault.ExecuteDeposit calldata _params) external returns (uint256);
    function executeWithdrawal(MarketId _id, IVault.ExecuteWithdrawal calldata _params) external;

    // Getter
    function getRequest(MarketId _id, bytes32 _key) external view returns (Pool.Input memory);
    function getRequestAtIndex(MarketId _id, uint256 _index) external view returns (Pool.Input memory);

    /**
     * ================ Functions ================
     */
    function initialize(address _tradeStorage, address _priceFeed, address _marketFactory) external;

    function initializePool(
        MarketId _id,
        Pool.Config memory _config,
        address _poolOwner,
        uint256 _borrowScale,
        address _marketToken,
        string memory _ticker,
        bool _isMultiAsset
    ) external;
    function updateMarketState(
        MarketId _id,
        string calldata _ticker,
        uint256 _sizeDelta,
        Execution.Prices memory _prices,
        bool _isLong,
        bool _isIncrease
    ) external;
    function updateImpactPool(MarketId _id, string calldata _ticker, int256 _priceImpactUsd) external;

    function tradeStorage() external view returns (ITradeStorage);
    function getVault(MarketId _id) external view returns (IVault);
    function getBorrowScale(MarketId _id) external view returns (uint256);
    function getAssetIds(MarketId _id) external view returns (bytes32[] memory);
    function getStorage(MarketId _id, string memory _ticker) external view returns (Pool.Storage memory);
    function getTickers(MarketId _id) external view returns (string[] memory);
    function FUNDING_VELOCITY_CLAMP() external view returns (uint64);
    function getConfig(MarketId _id, string calldata _ticker) external view returns (Pool.Config memory);
    function getCumulatives(MarketId _id, string calldata _ticker) external view returns (Pool.Cumulatives memory);
    function getImpactPool(MarketId _id, string calldata _ticker) external view returns (uint256);
    function getImpactValues(MarketId _id, string calldata _ticker) external view returns (int16, int16);
    function getLastUpdate(MarketId _id, string calldata _ticker) external view returns (uint48);
    function getFundingRates(MarketId _id, string calldata _ticker) external view returns (int64, int64);
    function getCumulativeBorrowFees(MarketId _id, string memory _ticker)
        external
        view
        returns (uint256 longCumulativeBorrowFees, uint256 shortCumulativeBorrowFees);
    function getCumulativeBorrowFee(MarketId _id, string memory _ticker, bool _isLong)
        external
        view
        returns (uint256);
    function getFundingAccrued(MarketId _id, string memory _ticker) external view returns (int256);
    function getBorrowingRate(MarketId _id, string memory _ticker, bool _isLong) external view returns (uint256);
    function getMaintenanceMargin(MarketId _id, string memory _ticker) external view returns (uint256);
    function getMaxLeverage(MarketId _id, string memory _ticker) external view returns (uint8);
    function getAllocation(MarketId _id, string memory _ticker) external view returns (uint8);
    function getOpenInterest(MarketId _id, string memory _ticker, bool _isLong) external view returns (uint256);
    function getAverageCumulativeBorrowFee(MarketId _id, string memory _ticker, bool _isLong)
        external
        view
        returns (uint256);
}
