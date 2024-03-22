// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IVault} from "./interfaces/IVault.sol";
import {ERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {RoleValidation} from "../access/RoleValidation.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {ReentrancyGuard} from "@solmate/utils/ReentrancyGuard.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IWETH} from "../tokens/interfaces/IWETH.sol";
import {IPositionManager} from "../router/interfaces/IPositionManager.sol";
import {IPriceFeed} from "../oracle/interfaces/IPriceFeed.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {mulDiv} from "@prb/math/Common.sol";
import {Oracle} from "../oracle/Oracle.sol";
import {Fee} from "../libraries/Fee.sol";
import {Invariant} from "../libraries/Invariant.sol";

// Stores all funds for the market(s)
// Each Vault can be associated with 1+ markets
// Its liquidity is allocated between the underlying markets
/// @dev Needs Vault Role
contract Vault is IVault, ERC20, RoleValidation, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using Address for address payable;
    using SignedMath for int256;

    uint256 public constant BITMASK_16 = type(uint256).max >> (256 - 16);
    uint256 public constant TOTAL_ALLOCATION = 10000;
    uint256 public constant MIN_SLIPPAGE = 0.0001e18; // 0.01%
    uint256 public constant MAX_SLIPPAGE = 0.9999e18; // 99.99%
    uint256 public constant SCALING_FACTOR = 1e18;
    uint256 public constant BASE_FEE = 0.001e18; // 0.1%

    address public immutable LONG_TOKEN;
    address public immutable SHORT_TOKEN;
    uint256 private immutable LONG_BASE_UNIT;
    uint256 private immutable SHORT_BASE_UNIT;

    IPriceFeed priceFeed;
    IPositionManager positionManager;

    uint48 minTimeToExpiration;

    address public poolOwner;
    address public feeDistributor;

    // Value = Max Bonus Fee
    // Users will be charged a % of this fee based on the skew of the market
    uint256 public feeScale; // 3% = 0.03e18
    uint256 public feePercentageToOwner; // 50% = 0.5e18

    uint256 public longTokenBalance;
    uint256 public shortTokenBalance;

    uint256 public longAccumulatedFees;
    uint256 public shortAccumulatedFees;

    uint256 public longTokensReserved;
    uint256 public shortTokensReserved;

    // Store the Collateral Amount for each User
    mapping(address user => mapping(bool _isLong => uint256 collateralAmount)) public collateralAmounts;

    mapping(bytes32 => Deposit) private depositRequests;
    EnumerableSet.Bytes32Set private depositKeys;
    mapping(bytes32 => Withdrawal) private withdrawalRequests;
    EnumerableSet.Bytes32Set private withdrawalKeys;

    modifier orderExists(bytes32 _key, bool _isDeposit) {
        if (_isDeposit) {
            if (!depositKeys.contains(_key)) revert Vault_InvalidKey();
        } else {
            if (!withdrawalKeys.contains(_key)) revert Vault_InvalidKey();
        }
        _;
    }

    modifier isValidDeposit(Deposit calldata _deposit) {
        // Cache the State Before
        State memory stateBefore = State({
            longPoolBalance: longTokenBalance,
            shortPoolBalance: shortTokenBalance,
            longAccumulatedFees: longAccumulatedFees,
            shortAccumulatedFees: shortAccumulatedFees,
            totalSupply: totalSupply(),
            wethBalance: IERC20(LONG_TOKEN).balanceOf(address(this)),
            usdcBalance: IERC20(SHORT_TOKEN).balanceOf(address(this))
        });
        _;
        // Cache the state after
        State memory stateAfter = State({
            longPoolBalance: longTokenBalance,
            shortPoolBalance: shortTokenBalance,
            longAccumulatedFees: longAccumulatedFees,
            shortAccumulatedFees: shortAccumulatedFees,
            totalSupply: totalSupply(),
            wethBalance: IERC20(LONG_TOKEN).balanceOf(address(this)),
            usdcBalance: IERC20(SHORT_TOKEN).balanceOf(address(this))
        });

        // Validate the Vault State Delta
        Invariant.validateDeposit(stateBefore, stateAfter, _deposit, feeScale);
    }

    modifier isValidWithdrawal(Withdrawal calldata _withdrawal, uint256 _amountOut) {
        // Cache the State Before
        State memory stateBefore = State({
            longPoolBalance: longTokenBalance,
            shortPoolBalance: shortTokenBalance,
            longAccumulatedFees: longAccumulatedFees,
            shortAccumulatedFees: shortAccumulatedFees,
            totalSupply: totalSupply(),
            wethBalance: IERC20(LONG_TOKEN).balanceOf(address(this)),
            usdcBalance: IERC20(SHORT_TOKEN).balanceOf(address(this))
        });
        _;
        // Cache the state after
        State memory stateAfter = State({
            longPoolBalance: longTokenBalance,
            shortPoolBalance: shortTokenBalance,
            longAccumulatedFees: longAccumulatedFees,
            shortAccumulatedFees: shortAccumulatedFees,
            totalSupply: totalSupply(),
            wethBalance: IERC20(LONG_TOKEN).balanceOf(address(this)),
            usdcBalance: IERC20(SHORT_TOKEN).balanceOf(address(this))
        });
        // Validate the Vault State Delta
        Invariant.validateWithdrawal(stateBefore, stateAfter, _withdrawal, _amountOut, feeScale);
    }

    constructor(VaultConfig memory _config, address _roleStorage)
        ERC20(_config.name, _config.symbol)
        RoleValidation(_roleStorage)
    {
        LONG_TOKEN = _config.longToken;
        SHORT_TOKEN = _config.shortToken;
        LONG_BASE_UNIT = _config.longBaseUnit;
        SHORT_BASE_UNIT = _config.shortBaseUnit;
        priceFeed = IPriceFeed(_config.priceFeed);
        positionManager = IPositionManager(_config.positionManager);
        poolOwner = _config.poolOwner;
        feeDistributor = _config.feeDistributor;
        minTimeToExpiration = _config.minTimeToExpiration;
        feeScale = _config.feeScale;
        feePercentageToOwner = _config.feePercentageToOwner;
    }

    receive() external payable {}

    function updateFees(address _poolOwner, address _feeDistributor, uint256 _feeScale, uint256 _feePercentageToOwner)
        external
        onlyConfigurator(address(this))
    {
        if (_poolOwner == address(0)) revert Vault_InvalidPoolOwner();
        if (_feeDistributor == address(0)) revert Vault_InvalidFeeDistributor();
        if (_feeScale > 1e18) revert Vault_InvalidFeeScale();
        if (_feePercentageToOwner > 1e18) revert Vault_InvalidFeePercentage();
        poolOwner = _poolOwner;
        feeDistributor = _feeDistributor;
        feeScale = _feeScale;
        feePercentageToOwner = _feePercentageToOwner;
    }

    function updatePositionManager(IPositionManager _positionManager) external onlyConfigurator(address(this)) {
        positionManager = _positionManager;
    }

    function updatePriceFeed(IPriceFeed _priceFeed) external onlyConfigurator(address(this)) {
        priceFeed = _priceFeed;
    }

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
        if (_amount > available) revert Vault_InsufficientAvailableTokens();
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

    function increaseCollateralAmount(uint256 _amount, address _user, bool _islong)
        external
        onlyTradeStorage(address(this))
    {
        collateralAmounts[_user][_islong] += _amount;
    }

    function decreaseCollateralAmount(uint256 _amount, address _user, bool _islong)
        external
        onlyTradeStorage(address(this))
    {
        if (_amount > collateralAmounts[_user][_islong]) revert Vault_InsufficientCollateral();
        else collateralAmounts[_user][_islong] -= _amount;
    }

    // Function to create a deposit request
    function createDeposit(address _owner, address _tokenIn, uint256 _amountIn, uint256 _executionFee, bool _shouldWrap)
        external
        payable
        onlyRouter
    {
        Deposit memory deposit = Deposit({
            amountIn: _amountIn,
            executionFee: _executionFee,
            owner: _owner,
            expirationTimestamp: uint48(block.timestamp) + minTimeToExpiration,
            isLongToken: _tokenIn == LONG_TOKEN,
            shouldWrap: _shouldWrap,
            blockNumber: block.number,
            key: _generateKey(_owner, _tokenIn, _amountIn)
        });
        bool success = depositKeys.add(deposit.key);
        if (!success) revert Vault_FailedToAddDeposit();
        depositRequests[deposit.key] = deposit;
        emit DepositRequestCreated(deposit.key, _owner, _tokenIn, _amountIn, deposit.blockNumber);
    }

    function deleteDeposit(bytes32 _key) external onlyPositionManager {
        _deleteDeposit(_key);
    }

    function executeDeposit(ExecuteDeposit calldata _params)
        external
        onlyPositionManager
        orderExists(_params.key, true)
        nonReentrant
        isValidDeposit(_params.deposit)
    {
        // Delete Deposit Request
        _deleteDeposit(_params.key);

        // Calculate Fee
        Fee.Params memory feeParams = Fee.constructFeeParams(
            _params.market,
            _params.deposit.amountIn,
            _params.deposit.isLongToken,
            _params.longPrices,
            _params.shortPrices,
            true
        );
        uint256 fee = Fee.calculateForMarketAction(
            feeParams, longTokenBalance, LONG_BASE_UNIT, shortTokenBalance, SHORT_BASE_UNIT
        );

        // Calculate remaining after fee
        uint256 afterFeeAmount = _params.deposit.amountIn - fee;

        // Calculate Mint amount with the remaining amount
        uint256 mintAmount = depositTokensToMarketTokens(
            _params.longPrices,
            _params.shortPrices,
            afterFeeAmount,
            _params.longBorrowFeesUsd,
            _params.shortBorrowFeesUsd,
            _params.cumulativePnl,
            _params.deposit.isLongToken
        );
        // update storage
        _accumulateFees(fee, _params.deposit.isLongToken);
        _increasePoolBalance(afterFeeAmount, _params.deposit.isLongToken);
        // Transfer tokens into the market
        address tokenIn = _params.deposit.isLongToken ? LONG_TOKEN : SHORT_TOKEN;
        positionManager.transferDepositTokens(address(this), tokenIn, _params.deposit.amountIn);

        emit DepositExecuted(_params.key, _params.deposit.owner, tokenIn, _params.deposit.amountIn, mintAmount);
        // mint tokens to user
        _mint(_params.deposit.owner, mintAmount);
    }

    // Function to create a withdrawal request
    function createWithdrawal(
        address _owner,
        address _tokenOut,
        uint256 _marketTokenAmountIn,
        uint256 _executionFee,
        bool _shouldUnwrap
    ) external payable onlyRouter {
        Withdrawal memory withdrawal = Withdrawal({
            marketTokenAmountIn: _marketTokenAmountIn,
            executionFee: _executionFee,
            owner: _owner,
            expirationTimestamp: uint48(block.timestamp) + minTimeToExpiration,
            isLongToken: _tokenOut == LONG_TOKEN,
            shouldUnwrap: _shouldUnwrap,
            blockNumber: block.number,
            key: _generateKey(_owner, _tokenOut, _marketTokenAmountIn)
        });

        bool success = withdrawalKeys.add(withdrawal.key);
        if (!success) revert Vault_FailedToAddWithdrawal();
        withdrawalRequests[withdrawal.key] = withdrawal;

        emit WithdrawalRequestCreated(withdrawal.key, _owner, _tokenOut, _marketTokenAmountIn, withdrawal.blockNumber);
    }

    function deleteWithdrawal(bytes32 _key) external onlyPositionManager {
        _deleteWithdrawal(_key);
    }

    function executeWithdrawal(ExecuteWithdrawal calldata _params)
        external
        onlyPositionManager
        orderExists(_params.key, false)
        nonReentrant
        isValidWithdrawal(_params.withdrawal, _params.amountOut)
    {
        // Transfer in Market Tokens
        _params.positionManager.transferDepositTokens(
            address(this), address(this), _params.withdrawal.marketTokenAmountIn
        );
        // Delete the WIthdrawal from Storage
        _deleteWithdrawal(_params.key);

        // Validate the Amount Out vs Expected Amount out
        uint256 expectedOut = withdrawMarketTokensToTokens(
            _params.longPrices,
            _params.shortPrices,
            _params.withdrawal.marketTokenAmountIn,
            _params.longBorrowFeesUsd,
            _params.shortBorrowFeesUsd,
            _params.cumulativePnl,
            _params.withdrawal.isLongToken
        );
        if (_params.amountOut != expectedOut) revert Vault_InvalidAmountOut(_params.amountOut, expectedOut);

        // Calculate Fee
        Fee.Params memory feeParams = Fee.constructFeeParams(
            _params.market,
            _params.amountOut,
            _params.withdrawal.isLongToken,
            _params.longPrices,
            _params.shortPrices,
            false
        );
        uint256 fee = Fee.calculateForMarketAction(
            feeParams, longTokenBalance, LONG_BASE_UNIT, shortTokenBalance, SHORT_BASE_UNIT
        );

        // Calculate amount out / aum before burning
        _burn(address(this), _params.withdrawal.marketTokenAmountIn);

        // calculate amount remaining after fee and price impact
        uint256 transferAmountOut = _params.amountOut - fee;
        // accumulate the fee
        _accumulateFees(fee, _params.withdrawal.isLongToken);
        // validate whether the pool has enough tokens
        uint256 available = _params.withdrawal.isLongToken
            ? longTokenBalance - longTokensReserved
            : shortTokenBalance - shortTokensReserved;
        if (transferAmountOut > available) revert Vault_InsufficientAvailableTokens();
        // decrease the pool
        _decreasePoolBalance(_params.amountOut, _params.withdrawal.isLongToken);

        emit WithdrawalExecuted(
            _params.key,
            _params.withdrawal.owner,
            _params.withdrawal.isLongToken ? LONG_TOKEN : SHORT_TOKEN,
            _params.withdrawal.marketTokenAmountIn,
            transferAmountOut
        );
        // transfer tokens to user
        _transferOutTokens(
            _params.withdrawal.owner, transferAmountOut, _params.withdrawal.isLongToken, _params.shouldUnwrap
        );
    }

    function calculateUsdValue(
        bool _isLongToken,
        uint256 _longBaseUnit,
        uint256 _shortBaseUnit,
        uint256 _price,
        uint256 _amount
    ) external pure returns (uint256 valueUsd) {
        if (_isLongToken) {
            valueUsd = mulDiv(_amount, _price, _longBaseUnit);
        } else {
            valueUsd = mulDiv(_amount, _price, _shortBaseUnit);
        }
    }

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
        if (aum == 0 || totalSupply() == 0) {
            lpTokenPrice = 0;
        } else {
            lpTokenPrice = mulDiv(aum, SCALING_FACTOR, totalSupply());
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

    /**
     * ====================== Internal Functions ======================
     */
    function _deleteWithdrawal(bytes32 _key) internal {
        bool success = withdrawalKeys.remove(_key);
        if (!success) revert Vault_FailedToRemoveWithdrawal();
        delete withdrawalRequests[_key];
    }

    function _deleteDeposit(bytes32 _key) internal {
        bool success = depositKeys.remove(_key);
        if (!success) revert Vault_FailedToRemoveDeposit();
        delete depositRequests[_key];
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

    function _generateKey(address _owner, address _tokenIn, uint256 _tokenAmount) internal view returns (bytes32) {
        return keccak256(abi.encode(_owner, _tokenIn, _tokenAmount, block.number));
    }

    function getTokenBalances() external view returns (uint256, uint256) {
        return (longTokenBalance, shortTokenBalance);
    }

    function getReservedAmounts() external view returns (uint256, uint256) {
        return (longTokensReserved, shortTokensReserved);
    }

    function getDepositRequestAtIndex(uint256 _index) external view returns (Deposit memory) {
        return depositRequests[depositKeys.at(_index)];
    }

    function getDepositRequest(bytes32 _key) external view returns (Deposit memory) {
        return depositRequests[_key];
    }

    function getWithdrawalRequest(bytes32 _key) external view returns (Withdrawal memory) {
        return withdrawalRequests[_key];
    }

    function getWithdrawalRequestAtIndex(uint256 _index) external view returns (Withdrawal memory) {
        return withdrawalRequests[withdrawalKeys.at(_index)];
    }

    function totalAvailableLiquidity(bool _isLong) external view returns (uint256 total) {
        total = _isLong ? longTokenBalance - longTokensReserved : shortTokenBalance - shortTokensReserved;
    }

    function getPoolValues() external view returns (uint256, uint256, uint256, uint256, uint256) {
        return (longTokenBalance, shortTokenBalance, totalSupply(), LONG_BASE_UNIT, SHORT_BASE_UNIT);
    }
}
