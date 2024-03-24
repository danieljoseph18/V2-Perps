// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IMarket} from "./interfaces/IMarket.sol";
import {RoleValidation} from "../access/RoleValidation.sol";
import {Funding} from "../libraries/Funding.sol";
import {Borrowing} from "../libraries/Borrowing.sol";
import {ReentrancyGuard} from "@solmate/utils/ReentrancyGuard.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {mulDiv} from "@prb/math/Common.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IMarketToken, IERC20} from "./interfaces/IMarketToken.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IWETH} from "../tokens/interfaces/IWETH.sol";
import {Oracle} from "../oracle/Oracle.sol";
import {MarketUtils} from "./MarketUtils.sol";

contract Market is IMarket, RoleValidation, ReentrancyGuard {
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using SafeCast for uint256;
    using SignedMath for int256;
    using SafeERC20 for IERC20;
    using Address for address payable;

    IMarketToken public immutable MARKET_TOKEN;

    address public tradeStorage;

    uint256 private constant BITMASK_16 = type(uint256).max >> (256 - 16);
    uint16 private constant TOTAL_ALLOCATION = 10000;
    uint64 private constant SCALING_FACTOR = 1e18;
    // Max 100 assets per market (could fit 12 more in last uint256, but 100 used for simplicity)
    // Fits 16 allocations per uint256
    uint8 private constant MAX_ASSETS = 100;
    uint64 public constant BASE_FEE = 0.001e18; // 0.1%

    address private immutable LONG_TOKEN;
    address private immutable SHORT_TOKEN;
    uint256 private immutable LONG_BASE_UNIT;
    uint256 private immutable SHORT_BASE_UNIT;

    EnumerableSet.Bytes32Set private assetIds;
    bool private isInitialized;

    uint48 minTimeToExpiration;

    address private poolOwner;
    address private feeDistributor;

    // Value = Max Bonus Fee
    // Users will be charged a % of this fee based on the skew of the market
    uint256 public feeScale; // 3% = 0.03e18
    uint256 private feePercentageToOwner; // 50% = 0.5e18

    uint256 private longTokenBalance;
    uint256 private shortTokenBalance;

    uint256 private longAccumulatedFees;
    uint256 private shortAccumulatedFees;

    uint256 private longTokensReserved;
    uint256 private shortTokensReserved;

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
            wethBalance: IERC20(LONG_TOKEN).balanceOf(address(this)),
            usdcBalance: IERC20(SHORT_TOKEN).balanceOf(address(this))
        });
        _;
        // Cache the state after
        State memory stateAfter = State({
            totalSupply: MARKET_TOKEN.totalSupply(),
            wethBalance: IERC20(LONG_TOKEN).balanceOf(address(this)),
            usdcBalance: IERC20(SHORT_TOKEN).balanceOf(address(this))
        });
        // Validate the Vault State Delta
        if (_isDeposit) {
            MarketUtils.validateDeposit(stateBefore, stateAfter, _amountIn, _isLongToken);
        } else {
            MarketUtils.validateWithdrawal(stateBefore, stateAfter, _amountIn, _amountOut, feeScale, _isLongToken);
        }
    }

    /**
     *  ========================= Constructor  =========================
     */
    constructor(
        VaultConfig memory _vaultConfig,
        Config memory _tokenConfig,
        address _marketToken,
        bytes32 _assetId,
        address _roleStorage
    ) RoleValidation(_roleStorage) {
        LONG_TOKEN = _vaultConfig.longToken;
        SHORT_TOKEN = _vaultConfig.shortToken;
        LONG_BASE_UNIT = _vaultConfig.longBaseUnit;
        SHORT_BASE_UNIT = _vaultConfig.shortBaseUnit;
        MARKET_TOKEN = IMarketToken(_marketToken);
        poolOwner = _vaultConfig.poolOwner;
        feeDistributor = _vaultConfig.feeDistributor;
        minTimeToExpiration = _vaultConfig.minTimeToExpiration;
        feeScale = _vaultConfig.feeScale;
        feePercentageToOwner = _vaultConfig.feePercentageToOwner;
        uint256[] memory allocations = new uint256[](1);
        allocations[0] = 10000 << 240;
        _addToken(_tokenConfig, _assetId, allocations);
    }

    receive() external payable {}

    function initialize(address _tradeStorage) external onlyMarketMaker {
        if (isInitialized) revert Market_AlreadyInitialized();
        tradeStorage = _tradeStorage;
        isInitialized = true;
        emit Market_Initialzied();
    }
    /**
     * ========================= Setter Functions  =========================
     */

    function addToken(Config memory _config, bytes32 _assetId, uint256[] calldata _newAllocations)
        external
        onlyMarketMaker
    {
        if (assetIds.length() >= MAX_ASSETS) revert Market_MaxAssetsReached();
        _addToken(_config, _assetId, _newAllocations);
    }

    function removeToken(bytes32 _assetId, uint256[] calldata _newAllocations) external onlyAdmin {
        if (!assetIds.contains(_assetId)) revert Market_TokenDoesNotExist();
        bool success = assetIds.remove(_assetId);
        if (!success) revert Market_FailedToRemoveAssetId();
        _setAllocationsWithBits(_newAllocations);
        delete marketStorage[_assetId];
        emit TokenRemoved(_assetId);
    }

    function updateFees(address _poolOwner, address _feeDistributor, uint256 _feeScale, uint256 _feePercentageToOwner)
        external
        onlyConfigurator(address(this))
    {
        if (_poolOwner == address(0)) revert Market_InvalidPoolOwner();
        if (_feeDistributor == address(0)) revert Market_InvalidFeeDistributor();
        if (_feeScale > 1e18) revert Market_InvalidFeeScale();
        if (_feePercentageToOwner > 1e18) revert Market_InvalidFeePercentage();
        poolOwner = _poolOwner;
        feeDistributor = _feeDistributor;
        feeScale = _feeScale;
        feePercentageToOwner = _feePercentageToOwner;
    }

    function updateConfig(Config memory _config, bytes32 _assetId) external onlyAdmin {
        marketStorage[_assetId].config = _config;
        emit MarketConfigUpdated(_assetId, _config);
    }

    /**
     * ========================= Market State Functions  =========================
     */
    // @audit - need to use a mapping to set market specific state keepers
    function setAllocationsWithBits(uint256[] memory _allocations) external onlyStateKeeper {
        _setAllocationsWithBits(_allocations);
    }

    // @audit - do we really need a flagging system for adl? can't we just nuke them until PTP ratio met?
    function updateAdlState(bytes32 _assetId, bool _isFlaggedForAdl, bool _isLong) external onlyPositionManager {
        if (_isLong) {
            marketStorage[_assetId].config.adl.flaggedLong = _isFlaggedForAdl;
        } else {
            marketStorage[_assetId].config.adl.flaggedShort = _isFlaggedForAdl;
        }
        emit AdlStateUpdated(_assetId, _isFlaggedForAdl);
    }

    // @audit - onlyTradeStorage
    function updateFundingRate(bytes32 _assetId, uint256 _indexPrice) external nonReentrant onlyPositionManager {
        FundingValues memory funding = marketStorage[_assetId].funding;

        // Calculate the skew in USD
        int256 skewUsd = Funding.calculateSkewUsd(this, _assetId);

        // Calculate the current funding velocity
        funding.fundingRateVelocity = Funding.getCurrentVelocity(this, _assetId, skewUsd);

        // Calculate the current funding rate
        (funding.fundingRate, funding.fundingAccruedUsd) = Funding.recompute(this, _assetId, _indexPrice);

        // Update storage
        funding.lastFundingUpdate = block.timestamp.toUint48();

        marketStorage[_assetId].funding = funding;

        emit FundingUpdated(funding.fundingRate, funding.fundingRateVelocity, funding.fundingAccruedUsd);
    }

    function updateBorrowingRate(
        bytes32 _assetId,
        uint256 _indexPrice,
        uint256 _indexBaseUnit,
        uint256 _collateralPrice,
        uint256 _collateralBaseUnit,
        bool _isLong
    ) external nonReentrant onlyPositionManager {
        BorrowingValues memory borrowing = marketStorage[_assetId].borrowing;

        if (_isLong) {
            borrowing.longCumulativeBorrowFees +=
                Borrowing.calculateFeesSinceUpdate(borrowing.longBorrowingRate, borrowing.lastBorrowUpdate);
            borrowing.longBorrowingRate = Borrowing.calculateRate(
                this, _assetId, _indexPrice, _indexBaseUnit, _collateralPrice, _collateralBaseUnit, true
            );
        } else {
            borrowing.shortCumulativeBorrowFees +=
                Borrowing.calculateFeesSinceUpdate(borrowing.shortBorrowingRate, borrowing.lastBorrowUpdate);
            borrowing.shortBorrowingRate = Borrowing.calculateRate(
                this, _assetId, _indexPrice, _indexBaseUnit, _collateralPrice, _collateralBaseUnit, false
            );
        }

        borrowing.lastBorrowUpdate = uint48(block.timestamp);

        // Update Storage
        marketStorage[_assetId].borrowing = borrowing;

        emit BorrowingRatesUpdated(_assetId, borrowing.longBorrowingRate, borrowing.shortBorrowingRate);
    }

    /**
     * Updates the weighted average values for the market. Both rely on the market condition pre-open interest update.
     */
    function updateWeightedAverages(bytes32 _assetId, uint256 _priceUsd, int256 _sizeDeltaUsd, bool _isLong)
        external
        onlyPositionManager
    {
        if (_priceUsd == 0) revert Market_PriceIsZero();
        if (_sizeDeltaUsd == 0) return; // No Change

        PnlValues memory pnl = marketStorage[_assetId].pnl;

        if (_isLong) {
            pnl.longAverageEntryPriceUsd = MarketUtils.calculateWeightedAverageEntryPrice(
                pnl.longAverageEntryPriceUsd,
                marketStorage[_assetId].openInterest.longOpenInterest,
                _sizeDeltaUsd,
                _priceUsd
            );
            marketStorage[_assetId].borrowing.weightedAvgCumulativeLong =
                Borrowing.getNextAverageCumulative(this, _assetId, _sizeDeltaUsd, true);
        } else {
            pnl.shortAverageEntryPriceUsd = MarketUtils.calculateWeightedAverageEntryPrice(
                pnl.shortAverageEntryPriceUsd,
                marketStorage[_assetId].openInterest.shortOpenInterest,
                _sizeDeltaUsd,
                _priceUsd
            );
            marketStorage[_assetId].borrowing.weightedAvgCumulativeShort =
                Borrowing.getNextAverageCumulative(this, _assetId, _sizeDeltaUsd, false);
        }

        // Update Storage
        marketStorage[_assetId].pnl = pnl;

        emit AverageEntryPriceUpdated(_assetId, pnl.longAverageEntryPriceUsd, pnl.shortAverageEntryPriceUsd);
    }

    // @audit - should we move all of these onlyPositionManager modifiers to Tradestorage modifiers?
    // makes more sense to have them there
    function updateOpenInterest(bytes32 _assetId, uint256 _sizeDeltaUsd, bool _isLong, bool _shouldAdd)
        external
        onlyPositionManager
    {
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
        emit OpenInterestUpdated(
            _assetId,
            marketStorage[_assetId].openInterest.longOpenInterest,
            marketStorage[_assetId].openInterest.shortOpenInterest
        );
    }

    function updateImpactPool(bytes32 _assetId, int256 _priceImpactUsd) external onlyPositionManager {
        _priceImpactUsd > 0
            ? marketStorage[_assetId].impactPool += _priceImpactUsd.abs()
            : marketStorage[_assetId].impactPool -= _priceImpactUsd.abs();
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
        uint256 longOwnerFee = mulDiv(longFees, feePercentageToOwner, SCALING_FACTOR);
        uint256 shortOwnerFee = mulDiv(shortFees, feePercentageToOwner, SCALING_FACTOR);
        uint256 longDistributorFee = longFees - longOwnerFee;
        uint256 shortDistributorFee = shortFees - shortOwnerFee;
        // send out fees
        IERC20(LONG_TOKEN).safeTransfer(poolOwner, longOwnerFee);
        IERC20(SHORT_TOKEN).safeTransfer(poolOwner, shortOwnerFee);
        IERC20(LONG_TOKEN).safeTransfer(feeDistributor, longDistributorFee);
        IERC20(SHORT_TOKEN).safeTransfer(feeDistributor, shortDistributorFee);

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

    function reserveLiquidity(uint256 _amount, bool _isLong) external onlyTradeStorage(address(this)) {
        _isLong ? longTokensReserved += _amount : shortTokensReserved += _amount;
    }

    function unreserveLiquidity(uint256 _amount, bool _isLong) external onlyTradeStorage(address(this)) {
        if (_isLong) {
            if (_amount > longTokensReserved) longTokensReserved = 0;
            else longTokensReserved -= _amount;
        } else {
            if (_amount > shortTokensReserved) shortTokensReserved = 0;
            else shortTokensReserved -= _amount;
        }
    }

    function increasePoolBalance(uint256 _amount, bool _isLong) external onlyTradeStorage(address(this)) {
        _increasePoolBalance(_amount, _isLong);
    }

    function decreasePoolBalance(uint256 _amount, bool _isLong) external onlyTradeStorage(address(this)) {
        _decreasePoolBalance(_amount, _isLong);
    }

    // combine increase and decrease into 1 function
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
        address _tokenIn,
        uint256 _amountIn,
        uint256 _executionFee,
        bool _reverseWrap,
        bool _isDeposit
    ) external payable onlyRouter {
        Input memory request = Input({
            amountIn: _amountIn,
            executionFee: _executionFee,
            owner: _owner,
            expirationTimestamp: uint48(block.timestamp) + minTimeToExpiration,
            isLongToken: _tokenIn == LONG_TOKEN,
            reverseWrap: _reverseWrap,
            isDeposit: _isDeposit,
            blockNumber: block.number,
            key: _generateKey(_owner, _tokenIn, _amountIn, _isDeposit)
        });
        bool success = requestKeys.add(request.key);
        if (!success) revert Market_FailedToAddRequest();
        requests[request.key] = request;
        emit RequestCreated(request.key, _owner, _tokenIn, _amountIn, request.blockNumber, _isDeposit);
    }

    function executeDeposit(ExecuteDeposit calldata _params)
        external
        onlyPositionManager
        orderExists(_params.key)
        nonReentrant
        validAction(_params.deposit.amountIn, 0, _params.deposit.isLongToken, true)
    {
        // Delete Deposit Request
        _deleteRequest(_params.key);

        // Calculate Fee (Internal Function to avoid STD)
        uint256 fee = _calculateDepositFee(_params);

        // Calculate remaining after fee
        uint256 afterFeeAmount = _params.deposit.amountIn - fee;

        // Calculate Mint amount with the remaining amount
        uint256 mintAmount = _calculateMintAmount(_params, afterFeeAmount);
        // update storage
        _accumulateFees(fee, _params.deposit.isLongToken);
        _increasePoolBalance(afterFeeAmount, _params.deposit.isLongToken);
        // Transfer tokens into the market
        address tokenIn = _params.deposit.isLongToken ? LONG_TOKEN : SHORT_TOKEN;

        emit DepositExecuted(_params.key, _params.deposit.owner, tokenIn, _params.deposit.amountIn, mintAmount);
        // mint tokens to user
        MARKET_TOKEN.mint(_params.deposit.owner, mintAmount);
    }

    function deleteRequest(bytes32 _key) external onlyPositionManager {
        _deleteRequest(_key);
    }

    function executeWithdrawal(ExecuteWithdrawal calldata _params)
        external
        onlyPositionManager
        orderExists(_params.key)
        nonReentrant
        validAction(_params.withdrawal.amountIn, _params.amountOut, _params.withdrawal.isLongToken, false)
    {
        // Delete the WIthdrawal from Storage
        _deleteRequest(_params.key);

        // Validate the Amount Out vs Expected Amount out
        uint256 expectedOut = withdrawMarketTokensToTokens(
            _params.longPrices,
            _params.shortPrices,
            _params.withdrawal.amountIn,
            _params.longBorrowFeesUsd,
            _params.shortBorrowFeesUsd,
            _params.cumulativePnl,
            _params.withdrawal.isLongToken
        );
        if (_params.amountOut != expectedOut) revert Market_InvalidAmountOut(_params.amountOut, expectedOut);

        // Calculate Fee
        MarketUtils.FeeParams memory feeParams = MarketUtils.constructFeeParams(
            _params.market,
            _params.amountOut,
            _params.withdrawal.isLongToken,
            _params.longPrices,
            _params.shortPrices,
            false
        );
        uint256 fee =
            MarketUtils.calculateFee(feeParams, longTokenBalance, LONG_BASE_UNIT, shortTokenBalance, SHORT_BASE_UNIT);

        // Calculate amount out / aum before burning
        MARKET_TOKEN.burn(address(this), _params.withdrawal.amountIn);

        // calculate amount remaining after fee and price impact
        uint256 transferAmountOut = _params.amountOut - fee;
        // accumulate the fee
        _accumulateFees(fee, _params.withdrawal.isLongToken);
        // validate whether the pool has enough tokens
        uint256 available = _params.withdrawal.isLongToken
            ? longTokenBalance - longTokensReserved
            : shortTokenBalance - shortTokensReserved;
        if (transferAmountOut > available) revert Market_InsufficientAvailableTokens();
        // decrease the pool
        _decreasePoolBalance(_params.amountOut, _params.withdrawal.isLongToken);

        emit WithdrawalExecuted(
            _params.key,
            _params.withdrawal.owner,
            _params.withdrawal.isLongToken ? LONG_TOKEN : SHORT_TOKEN,
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
    function depositTokensToMarketTokens(
        Oracle.Price memory _longPrices,
        Oracle.Price memory _shortPrices,
        uint256 _amountIn,
        uint256 _longBorrowFeesUsd,
        uint256 _shortBorrowFeesUsd,
        int256 _cumulativePnl,
        bool _isLongToken
    ) public view returns (uint256 marketTokenAmount) {
        // Minimise
        uint256 valueUsd = _isLongToken
            ? mulDiv(_amountIn, _longPrices.price - _longPrices.confidence, LONG_BASE_UNIT)
            : mulDiv(_amountIn, _shortPrices.price - _shortPrices.confidence, SHORT_BASE_UNIT);
        // Maximise
        uint256 marketTokenPrice = getMarketTokenPrice(
            _longPrices.price + _longPrices.confidence,
            _longBorrowFeesUsd,
            _shortPrices.price + _shortPrices.confidence,
            _shortBorrowFeesUsd,
            _cumulativePnl
        );
        return marketTokenPrice == 0 ? valueUsd : mulDiv(valueUsd, SCALING_FACTOR, marketTokenPrice);
    }

    function withdrawMarketTokensToTokens(
        Oracle.Price memory _longPrices,
        Oracle.Price memory _shortPrices,
        uint256 _marketTokenAmountIn,
        uint256 _longBorrowFeesUsd,
        uint256 _shortBorrowFeesUsd,
        int256 _cumulativePnl,
        bool _isLongToken
    ) public view returns (uint256 tokenAmount) {
        uint256 marketTokenPrice = getMarketTokenPrice(
            _longPrices.price - _longPrices.confidence,
            _longBorrowFeesUsd,
            _shortPrices.price - _shortPrices.confidence,
            _shortBorrowFeesUsd,
            _cumulativePnl
        );
        uint256 valueUsd = mulDiv(_marketTokenAmountIn, marketTokenPrice, SCALING_FACTOR);
        if (_isLongToken) {
            tokenAmount = mulDiv(valueUsd, LONG_BASE_UNIT, _longPrices.price + _longPrices.confidence);
        } else {
            tokenAmount = mulDiv(valueUsd, SHORT_BASE_UNIT, _shortPrices.price + _shortPrices.confidence);
        }
    }

    function getMarketTokenPrice(
        uint256 _longTokenPrice,
        uint256 _longBorrowFeesUsd,
        uint256 _shortTokenPrice,
        uint256 _shortBorrowFeesUsd,
        int256 _cumulativePnl
    ) public view returns (uint256 lpTokenPrice) {
        // market token price = (worth of market pool in USD) / total supply
        uint256 aum = getAum(_longTokenPrice, _longBorrowFeesUsd, _shortTokenPrice, _shortBorrowFeesUsd, _cumulativePnl);
        if (aum == 0 || MARKET_TOKEN.totalSupply() == 0) {
            lpTokenPrice = 0;
        } else {
            lpTokenPrice = mulDiv(aum, SCALING_FACTOR, MARKET_TOKEN.totalSupply());
        }
    }

    // Funding Fees should be balanced between the longs and shorts, so don't need to be accounted for.
    // They are however settled through the pool, so maybe they should be accounted for?
    // If not, we must reduce the pool balance for each funding claim, which will account for them.
    function getAum(
        uint256 _longTokenPrice,
        uint256 _longBorrowFeesUsd,
        uint256 _shortTokenPrice,
        uint256 _shortBorrowFeesUsd,
        int256 _cumulativePnl
    ) public view returns (uint256 aum) {
        // Get Values in USD -> Subtract reserved amounts from AUM
        uint256 longTokenValue = mulDiv(longTokenBalance - longTokensReserved, _longTokenPrice, LONG_BASE_UNIT);
        uint256 shortTokenValue = mulDiv(shortTokenBalance - shortTokensReserved, _shortTokenPrice, SHORT_BASE_UNIT);

        // Add Borrow Fees
        longTokenValue += _longBorrowFeesUsd;
        shortTokenValue += _shortBorrowFeesUsd;

        // Calculate AUM
        aum = _cumulativePnl >= 0
            ? longTokenValue + shortTokenValue + _cumulativePnl.abs()
            : longTokenValue + shortTokenValue - _cumulativePnl.abs();
    }

    function getAssetIds() external view returns (bytes32[] memory) {
        return assetIds.values();
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
    function _calculateDepositFee(ExecuteDeposit calldata _params) internal view returns (uint256 fee) {
        // Calculate Fee
        MarketUtils.FeeParams memory feeParams = MarketUtils.constructFeeParams(
            _params.market,
            _params.deposit.amountIn,
            _params.deposit.isLongToken,
            _params.longPrices,
            _params.shortPrices,
            true
        );
        fee = MarketUtils.calculateFee(feeParams, longTokenBalance, LONG_BASE_UNIT, shortTokenBalance, SHORT_BASE_UNIT);
    }

    function _calculateMintAmount(ExecuteDeposit calldata _params, uint256 _afterFeeAmount)
        internal
        view
        returns (uint256 mintAmount)
    {
        mintAmount = depositTokensToMarketTokens(
            _params.longPrices,
            _params.shortPrices,
            _afterFeeAmount,
            _params.longBorrowFeesUsd,
            _params.shortBorrowFeesUsd,
            _params.cumulativePnl,
            _params.deposit.isLongToken
        );
    }

    function _setAllocationsWithBits(uint256[] memory _allocations) internal {
        bytes32[] memory assets = assetIds.values();
        uint256 assetLen = assets.length;

        uint256 total = 0;
        uint256 allocationIndex = 0;

        for (uint256 i = 0; i < _allocations.length; ++i) {
            for (uint256 bitIndex = 0; bitIndex < 16;) {
                if (allocationIndex >= assetLen) {
                    break;
                }

                // Calculate the bit position for the current allocation
                uint256 startBit = 240 - (bitIndex * 16);
                uint256 allocation = (_allocations[i] >> startBit) & BITMASK_16;
                total += allocation;

                // Ensure that the allocationIndex does not exceed the bounds of the markets array
                if (allocationIndex < assetLen) {
                    marketStorage[assets[allocationIndex]].allocationPercentage = allocation;
                    ++allocationIndex;
                }
                unchecked {
                    ++bitIndex;
                }
            }
        }

        if (total != TOTAL_ALLOCATION) revert Market_InvalidCumulativeAllocation();
    }

    function _addToken(Config memory _config, bytes32 _assetId, uint256[] memory _newAllocations) internal {
        if (assetIds.contains(_assetId)) revert Market_TokenAlreadyExists();
        bool success = assetIds.add(_assetId);
        if (!success) revert Market_FailedToAddAssetId();
        _setAllocationsWithBits(_newAllocations);
        marketStorage[_assetId].config = _config;
        marketStorage[_assetId].funding.lastFundingUpdate = block.timestamp.toUint48();
        marketStorage[_assetId].borrowing.lastBorrowUpdate = block.timestamp.toUint48();
        emit TokenAdded(_assetId, _config);
    }

    function _deleteRequest(bytes32 _key) internal {
        bool success = requestKeys.remove(_key);
        if (!success) revert Market_FailedToRemoveRequest();
        delete requests[_key];
    }

    function _accumulateFees(uint256 _amount, bool _isLong) internal {
        _isLong ? longAccumulatedFees += _amount : shortAccumulatedFees += _amount;
    }

    function _increasePoolBalance(uint256 _amount, bool _isLong) internal {
        _isLong ? longTokenBalance += _amount : shortTokenBalance += _amount;
    }

    function _decreasePoolBalance(uint256 _amount, bool _isLong) internal {
        _isLong ? longTokenBalance -= _amount : shortTokenBalance -= _amount;
    }

    function _transferOutTokens(address _to, uint256 _amount, bool _isLongToken, bool _shouldUnwrap) internal {
        if (_isLongToken) {
            if (_shouldUnwrap) {
                IWETH(LONG_TOKEN).withdraw(_amount);
                payable(_to).sendValue(_amount);
            } else {
                IERC20(LONG_TOKEN).safeTransfer(_to, _amount);
            }
        } else {
            IERC20(SHORT_TOKEN).safeTransfer(_to, _amount);
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
