// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IMarket} from "./IMarket.sol";
import {Oracle} from "../../oracle/Oracle.sol";
import {IPriceFeed} from "../../oracle/interfaces/IPriceFeed.sol";
import {IVault} from "./IVault.sol";
import {IRewardTracker} from "../../rewards/interfaces/IRewardTracker.sol";
import {Pool} from "../Pool.sol";

interface IMarket {
    /**
     * ================ Structs ================
     */
    struct Input {
        uint256 amountIn;
        uint256 executionFee;
        address owner;
        uint48 requestTimestamp;
        bool isLongToken;
        bool reverseWrap;
        bool isDeposit;
        bytes32 key;
        bytes32 priceRequestKey; // Key of the price update request
        bytes32 pnlRequestKey; // Id of the cumulative pnl request
    }

    /**
     * ================ Errors ================
     */
    error Market_InvalidKey();
    error Market_InvalidPoolOwner();
    error Market_InvalidFeeDistributor();
    error Market_TokenAlreadyExists();
    error Market_FailedToAddAssetId();
    error Market_FailedToRemoveAssetId();
    error Market_AlreadyInitialized();
    error Market_InvalidETHTransfer();
    error Market_InvalidBorrowScale();
    error Market_SingleAssetMarket();
    error Market_FailedToRemoveRequest();

    /**
     * ================ Events ================
     */
    event TokenAdded(bytes32 indexed assetId);
    event MarketConfigUpdated(bytes32 indexed assetId);
    event Market_Initialized();
    event FeesAccumulated(uint256 amount, bool _isLong);

    function createRequest(
        address _owner,
        address _transferToken, // Token In for Deposits, Out for Withdrawals
        uint256 _amountIn,
        uint256 _executionFee,
        bytes32 _priceRequestKey,
        bytes32 _pnlRequestKey,
        bool _reverseWrap,
        bool _isDeposit
    ) external payable;

    function cancelRequest(bytes32 _key, address _caller)
        external
        returns (address tokenOut, uint256 amountOut, bool shouldUnwrap);
    function executeDeposit(IVault.ExecuteDeposit calldata _params) external;
    function executeWithdrawal(IVault.ExecuteWithdrawal calldata _params) external;

    // Getter
    function totalAvailableLiquidity(bool _isLong) external view returns (uint256 total);
    function getRequest(bytes32 _key) external view returns (Input memory);
    function getRequestAtIndex(uint256 _index) external view returns (Input memory);
    function rewardTracker() external view returns (IRewardTracker);

    /**
     * ================ Functions ================
     */
    function initialize(address _tradeStorage, address _rewardTracker, uint256 _borrowScale) external;
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
    function getAssetsInMarket() external view returns (uint256);
    function getStorage(string memory _ticker) external view returns (Pool.Storage memory);
    function longTokenBalance() external view returns (uint256);
    function shortTokenBalance() external view returns (uint256);
    function longTokensReserved() external view returns (uint256);
    function shortTokensReserved() external view returns (uint256);
    function isAssetInMarket(string memory _ticker) external view returns (bool);
    function getTickers() external view returns (string[] memory);
    function FUNDING_VELOCITY_CLAMP() external view returns (uint64);
    function requestExists(bytes32 _key) external view returns (bool);
    function setAllocationShare(string calldata _ticker, uint8 _allocationShare) external;
    function addAsset(string calldata _ticker) external;
    function removeAsset(string calldata _ticker) external;
    function getConfig(string calldata _ticker) external view returns (Pool.Config memory);
    function getCumulatives(string calldata _ticker) external view returns (Pool.Cumulatives memory);
    function getImpactPool(string calldata _ticker) external view returns (uint256);
    function getImpactValues(string calldata _ticker) external view returns (int16, int16, int16, int16);
    function getOpenInterestValues(string calldata _ticker) external view returns (uint256, uint256);
    function getAllocationShare(string calldata _ticker) external view returns (uint8);
}
