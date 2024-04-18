// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IMarket} from "./interfaces/IMarket.sol";
import {RoleValidation} from "../access/RoleValidation.sol";
import {Funding} from "../libraries/Funding.sol";
import {Borrowing} from "../libraries/Borrowing.sol";
import {ReentrancyGuard} from "@solmate/utils/ReentrancyGuard.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {mulDiv} from "@prb/math/Common.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {EnumerableMap} from "../libraries/EnumerableMap.sol";
import {IMarketToken, IERC20} from "./interfaces/IMarketToken.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IWETH} from "../tokens/interfaces/IWETH.sol";
import {MarketUtils} from "./MarketUtils.sol";
import {IPriceFeed} from "../oracle/interfaces/IPriceFeed.sol";
import {ITradeStorage} from "../positions/interfaces/ITradeStorage.sol";
import {IRewardTracker} from "../rewards/interfaces/IRewardTracker.sol";
import {IFeeDistributor} from "../rewards/interfaces/IFeeDistributor.sol";
import {MarketLogic} from "./MarketLogic.sol";

contract Market is IMarket, RoleValidation, ReentrancyGuard {
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using EnumerableMap for EnumerableMap.MarketRequestMap;
    using SignedMath for int256;
    using SafeERC20 for IERC20;
    using SafeERC20 for IMarketToken;

    IMarketToken public immutable MARKET_TOKEN;
    IRewardTracker public rewardTracker;
    IFeeDistributor public feeDistributor;

    address public tradeStorage;

    uint64 private constant MIN_BORROW_SCALE = 0.0001e18; // 0.01% per day
    uint64 private constant MAX_BORROW_SCALE = 0.01e18; // 1% per day
    /**
     * Level of pSkew beyond which funding rate starts to change
     * Units: % Per Day
     */
    uint64 public constant FUNDING_VELOCITY_CLAMP = 0.00001e18; // 0.001% per day

    address private immutable WETH;
    address private immutable USDC;

    EnumerableSet.Bytes32Set private assetIds;
    bool private isInitialized;

    // Owner / Configurator of the Pool
    address private poolOwner;
    // Address for the protocol to receive 10% of fees to
    address private feeReceiver;

    uint256 private longAccumulatedFees;
    uint256 private shortAccumulatedFees;

    uint256 public longTokenBalance;
    uint256 public shortTokenBalance;
    uint256 public longTokensReserved;
    uint256 public shortTokensReserved;
    /**
     * Maximum borrowing fee per day as a percentage.
     * The current borrowing fee will fluctuate along this scale,
     * based on the open interest to max open interest ratio.
     */
    uint256 public borrowScale;

    string[] private tickers;

    // Store the Collateral Amount for each User
    mapping(address user => mapping(bool _isLong => uint256 collateralAmount)) public collateralAmounts;

    EnumerableMap.MarketRequestMap private requests;

    // Each Asset's storage is tracked through this mapping
    mapping(bytes32 assetId => MarketStorage assetStorage) private marketStorage;

    modifier orderExists(bytes32 _key) {
        _orderExists(_key);
        _;
    }

    /**
     *  ========================= Constructor  =========================
     */
    constructor(
        Config memory _config,
        address _poolOwner,
        address _feeReceiver,
        address _feeDistributor,
        address _weth,
        address _usdc,
        address _marketToken,
        string memory _ticker,
        address _roleStorage
    ) RoleValidation(_roleStorage) {
        WETH = _weth;
        USDC = _usdc;
        MARKET_TOKEN = IMarketToken(_marketToken);
        poolOwner = _poolOwner;
        feeDistributor = IFeeDistributor(_feeDistributor);
        feeReceiver = _feeReceiver;
        bytes32 assetId = MarketUtils.generateAssetId(_ticker);
        if (assetIds.contains(assetId)) revert Market_TokenAlreadyExists();
        if (!assetIds.add(assetId)) revert Market_FailedToAddAssetId();
        // Add Ticker
        tickers.push(_ticker);
        // Initialize Storage
        marketStorage[assetId].allocationShare = 100;
        marketStorage[assetId].config = _config;
        marketStorage[assetId].funding.lastFundingUpdate = uint48(block.timestamp);
        marketStorage[assetId].borrowing.lastBorrowUpdate = uint48(block.timestamp);
        emit TokenAdded(assetId);
    }

    receive() external payable {
        // Only accept ETH via fallback from the WETH contract when unwrapping WETH
        // Ensure that the call depth is 1 (direct call from WETH contract)
        if (msg.sender != WETH || gasleft() <= 2300) revert Market_InvalidETHTransfer();
    }

    function initialize(address _tradeStorage, address _rewardTracker, uint256 _borrowScale)
        external
        onlyMarketFactory
    {
        if (isInitialized) revert Market_AlreadyInitialized();
        tradeStorage = _tradeStorage;
        rewardTracker = IRewardTracker(_rewardTracker);
        borrowScale = _borrowScale;
        isInitialized = true;
        emit Market_Initialized();
    }
    /**
     * ========================= Setter Functions  =========================
     */

    function transferPoolOwnership(address _newOwner) external {
        if (msg.sender != poolOwner || _newOwner == address(0)) revert Market_InvalidPoolOwner();
        poolOwner = _newOwner;
    }

    function updateFeeDistributor(IFeeDistributor _feeDistributor) external onlyAdmin {
        if (address(_feeDistributor) == address(0)) revert Market_InvalidFeeDistributor();
        feeDistributor = _feeDistributor;
    }

    function updateBorrowScale(uint256 _borrowScale) external onlyConfigurator(address(this)) {
        if (_borrowScale < MIN_BORROW_SCALE || _borrowScale > MAX_BORROW_SCALE) revert Market_InvalidBorrowScale();
        borrowScale = _borrowScale;
    }

    function updateConfig(Config calldata _config, string calldata _ticker) external {
        MarketLogic.validateConfig(_config);
        bytes32 assetId = keccak256(abi.encode(_ticker));
        marketStorage[assetId].config = _config;
        emit MarketConfigUpdated(assetId);
    }

    /**
     * ========================= Deposit / Withdrawal Functions  =========================
     */
    function createRequest(
        address _owner,
        address _transferToken, // Token In for Deposits, Out for Withdrawals
        uint256 _amountIn,
        uint256 _executionFee,
        bytes32 _priceRequestKey,
        bytes32 _pnlRequestKey,
        bool _reverseWrap,
        bool _isDeposit
    ) external payable onlyRouter {
        MarketLogic.createRequest(
            requests,
            _owner,
            _transferToken,
            _amountIn,
            _executionFee,
            _priceRequestKey,
            _pnlRequestKey,
            WETH,
            _reverseWrap,
            _isDeposit
        );
    }

    function cancelRequest(bytes32 _key, address _caller)
        external
        onlyPositionManager
        returns (address tokenOut, uint256 amountOut, bool shouldUnwrap)
    {
        return MarketLogic.cancelRequest(requests, _key, _caller, WETH, USDC, address(MARKET_TOKEN));
    }

    function executeDeposit(ExecuteDeposit calldata _params)
        external
        onlyPositionManager
        orderExists(_params.key)
        nonReentrant
    {
        MarketLogic.executeDeposit(requests, _params, _params.deposit.isLongToken ? WETH : USDC);
    }

    function executeWithdrawal(ExecuteWithdrawal calldata _params)
        external
        onlyPositionManager
        orderExists(_params.key)
        nonReentrant
    {
        if (_params.withdrawal.isLongToken) {
            MarketLogic.executeWithdrawal(requests, _params, WETH, longTokenBalance - longTokensReserved);
        } else {
            MarketLogic.executeWithdrawal(requests, _params, USDC, shortTokenBalance - shortTokensReserved);
        }
    }

    /**
     * ========================= Callback Functions  =========================
     */
    function setAllocationShare(string calldata, uint256) external onlyCallback {
        // Redundant action to prevent compiler warning
        delete marketStorage[bytes32(0)].allocationShare;
        revert Market_SingleAssetMarket();
    }

    function addAsset(string calldata) external onlyCallback {
        // Redundant action to prevent compiler warning
        delete marketStorage[bytes32(0)].allocationShare;
        revert Market_SingleAssetMarket();
    }

    function removeAsset(string calldata) external onlyCallback {
        // Redundant action to prevent compiler warning
        delete marketStorage[bytes32(0)].allocationShare;
        revert Market_SingleAssetMarket();
    }

    /**
     * ========================= External State Functions  =========================
     */
    function updateMarketState(
        string calldata _ticker,
        uint256 _sizeDelta,
        uint256 _indexPrice,
        uint256 _impactedPrice,
        uint256 _collateralPrice,
        uint256 _collateralBaseUnit,
        bool _isLong,
        bool _isIncrease
    ) external nonReentrant onlyTradeStorage(address(this)) {
        MarketStorage storage self = marketStorage[keccak256(abi.encode(_ticker))];
        MarketLogic.updateMarketState(
            self,
            _ticker,
            _sizeDelta,
            _indexPrice,
            _impactedPrice,
            _collateralPrice,
            _collateralBaseUnit,
            _isLong,
            _isIncrease
        );
    }

    /**
     * ========================= Token Functions  =========================
     */
    function batchWithdrawFees() external onlyConfigurator(address(this)) nonReentrant {
        uint256 longFees = longAccumulatedFees;
        uint256 shortFees = shortAccumulatedFees;
        longAccumulatedFees = 0;
        shortAccumulatedFees = 0;
        MarketLogic.batchWithdrawFees(WETH, USDC, address(feeDistributor), feeReceiver, poolOwner, longFees, shortFees);
    }

    function transferOutTokens(address _to, uint256 _amount, bool _isLongToken, bool _shouldUnwrap)
        external
        onlyTradeStorage(address(this))
        nonReentrant
    {
        if (_isLongToken) {
            MarketLogic.transferOutTokens(
                _to, WETH, _amount, longTokenBalance - longTokensReserved, true, _shouldUnwrap
            );
        } else {
            MarketLogic.transferOutTokens(
                _to, USDC, _amount, shortTokenBalance - shortTokensReserved, false, _shouldUnwrap
            );
        }
    }

    function accumulateFees(uint256 _amount, bool _isLong) external onlyTradeStorageOrMarket(address(this)) {
        _isLong ? longAccumulatedFees += _amount : shortAccumulatedFees += _amount;
        emit FeesAccumulated(_amount, _isLong);
    }

    function updateLiquidityReservation(uint256 _amount, bool _isLong, bool _isIncrease)
        external
        onlyTradeStorage(address(this))
    {
        if (_isIncrease) {
            _isLong ? longTokensReserved += _amount : shortTokensReserved += _amount;
        } else {
            if (_isLong) {
                if (_amount > longTokensReserved) longTokensReserved = 0;
                else longTokensReserved -= _amount;
            } else {
                if (_amount > shortTokensReserved) shortTokensReserved = 0;
                else shortTokensReserved -= _amount;
            }
        }
    }

    function updatePoolBalance(uint256 _amount, bool _isLong, bool _isIncrease)
        external
        onlyTradeStorageOrMarket(address(this))
    {
        if (_isIncrease) {
            _isLong ? longTokenBalance += _amount : shortTokenBalance += _amount;
        } else {
            _isLong ? longTokenBalance -= _amount : shortTokenBalance -= _amount;
        }
    }

    /**
     * Store the amount of collateral the user provided for their position.
     * This is used to handle the accounting of collateral as it can fluctuate in value.
     *
     * Position collateral is a snapshot of the amount of collateral held by the position at
     * entry, so stays constant.
     *
     * Any excess collateral will be absorbed by the pool.
     * Any deficit will be taken from the pool.
     */
    function updateCollateralAmount(uint256 _amount, address _user, bool _isLong, bool _isIncrease, bool _isFullClose)
        external
        onlyTradeStorage(address(this))
    {
        if (_isIncrease) {
            // Case 1: Increase the collateral amount
            collateralAmounts[_user][_isLong] += _amount;
        } else {
            // Case 2: Decrease the collateral amount
            uint256 currentCollateral = collateralAmounts[_user][_isLong];

            if (_amount > currentCollateral) {
                // Amount to decrease is greater than stored collateral
                uint256 excess = _amount - currentCollateral;
                collateralAmounts[_user][_isLong] = 0;
                // Subtract the extra amount from the pool
                _isLong ? longTokenBalance -= excess : shortTokenBalance -= excess;
            } else {
                // Amount to decrease is less than or equal to stored collateral
                collateralAmounts[_user][_isLong] -= _amount;
            }

            if (_isFullClose) {
                // Transfer any remaining collateral to the pool
                uint256 remaining = collateralAmounts[_user][_isLong];
                if (remaining > 0) {
                    collateralAmounts[_user][_isLong] = 0;
                    _isLong ? longTokenBalance += remaining : shortTokenBalance += remaining;
                }
            }
        }
    }

    function updateImpactPool(string calldata _ticker, int256 _priceImpactUsd)
        external
        onlyTradeStorage(address(this))
    {
        bytes32 assetId = keccak256(abi.encode(_ticker));
        _priceImpactUsd > 0
            ? marketStorage[assetId].impactPool += _priceImpactUsd.abs()
            : marketStorage[assetId].impactPool -= _priceImpactUsd.abs();
    }

    /**
     * ========================= Private Functions  =========================
     */
    function _orderExists(bytes32 _key) private view {
        if (!requests.contains(_key)) revert Market_InvalidKey();
    }

    /**
     * ========================= Getter Functions  =========================
     */
    function getAssetIds() external view returns (bytes32[] memory) {
        return assetIds.values();
    }

    function isAssetInMarket(string calldata _ticker) external view returns (bool) {
        bytes32 assetId = keccak256(abi.encode(_ticker));
        return assetIds.contains(assetId);
    }

    function getAssetsInMarket() external view returns (uint256) {
        return assetIds.length();
    }

    function getStorage(string calldata _ticker) external view returns (MarketStorage memory) {
        bytes32 assetId = keccak256(abi.encode(_ticker));
        return marketStorage[assetId];
    }

    function getConfig(string calldata _ticker) external view returns (Config memory) {
        bytes32 assetId = keccak256(abi.encode(_ticker));
        return marketStorage[assetId].config;
    }

    function getFundingValues(string calldata _ticker) external view returns (FundingValues memory) {
        bytes32 assetId = keccak256(abi.encode(_ticker));
        return marketStorage[assetId].funding;
    }

    function getBorrowingValues(string calldata _ticker) external view returns (BorrowingValues memory) {
        bytes32 assetId = keccak256(abi.encode(_ticker));
        return marketStorage[assetId].borrowing;
    }

    function getOpenInterestValues(string calldata _ticker) external view returns (OpenInterestValues memory) {
        bytes32 assetId = keccak256(abi.encode(_ticker));
        return marketStorage[assetId].openInterest;
    }

    function getPnlValues(string calldata _ticker) external view returns (PnlValues memory) {
        bytes32 assetId = keccak256(abi.encode(_ticker));
        return marketStorage[assetId].pnl;
    }

    function getImpactPool(string calldata _ticker) external view returns (uint256) {
        bytes32 assetId = keccak256(abi.encode(_ticker));
        return marketStorage[assetId].impactPool;
    }

    function getAllocationShare(string calldata _ticker) external view returns (uint256) {
        bytes32 assetId = keccak256(abi.encode(_ticker));
        return marketStorage[assetId].allocationShare;
    }

    function getRequest(bytes32 _key) external view returns (Input memory) {
        return requests.get(_key);
    }

    function getRequestAtIndex(uint256 _index) external view returns (Input memory request) {
        (, request) = requests.at(_index);
    }

    function totalAvailableLiquidity(bool _isLong) external view returns (uint256 total) {
        total = _isLong ? longTokenBalance - longTokensReserved : shortTokenBalance - shortTokensReserved;
    }

    function getTickers() external view returns (string[] memory) {
        return tickers;
    }

    function requestExists(bytes32 _key) external view returns (bool) {
        return requests.contains(_key);
    }

    function getState(bool _isLong) external view returns (State memory) {
        if (_isLong) {
            return State({
                totalSupply: MARKET_TOKEN.totalSupply(),
                wethBalance: IERC20(WETH).balanceOf(address(this)),
                usdcBalance: IERC20(USDC).balanceOf(address(this)),
                accumulatedFees: longAccumulatedFees,
                poolBalance: longTokenBalance
            });
        } else {
            return State({
                totalSupply: MARKET_TOKEN.totalSupply(),
                wethBalance: IERC20(WETH).balanceOf(address(this)),
                usdcBalance: IERC20(USDC).balanceOf(address(this)),
                accumulatedFees: shortAccumulatedFees,
                poolBalance: shortTokenBalance
            });
        }
    }
}
