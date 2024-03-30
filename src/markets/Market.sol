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
import {IMarketToken, IERC20} from "./interfaces/IMarketToken.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IWETH} from "../tokens/interfaces/IWETH.sol";
import {MarketUtils} from "./MarketUtils.sol";

contract Market is IMarket, RoleValidation, ReentrancyGuard {
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using SignedMath for int256;
    using SafeERC20 for IERC20;
    using SafeERC20 for IMarketToken;

    IMarketToken public immutable MARKET_TOKEN;

    address public tradeStorage;

    uint256 private constant BITMASK_16 = type(uint256).max >> (256 - 16);
    uint16 private constant TOTAL_ALLOCATION = 10000;
    // Max 100 assets per market (could fit 12 more in last uint256, but 100 used for simplicity)
    // Fits 16 allocations per uint256
    uint8 private constant MAX_ASSETS = 100;
    uint64 private constant SCALING_FACTOR = 1e18;
    uint64 private constant MIN_BORROW_SCALE = 0.0001e18; // 0.01% per day
    uint64 private constant MAX_BORROW_SCALE = 0.01e18; // 1% per day
    uint64 public constant BASE_FEE = 0.001e18; // 0.1%
    // Value = Max Bonus Fee
    // Users will be charged a % of this fee based on the skew of the market
    uint256 public constant FEE_SCALE = 0.01e18; // 1%

    // The rest of the 80% of the fees go to the FeeDistributor to distribute to LPs
    uint256 private constant FEES_TO_OWNER = 0.1e18; // 10% to Owner
    uint256 private constant FEES_TO_PROTOCOL = 0.1e18; // 10% to Protocol

    address private immutable WETH;
    address private immutable USDC;
    uint48 private constant TIME_TO_EXPIRATION = 1 minutes;
    uint256 private constant LONG_BASE_UNIT = 1e18;
    uint256 private constant SHORT_BASE_UNIT = 1e6;

    bool public isMultiAssetMarket;

    EnumerableSet.Bytes32Set private assetIds;
    bool private isInitialized;

    address private poolOwner;
    address private feeDistributor;
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

    // Store the Collateral Amount for each User
    mapping(address user => mapping(bool _isLong => uint256 collateralAmount)) public collateralAmounts;

    mapping(bytes32 key => Input request) private requests;
    EnumerableSet.Bytes32Set private requestKeys;

    // Each Asset's storage is tracked through this mapping
    mapping(bytes32 assetId => MarketStorage assetStorage) private marketStorage;

    modifier orderExists(bytes32 _key) {
        if (!requestKeys.contains(_key)) revert Market_InvalidKey();
        _;
    }

    modifier validAction(uint256 _amountIn, uint256 _amountOut, bool _isLongToken, bool _isDeposit) {
        // Cache the State Before
        State memory stateBefore = State({
            totalSupply: MARKET_TOKEN.totalSupply(),
            wethBalance: IERC20(WETH).balanceOf(address(this)),
            usdcBalance: IERC20(USDC).balanceOf(address(this))
        });
        _;
        // Cache the state after
        State memory stateAfter = State({
            totalSupply: MARKET_TOKEN.totalSupply(),
            wethBalance: IERC20(WETH).balanceOf(address(this)),
            usdcBalance: IERC20(USDC).balanceOf(address(this))
        });
        // Validate the Vault State Delta
        if (_isDeposit) {
            MarketUtils.validateDeposit(stateBefore, stateAfter, _amountIn, _isLongToken);
        } else {
            MarketUtils.validateWithdrawal(stateBefore, stateAfter, _amountIn, _amountOut, _isLongToken);
        }
    }

    /**
     *  ========================= Constructor  =========================
     */
    constructor(
        Config memory _tokenConfig,
        address _poolOwner,
        address _feeReceiver,
        address _feeDistributor,
        address _weth,
        address _usdc,
        address _marketToken,
        bytes32 _assetId,
        address _roleStorage
    ) RoleValidation(_roleStorage) {
        WETH = _weth;
        USDC = _usdc;
        MARKET_TOKEN = IMarketToken(_marketToken);
        poolOwner = _poolOwner;
        feeDistributor = _feeDistributor;
        feeReceiver = _feeReceiver;
        uint256[] memory allocations = new uint256[](1);
        allocations[0] = 10000 << 240;
        _addToken(_tokenConfig, _assetId, allocations);
    }

    receive() external payable {
        if (msg.sender != WETH) revert Market_InvalidETHTransfer();
    }

    function initialize(address _tradeStorage, uint256 _borrowScale) external onlyMarketMaker {
        if (isInitialized) revert Market_AlreadyInitialized();
        tradeStorage = _tradeStorage;
        borrowScale = _borrowScale;
        isInitialized = true;
        emit Market_Initialzied();
    }
    /**
     * ========================= Setter Functions  =========================
     */

    function transferPoolOwnership(address _newOwner) external {
        if (msg.sender != poolOwner || _newOwner == address(0)) revert Market_InvalidPoolOwner();
        poolOwner = _newOwner;
    }

    function addToken(Config memory _config, bytes32 _assetId, uint256[] calldata _newAllocations)
        external
        onlyMarketMaker
    {
        if (assetIds.length() >= MAX_ASSETS) revert Market_MaxAssetsReached();
        if (!isMultiAssetMarket) isMultiAssetMarket = true;
        _addToken(_config, _assetId, _newAllocations);
    }

    function removeToken(bytes32 _assetId, uint256[] calldata _newAllocations) external onlyAdmin {
        if (!assetIds.contains(_assetId)) revert Market_TokenDoesNotExist();
        uint256 len = assetIds.length();
        if (len == 1) revert Market_MinimumAssetsReached();
        if (!assetIds.remove(_assetId)) revert Market_FailedToRemoveAssetId();

        // If length after removal is 1, set isMultiAssetMarket to false
        if (len == 2) {
            isMultiAssetMarket = false;
            uint256[] memory allocations = new uint256[](1);
            allocations[0] = 10000 << 240;
            _setAllocationsWithBits(allocations);
        } else {
            _setAllocationsWithBits(_newAllocations);
        }

        delete marketStorage[_assetId];
        emit TokenRemoved(_assetId);
    }

    function updateFees(address _poolOwner, address _feeDistributor) external onlyConfigurator(address(this)) {
        if (_poolOwner == address(0)) revert Market_InvalidPoolOwner();
        if (_feeDistributor == address(0)) revert Market_InvalidFeeDistributor();
        poolOwner = _poolOwner;
        feeDistributor = _feeDistributor;
    }

    function updateBorrowScale(uint256 _borrowScale) external onlyConfigurator(address(this)) {
        if (_borrowScale < MIN_BORROW_SCALE || _borrowScale > MAX_BORROW_SCALE) revert Market_InvalidBorrowScale();
        borrowScale = _borrowScale;
    }

    /**
     * @dev Sensitive Function. Config must be validated before calling this function.
     * Unrealistic values may lead to unexpected behavior in the system.
     * Permissions restricted to only a super-user.
     */
    function updateConfig(Config memory _config, bytes32 _assetId) external onlyAdmin {
        marketStorage[_assetId].config = _config;
        emit MarketConfigUpdated(_assetId, _config);
    }

    /**
     * ========================= Market State Functions  =========================
     */
    function setAllocationsWithBits(uint256[] memory _allocations) external onlyStateKeeper {
        if (!isMultiAssetMarket) revert Market_SingleAssetMarket();
        _setAllocationsWithBits(_allocations);
    }

    function updateMarketState(
        bytes32 _assetId,
        uint256 _sizeDelta,
        uint256 _indexPrice,
        uint256 _impactedPrice,
        uint256 _collateralPrice,
        bool _isLong,
        bool _isIncrease
    ) external nonReentrant onlyTradeStorage(address(this)) {
        // 1. Depends on Open Interest Delta to determine Skew
        _updateFundingRate(_assetId, _indexPrice);
        if (_sizeDelta != 0) {
            // Use Impacted Price for Entry
            // 2. Relies on Open Interest Delta
            _updateWeightedAverages(
                _assetId,
                _impactedPrice == 0 ? _indexPrice : _impactedPrice, // If no price impact, set to the index price
                _isIncrease ? int256(_sizeDelta) : -int256(_sizeDelta),
                _isLong
            );
            // 3. Updated pre-borrowing rate if size delta > 0
            _updateOpenInterest(_assetId, _sizeDelta, _isLong, _isIncrease);
        }
        // 4. Relies on Updated Open interest
        _updateBorrowingRate(_assetId, _collateralPrice, _isLong ? LONG_BASE_UNIT : SHORT_BASE_UNIT, _isLong);
        // Fire Event
        emit MarketStateUpdated(_assetId, _isLong);
    }

    /**
     * ========================= Token Functions  =========================
     */
    function batchWithdrawFees() external onlyAdmin nonReentrant {
        uint256 longFees = longAccumulatedFees;
        uint256 shortFees = shortAccumulatedFees;
        longAccumulatedFees = 0;
        shortAccumulatedFees = 0;
        // calculate percentages and distribute percentage to owner and feeDistributor
        uint256 longOwnerFees = mulDiv(longFees, FEES_TO_OWNER, SCALING_FACTOR);
        uint256 shortOwnerFees = mulDiv(shortFees, FEES_TO_OWNER, SCALING_FACTOR);
        uint256 longDistributorFee = longFees - (longOwnerFees * 2); // 2 because 10% to owner and 10% to protocol
        uint256 shortDistributorFee = shortFees - (shortOwnerFees * 2);
        // send out fees
        IERC20(WETH).safeTransfer(poolOwner, longOwnerFees);
        IERC20(WETH).safeTransfer(feeReceiver, longOwnerFees);
        IERC20(WETH).safeTransfer(feeDistributor, longDistributorFee);
        IERC20(USDC).safeTransfer(poolOwner, shortOwnerFees);
        IERC20(USDC).safeTransfer(feeReceiver, shortOwnerFees);
        IERC20(USDC).safeTransfer(feeDistributor, shortDistributorFee);

        emit FeesWithdrawn(longFees, shortFees);
    }

    function transferOutTokens(address _to, uint256 _amount, bool _isLongToken, bool _shouldUnwrap)
        external
        onlyTradeStorage(address(this))
        nonReentrant
    {
        uint256 available =
            _isLongToken ? longTokenBalance - longTokensReserved : shortTokenBalance - shortTokensReserved;
        if (_amount > available) revert Market_InsufficientAvailableTokens();
        _transferOutTokens(_to, _amount, _isLongToken, _shouldUnwrap);
    }

    function accumulateFees(uint256 _amount, bool _isLong) external onlyTradeStorage(address(this)) {
        _accumulateFees(_amount, _isLong);
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
        onlyTradeStorage(address(this))
    {
        _updatePoolBalance(_amount, _isLong, _isIncrease);
    }

    function updateCollateralAmount(uint256 _amount, address _user, bool _isLong, bool _isIncrease)
        external
        onlyTradeStorage(address(this))
    {
        if (_isIncrease) {
            collateralAmounts[_user][_isLong] += _amount;
        } else {
            if (_amount > collateralAmounts[_user][_isLong]) revert Market_InsufficientCollateral();
            else collateralAmounts[_user][_isLong] -= _amount;
        }
    }

    function createRequest(
        address _owner,
        address _transferToken, // Token In for Deposits, Out for Withdrawals
        uint256 _amountIn,
        uint256 _executionFee,
        bool _reverseWrap,
        bool _isDeposit
    ) external payable onlyRouter {
        Input memory request = Input({
            amountIn: _amountIn,
            executionFee: _executionFee,
            owner: _owner,
            expirationTimestamp: uint48(block.timestamp) + TIME_TO_EXPIRATION,
            isLongToken: _transferToken == WETH,
            reverseWrap: _reverseWrap,
            isDeposit: _isDeposit,
            key: _generateKey(_owner, _transferToken, _amountIn, _isDeposit)
        });
        if (!requestKeys.add(request.key)) revert Market_FailedToAddRequest();
        requests[request.key] = request;
        emit RequestCreated(request.key, _owner, _transferToken, _amountIn, _isDeposit);
    }

    function cancelRequest(bytes32 _key, address _caller)
        external
        onlyPositionManager
        returns (address tokenOut, uint256 amountOut, bool shouldUnwrap)
    {
        // Check the Request Exists
        if (!requestKeys.contains(_key)) revert Market_InvalidKey();
        // Check the caller owns the request
        Input memory request = requests[_key];
        if (request.owner != _caller) revert Market_RequestNotOwner();
        // Ensure the request has passed the expiration time
        if (request.expirationTimestamp > block.timestamp) revert Market_RequestNotExpired();
        // Delete the request
        _deleteRequest(_key);
        // Remove the request key from the set
        if (!requestKeys.remove(_key)) revert Market_FailedToRemoveRequest();
        // Set Token Out and Should Unwrap
        if (request.isDeposit) {
            // If is deposit, token out is the token in
            tokenOut = request.isLongToken ? WETH : USDC;
            shouldUnwrap = request.reverseWrap;
        } else {
            // If is withdrawal, token out is market tokens
            tokenOut = address(MARKET_TOKEN);
            shouldUnwrap = false;
        }
        amountOut = request.amountIn;
        // Fire event
        emit RequestCanceled(_key, _caller);
    }

    function executeDeposit(ExecuteDeposit calldata _params)
        external
        onlyPositionManager
        orderExists(_params.key)
        nonReentrant
        validAction(_params.deposit.amountIn, 0, _params.deposit.isLongToken, true)
    {
        // Transfer deposit tokens from msg.sender
        address tokenIn = _params.deposit.isLongToken ? WETH : USDC;
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), _params.deposit.amountIn);
        // Delete Deposit Request
        _deleteRequest(_params.key);

        (uint256 afterFeeAmount, uint256 fee, uint256 mintAmount) = MarketUtils.calculateDepositAmounts(_params);

        // update storage
        _accumulateFees(fee, _params.deposit.isLongToken);
        _updatePoolBalance(afterFeeAmount, _params.deposit.isLongToken, true);

        emit DepositExecuted(_params.key, _params.deposit.owner, tokenIn, _params.deposit.amountIn, mintAmount);
        // mint tokens to user
        MARKET_TOKEN.mint(_params.deposit.owner, mintAmount);
    }

    function executeWithdrawal(ExecuteWithdrawal calldata _params)
        external
        onlyPositionManager
        orderExists(_params.key)
        nonReentrant
        validAction(_params.withdrawal.amountIn, _params.amountOut, _params.withdrawal.isLongToken, false)
    {
        // Transfer Market Tokens in from msg.sender
        MARKET_TOKEN.safeTransferFrom(msg.sender, address(this), _params.withdrawal.amountIn);
        // Delete the Withdrawal from Storage
        _deleteRequest(_params.key);

        // Calculate Fee
        (uint256 transferAmountOut, uint256 fee) = MarketUtils.calculateWithdrawalAmounts(_params);

        // Calculate amount out / aum before burning
        MARKET_TOKEN.burn(address(this), _params.withdrawal.amountIn);

        // accumulate the fee
        _accumulateFees(fee, _params.withdrawal.isLongToken);
        // validate whether the pool has enough tokens
        uint256 available = _params.withdrawal.isLongToken
            ? longTokenBalance - longTokensReserved
            : shortTokenBalance - shortTokensReserved;
        if (transferAmountOut > available) revert Market_InsufficientAvailableTokens();
        // decrease the pool
        _updatePoolBalance(_params.amountOut, _params.withdrawal.isLongToken, false);

        emit WithdrawalExecuted(
            _params.key,
            _params.withdrawal.owner,
            _params.withdrawal.isLongToken ? WETH : USDC,
            _params.withdrawal.amountIn,
            transferAmountOut
        );
        // transfer tokens to user
        _transferOutTokens(
            _params.withdrawal.owner, transferAmountOut, _params.withdrawal.isLongToken, _params.shouldUnwrap
        );
    }

    /**
     * ========================= Getter Functions  =========================
     */
    function getAssetIds() external view returns (bytes32[] memory) {
        return assetIds.values();
    }

    function isAssetInMarket(bytes32 _assetId) external view returns (bool) {
        return assetIds.contains(_assetId);
    }

    function getAssetsInMarket() external view returns (uint256) {
        return assetIds.length();
    }

    function getStorage(bytes32 _assetId) external view returns (MarketStorage memory) {
        return marketStorage[_assetId];
    }

    function getRequest(bytes32 _key) external view returns (Input memory) {
        return requests[_key];
    }

    function getRequestAtIndex(uint256 _index) external view returns (Input memory) {
        return requests[requestKeys.at(_index)];
    }

    function totalAvailableLiquidity(bool _isLong) external view returns (uint256 total) {
        total = _isLong ? longTokenBalance - longTokensReserved : shortTokenBalance - shortTokensReserved;
    }

    /**
     *  ========================= Internal Functions  =========================
     */
    function _updateFundingRate(bytes32 _assetId, uint256 _indexPrice) internal {
        FundingValues memory funding = marketStorage[_assetId].funding;
        marketStorage[_assetId].funding = Funding.updateState(this, funding, _assetId, _indexPrice);
    }

    function _updateBorrowingRate(bytes32 _assetId, uint256 _collateralPrice, uint256 _collateralBaseUnit, bool _isLong)
        internal
    {
        BorrowingValues memory borrowing = marketStorage[_assetId].borrowing;
        marketStorage[_assetId].borrowing =
            Borrowing.updateState(this, borrowing, _assetId, _collateralPrice, _collateralBaseUnit, _isLong);
    }

    /**
     * Updates the weighted average values for the market. Both rely on the market condition pre-open interest update.
     */
    function _updateWeightedAverages(bytes32 _assetId, uint256 _priceUsd, int256 _sizeDeltaUsd, bool _isLong)
        internal
    {
        if (_priceUsd == 0) revert Market_PriceIsZero();
        if (_sizeDeltaUsd == 0) return;

        PnlValues storage pnl = marketStorage[_assetId].pnl;
        uint256 openInterest;

        if (_isLong) {
            openInterest = marketStorage[_assetId].openInterest.longOpenInterest;
            pnl.longAverageEntryPriceUsd = MarketUtils.calculateWeightedAverageEntryPrice(
                pnl.longAverageEntryPriceUsd, openInterest, _sizeDeltaUsd, _priceUsd
            );
            marketStorage[_assetId].borrowing.weightedAvgCumulativeLong =
                Borrowing.getNextAverageCumulative(this, _assetId, _sizeDeltaUsd, true);
        } else {
            openInterest = marketStorage[_assetId].openInterest.shortOpenInterest;
            pnl.shortAverageEntryPriceUsd = MarketUtils.calculateWeightedAverageEntryPrice(
                pnl.shortAverageEntryPriceUsd, openInterest, _sizeDeltaUsd, _priceUsd
            );
            marketStorage[_assetId].borrowing.weightedAvgCumulativeShort =
                Borrowing.getNextAverageCumulative(this, _assetId, _sizeDeltaUsd, false);
        }
    }

    function _updateOpenInterest(bytes32 _assetId, uint256 _sizeDeltaUsd, bool _isLong, bool _shouldAdd) internal {
        // Update the open interest
        if (_shouldAdd) {
            _isLong
                ? marketStorage[_assetId].openInterest.longOpenInterest += _sizeDeltaUsd
                : marketStorage[_assetId].openInterest.shortOpenInterest += _sizeDeltaUsd;
        } else {
            _isLong
                ? marketStorage[_assetId].openInterest.longOpenInterest -= _sizeDeltaUsd
                : marketStorage[_assetId].openInterest.shortOpenInterest -= _sizeDeltaUsd;
        }
    }

    function updateImpactPool(bytes32 _assetId, int256 _priceImpactUsd) external onlyTradeStorage(address(this)) {
        _priceImpactUsd > 0
            ? marketStorage[_assetId].impactPool += _priceImpactUsd.abs()
            : marketStorage[_assetId].impactPool -= _priceImpactUsd.abs();
    }

    function _setAllocationsWithBits(uint256[] memory _allocations) internal {
        bytes32[] memory assets = assetIds.values();
        uint256 assetLen = assets.length;
        uint256 total;
        uint256 len = _allocations.length;
        for (uint256 i = 0; i < len;) {
            uint256 allocation = _allocations[i];
            for (uint256 j = 0; j < 16 && i * 16 + j < assetLen;) {
                uint256 allocationValue = (allocation >> (240 - j * 16)) & BITMASK_16;
                total += allocationValue;
                marketStorage[assets[i * 16 + j]].allocationPercentage = allocationValue;
                unchecked {
                    ++j;
                }
            }
            unchecked {
                ++i;
            }
        }

        if (total != TOTAL_ALLOCATION) revert Market_InvalidCumulativeAllocation();
    }

    function _addToken(Config memory _config, bytes32 _assetId, uint256[] memory _newAllocations) internal {
        if (assetIds.contains(_assetId)) revert Market_TokenAlreadyExists();
        if (!assetIds.add(_assetId)) revert Market_FailedToAddAssetId();
        _setAllocationsWithBits(_newAllocations);
        marketStorage[_assetId].config = _config;
        marketStorage[_assetId].funding.lastFundingUpdate = uint48(block.timestamp);
        marketStorage[_assetId].borrowing.lastBorrowUpdate = uint48(block.timestamp);
        emit TokenAdded(_assetId, _config);
    }

    function _deleteRequest(bytes32 _key) internal {
        if (!requestKeys.remove(_key)) revert Market_FailedToRemoveRequest();
        delete requests[_key];
    }

    function _accumulateFees(uint256 _amount, bool _isLong) internal {
        _isLong ? longAccumulatedFees += _amount : shortAccumulatedFees += _amount;
    }

    function _updatePoolBalance(uint256 _amount, bool _isLong, bool _isIncrease) internal {
        if (_isIncrease) {
            _isLong ? longTokenBalance += _amount : shortTokenBalance += _amount;
        } else {
            _isLong ? longTokenBalance -= _amount : shortTokenBalance -= _amount;
        }
    }

    function _transferOutTokens(address _to, uint256 _amount, bool _isLongToken, bool _shouldUnwrap) internal {
        if (_isLongToken) {
            if (_shouldUnwrap) {
                IWETH(WETH).withdraw(_amount);
                (bool success,) = _to.call{value: _amount}("");
                if (!success) revert Market_FailedToTransferETH();
            } else {
                IERC20(WETH).safeTransfer(_to, _amount);
            }
        } else {
            IERC20(USDC).safeTransfer(_to, _amount);
        }
    }

    function _generateKey(address _owner, address _tokenIn, uint256 _tokenAmount, bool _isDeposit)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(_owner, _tokenIn, _tokenAmount, _isDeposit));
    }
}
