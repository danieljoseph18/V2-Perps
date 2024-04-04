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
import {IPriceFeed} from "../oracle/interfaces/IPriceFeed.sol";
import {ITradeStorage} from "../positions/interfaces/ITradeStorage.sol";
import {IRewardTracker} from "../rewards/interfaces/IRewardTracker.sol";
import {IFeeDistributor} from "../rewards/interfaces/IFeeDistributor.sol";

// @audit - optimize. Can probably remove some stuff
contract Market is IMarket, RoleValidation, ReentrancyGuard {
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using SignedMath for int256;
    using SafeERC20 for IERC20;
    using SafeERC20 for IMarketToken;

    IMarketToken public immutable MARKET_TOKEN;
    IRewardTracker public rewardTracker;
    IFeeDistributor public feeDistributor;

    address public tradeStorage;

    uint32 private constant MIN_LEVERAGE = 100; // Min 1x Leverage
    uint32 private constant MAX_LEVERAGE = 1000_00; // Max 1000x leverage
    uint64 private constant MIN_RESERVE_FACTOR = 0.1e18; // 10% reserve factor
    uint64 private constant MAX_RESERVE_FACTOR = 0.5e18; // 50% reserve factor
    uint64 private constant SCALING_FACTOR = 1e18;
    uint64 private constant MIN_BORROW_SCALE = 0.0001e18; // 0.01% per day
    uint64 private constant MAX_BORROW_SCALE = 0.01e18; // 1% per day
    uint64 public constant BASE_FEE = 0.001e18; // 0.1%
    int64 private constant MIN_VELOCITY = 0.001e18; // 0.1% per day
    int64 private constant MAX_VELOCITY = 0.2e18; // 20% per day
    int256 private constant MIN_SKEW_SCALE = 1000e30; // $1000
    int256 private constant MAX_SKEW_SCALE = 10_000_000_000e30; // $10 Bn
    int64 private constant SIGNED_SCALAR = 1e18;
    string private constant LONG_TICKER = "ETH";
    string private constant SHORT_TICKER = "USDC";
    /**
     * Level of pSkew beyond which funding rate starts to change
     * Units: % Per Day
     */
    uint64 public constant FUNDING_VELOCITY_CLAMP = 0.00001e18; // 0.001% per day
    /**
     * Maximum PNL:POOL ratio before ADL is triggered.
     */
    uint64 public constant MAX_PNL_FACTOR = 0.45e18; // 45%
    uint64 public constant MAX_ADL_PERCENTAGE = 0.5e18; // Can only ADL up to 50% of a position
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

    EnumerableSet.Bytes32Set private assetIds;
    bool private isInitialized;

    address private poolOwner;
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
        State memory initialState = State({
            totalSupply: MARKET_TOKEN.totalSupply(),
            wethBalance: IERC20(WETH).balanceOf(address(this)),
            usdcBalance: IERC20(USDC).balanceOf(address(this))
        });
        _;
        // Cache the state after
        State memory updatedState = State({
            totalSupply: MARKET_TOKEN.totalSupply(),
            wethBalance: IERC20(WETH).balanceOf(address(this)),
            usdcBalance: IERC20(USDC).balanceOf(address(this))
        });
        // Validate the Vault State Delta
        if (_isDeposit) {
            MarketUtils.validateDeposit(initialState, updatedState, _amountIn, _isLongToken);
        } else {
            MarketUtils.validateWithdrawal(initialState, updatedState, _amountIn, _amountOut, _isLongToken);
        }
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
        marketStorage[assetId].allocationPercentage = 1e18;
        marketStorage[assetId].config = _config;
        marketStorage[assetId].funding.lastFundingUpdate = uint48(block.timestamp);
        marketStorage[assetId].borrowing.lastBorrowUpdate = uint48(block.timestamp);
        emit TokenAdded(assetId);
    }

    receive() external payable {
        if (msg.sender != WETH) revert Market_InvalidETHTransfer();
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
        emit Market_Initialzied();
    }
    /**
     * ========================= Setter Functions  =========================
     */

    function transferPoolOwnership(address _newOwner) external {
        if (msg.sender != poolOwner || _newOwner == address(0)) revert Market_InvalidPoolOwner();
        poolOwner = _newOwner;
    }

    function transferOwnership(address _newPoolOwner) external {
        if (msg.sender != poolOwner || _newPoolOwner == address(0)) revert Market_InvalidPoolOwner();
        poolOwner = _newPoolOwner;
        emit PoolOwnershipTransferred(_newPoolOwner);
    }

    function updateFeeDistributor(IFeeDistributor _feeDistributor) external onlyAdmin {
        if (address(_feeDistributor) == address(0)) revert Market_InvalidFeeDistributor();
        feeDistributor = _feeDistributor;
    }

    function updateBorrowScale(uint256 _borrowScale) external onlyConfigurator(address(this)) {
        if (_borrowScale < MIN_BORROW_SCALE || _borrowScale > MAX_BORROW_SCALE) revert Market_InvalidBorrowScale();
        borrowScale = _borrowScale;
    }

    function updateConfig(Config calldata _config, string calldata _ticker) external onlyConfigurator(address(this)) {
        _validateConfig(_config);
        bytes32 assetId = keccak256(abi.encode(_ticker));
        marketStorage[assetId].config = _config;
        emit MarketConfigUpdated(assetId);
    }

    /**
     * ========================= Market State Functions  =========================
     */
    function updateMarketState(
        string calldata _ticker,
        uint256 _sizeDelta,
        uint256 _indexPrice,
        uint256 _impactedPrice,
        uint256 _collateralPrice,
        uint256 _indexBaseUnit,
        bool _isLong,
        bool _isIncrease
    ) external nonReentrant onlyTradeStorage(address(this)) {
        // If invalid ticker, revert
        if (!assetIds.contains(keccak256(abi.encode(_ticker)))) revert Market_InvalidTicker();
        // 1. Depends on Open Interest Delta to determine Skew
        _updateFundingRate(_ticker, _indexPrice);
        if (_sizeDelta != 0) {
            // Use Impacted Price for Entry
            // 2. Relies on Open Interest Delta
            _updateWeightedAverages(
                _ticker,
                _impactedPrice == 0 ? _indexPrice : _impactedPrice, // If no price impact, set to the index price
                _isIncrease ? int256(_sizeDelta) : -int256(_sizeDelta),
                _isLong
            );
            // 3. Updated pre-borrowing rate if size delta > 0
            _updateOpenInterest(_ticker, _sizeDelta, _isLong, _isIncrease);
        }
        // 4. Relies on Updated Open interest
        _updateBorrowingRate(
            _ticker, _indexPrice, _collateralPrice, _indexBaseUnit, _isLong ? LONG_BASE_UNIT : SHORT_BASE_UNIT, _isLong
        );
        // Fire Event
        emit MarketStateUpdated(_ticker, _isLong);
    }

    /**
     * ========================= Token Functions  =========================
     */
    function batchWithdrawFees() external onlyConfigurator(address(this)) nonReentrant {
        uint256 longFees = longAccumulatedFees;
        uint256 shortFees = shortAccumulatedFees;
        longAccumulatedFees = 0;
        shortAccumulatedFees = 0;
        // calculate percentages and distribute percentage to owner and feeDistributor
        uint256 longOwnerFees = mulDiv(longFees, FEES_TO_OWNER, SCALING_FACTOR);
        uint256 shortOwnerFees = mulDiv(shortFees, FEES_TO_OWNER, SCALING_FACTOR);
        uint256 longDistributorFee = longFees - (longOwnerFees * 2); // 2 because 10% to owner and 10% to protocol
        uint256 shortDistributorFee = shortFees - (shortOwnerFees * 2);

        // Send Fees to Distribute to LPs
        IERC20(WETH).approve(address(feeDistributor), longDistributorFee);
        IERC20(USDC).approve(address(feeDistributor), shortDistributorFee);
        feeDistributor.accumulateFees(longDistributorFee, shortDistributorFee);
        // Send Fees to Protocol
        IERC20(WETH).safeTransfer(feeReceiver, longOwnerFees);
        IERC20(USDC).safeTransfer(feeReceiver, shortOwnerFees);
        // Send Fees to Owner
        IERC20(WETH).safeTransfer(poolOwner, longOwnerFees);
        IERC20(USDC).safeTransfer(poolOwner, shortOwnerFees);

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
        bytes32 _priceRequestId,
        bytes32 _pnlRequestId,
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
            key: _generateKey(_owner, _transferToken, _amountIn, _isDeposit),
            priceRequestId: _priceRequestId,
            pnlRequestId: _pnlRequestId
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

        // Clear Signed Prices and Pnl
        IPriceFeed priceFeed = ITradeStorage(tradeStorage).priceFeed();
        priceFeed.clearSignedPrices(this, _params.deposit.priceRequestId);
        priceFeed.clearCumulativePnl(this, _params.deposit.pnlRequestId);

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

        // Clear Signed Prices and Pnl
        IPriceFeed priceFeed = ITradeStorage(tradeStorage).priceFeed();
        priceFeed.clearSignedPrices(this, _params.withdrawal.priceRequestId);
        priceFeed.clearCumulativePnl(this, _params.withdrawal.pnlRequestId);

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

    function getRequest(bytes32 _key) external view returns (Input memory) {
        return requests[_key];
    }

    function getRequestAtIndex(uint256 _index) external view returns (Input memory) {
        return requests[requestKeys.at(_index)];
    }

    function totalAvailableLiquidity(bool _isLong) external view returns (uint256 total) {
        total = _isLong ? longTokenBalance - longTokensReserved : shortTokenBalance - shortTokensReserved;
    }

    function getTickers() external view returns (string[] memory) {
        return tickers;
    }

    /**
     *  ========================= Internal Functions  =========================
     */
    function _updateFundingRate(string calldata _ticker, uint256 _indexPrice) internal {
        bytes32 assetId = keccak256(abi.encode(_ticker));
        FundingValues memory funding = marketStorage[assetId].funding;
        marketStorage[assetId].funding = Funding.updateState(this, funding, _ticker, _indexPrice);
    }

    function _updateBorrowingRate(
        string calldata _ticker,
        uint256 _indexPrice,
        uint256 _collateralPrice,
        uint256 _indexBaseUnit,
        uint256 _collateralBaseUnit,
        bool _isLong
    ) internal {
        bytes32 assetId = keccak256(abi.encode(_ticker));
        BorrowingValues memory borrowing = marketStorage[assetId].borrowing;
        marketStorage[assetId].borrowing = Borrowing.updateState(
            this, borrowing, _ticker, _indexPrice, _collateralPrice, _indexBaseUnit, _collateralBaseUnit, _isLong
        );
    }

    /**
     * Updates the weighted average values for the market. Both rely on the market condition pre-open interest update.
     */
    function _updateWeightedAverages(string calldata _ticker, uint256 _priceUsd, int256 _sizeDeltaUsd, bool _isLong)
        internal
    {
        if (_priceUsd == 0) revert Market_PriceIsZero();
        if (_sizeDeltaUsd == 0) return;

        bytes32 assetId = keccak256(abi.encode(_ticker));

        PnlValues storage pnl = marketStorage[assetId].pnl;
        uint256 openInterest;

        if (_isLong) {
            openInterest = marketStorage[assetId].openInterest.longOpenInterest;
            pnl.longAverageEntryPriceUsd = MarketUtils.calculateWeightedAverageEntryPrice(
                pnl.longAverageEntryPriceUsd, openInterest, _sizeDeltaUsd, _priceUsd
            );
            marketStorage[assetId].borrowing.weightedAvgCumulativeLong =
                Borrowing.getNextAverageCumulative(this, _ticker, _sizeDeltaUsd, true);
        } else {
            openInterest = marketStorage[assetId].openInterest.shortOpenInterest;
            pnl.shortAverageEntryPriceUsd = MarketUtils.calculateWeightedAverageEntryPrice(
                pnl.shortAverageEntryPriceUsd, openInterest, _sizeDeltaUsd, _priceUsd
            );
            marketStorage[assetId].borrowing.weightedAvgCumulativeShort =
                Borrowing.getNextAverageCumulative(this, _ticker, _sizeDeltaUsd, false);
        }
    }

    function _updateOpenInterest(string calldata _ticker, uint256 _sizeDeltaUsd, bool _isLong, bool _shouldAdd)
        internal
    {
        // Update the open interest
        bytes32 assetId = keccak256(abi.encode(_ticker));
        if (_shouldAdd) {
            _isLong
                ? marketStorage[assetId].openInterest.longOpenInterest += _sizeDeltaUsd
                : marketStorage[assetId].openInterest.shortOpenInterest += _sizeDeltaUsd;
        } else {
            _isLong
                ? marketStorage[assetId].openInterest.longOpenInterest -= _sizeDeltaUsd
                : marketStorage[assetId].openInterest.shortOpenInterest -= _sizeDeltaUsd;
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

    function _validateConfig(Config memory _config) internal pure {
        /* 1. Validate the initial inputs */
        // Check Leverage is within bounds
        if (_config.maxLeverage < MIN_LEVERAGE || _config.maxLeverage > MAX_LEVERAGE) revert Market_InvalidLeverage();
        // Check the Reserve Factor is within bounds
        if (_config.reserveFactor < MIN_RESERVE_FACTOR || _config.reserveFactor > MAX_RESERVE_FACTOR) {
            revert Market_InvalidReserveFactor();
        }
        /* 2. Validate the Funding Values */
        // Check the Max Velocity is within bounds
        if (_config.funding.maxVelocity < MIN_VELOCITY || _config.funding.maxVelocity > MAX_VELOCITY) {
            revert Market_InvalidMaxVelocity();
        }
        // Check the Skew Scale is within bounds
        if (_config.funding.skewScale < MIN_SKEW_SCALE || _config.funding.skewScale > MAX_SKEW_SCALE) {
            revert Market_InvalidSkewScale();
        }
        /* 3. Validate Impact Values */
        // Check Skew Scalars are > 0 and <= 100%
        if (_config.impact.positiveSkewScalar <= 0 || _config.impact.positiveSkewScalar > SIGNED_SCALAR) {
            revert Market_InvalidSkewScalar();
        }
        if (_config.impact.negativeSkewScalar <= 0 || _config.impact.negativeSkewScalar > SIGNED_SCALAR) {
            revert Market_InvalidSkewScalar();
        }
        // Check negative skew scalar is >= positive skew scalar
        if (_config.impact.negativeSkewScalar < _config.impact.positiveSkewScalar) {
            revert Market_InvalidSkewScalar();
        }
        // Check Liquidity Scalars are > 0 and <= 100%
        if (_config.impact.positiveLiquidityScalar <= 0 || _config.impact.positiveLiquidityScalar > SIGNED_SCALAR) {
            revert Market_InvalidLiquidityScalar();
        }
        if (_config.impact.negativeLiquidityScalar <= 0 || _config.impact.negativeLiquidityScalar > SIGNED_SCALAR) {
            revert Market_InvalidLiquidityScalar();
        }
        // Check negative liquidity scalar is >= positive liquidity scalar
        if (_config.impact.negativeLiquidityScalar < _config.impact.positiveLiquidityScalar) {
            revert Market_InvalidLiquidityScalar();
        }
    }
}
