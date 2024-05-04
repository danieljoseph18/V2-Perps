// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IMarket} from "./IMarket.sol";
import {Oracle} from "../../oracle/Oracle.sol";
import {IPriceFeed} from "../../oracle/interfaces/IPriceFeed.sol";
import {IVault} from "./IVault.sol";
import {Pool} from "../Pool.sol";

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

    function cancelRequest(bytes32 _key, address _caller)
        external
        returns (address tokenOut, uint256 amountOut, bool shouldUnwrap);
    function executeDeposit(IVault.ExecuteDeposit calldata _params) external returns (uint256);
    function executeWithdrawal(IVault.ExecuteWithdrawal calldata _params) external;

    // Getter
    function getRequest(bytes32 _key) external view returns (Pool.Input memory);
    function getRequestAtIndex(uint256 _index) external view returns (Pool.Input memory);

    /**
     * ================ Functions ================
     */
    function initialize(address _tradeStorage, uint256 _borrowScale) external;
    function updateMarketState(
        string calldata _ticker,
        uint256 _sizeDelta,
        uint256 _indexPrice,
        uint256 _impactedPrice,
        uint256 _collateralPrice,
        uint256 _collateralBaseUnit,
        bool _isLong,
        bool _isIncrease
    ) external;
    function updateImpactPool(string memory _ticker, int256 _priceImpactUsd) external;

    function tradeStorage() external view returns (address);
    function VAULT() external view returns (IVault);
    function borrowScale() external view returns (uint256);
    function getAssetIds() external view returns (bytes32[] memory);
    function getStorage(string memory _ticker) external view returns (Pool.Storage memory);
    function getTickers() external view returns (string[] memory);
    function FUNDING_VELOCITY_CLAMP() external view returns (uint64);
    function getConfig(string calldata _ticker) external view returns (Pool.Config memory);
    function getCumulatives(string calldata _ticker) external view returns (Pool.Cumulatives memory);
    function getImpactPool(string calldata _ticker) external view returns (uint256);
    function getImpactValues(string calldata _ticker) external view returns (int16, int16, int16, int16);
    function getLastUpdate(string calldata _ticker) external view returns (uint48);
    function getFundingRates(string calldata _ticker) external view returns (int64, int64);
    function getCumulativeBorrowFees(string memory _ticker)
        external
        view
        returns (uint256 longCumulativeBorrowFees, uint256 shortCumulativeBorrowFees);
    function getCumulativeBorrowFee(string memory _ticker, bool _isLong) external view returns (uint256);
    function getFundingAccrued(string memory _ticker) external view returns (int256);
    function getBorrowingRate(string memory _ticker, bool _isLong) external view returns (uint256);
    function getMaintenanceMargin(string memory _ticker) external view returns (uint256);
    function getMaxLeverage(string memory _ticker) external view returns (uint8);
    function getAllocation(string memory _ticker) external view returns (uint8);
    function getOpenInterest(string memory _ticker, bool _isLong) external view returns (uint256);
    function getAverageCumulativeBorrowFee(string memory _ticker, bool _isLong) external view returns (uint256);
}
