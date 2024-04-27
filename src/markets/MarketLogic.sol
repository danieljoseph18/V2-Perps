// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IMarket} from "./interfaces/IMarket.sol";
import {IVault, IERC20} from "./interfaces/IVault.sol";
import {SafeTransferLib} from "../libraries/SafeTransferLib.sol";
import {IFeeDistributor} from "../rewards/interfaces/IFeeDistributor.sol";
import {IPriceFeed} from "../oracle/interfaces/IPriceFeed.sol";
import {MarketUtils} from "./MarketUtils.sol";
import {Funding} from "../libraries/Funding.sol";
import {Borrowing} from "../libraries/Borrowing.sol";
import {IWETH} from "../tokens/interfaces/IWETH.sol";
import {MathUtils} from "../libraries/MathUtils.sol";
import {SignedMath} from "../libraries/SignedMath.sol";
import {EnumerableMap} from "../libraries/EnumerableMap.sol";
import {Oracle} from "../oracle/Oracle.sol";
import {Pool} from "./Pool.sol";

library MarketLogic {
    using SafeTransferLib for IERC20;
    using SafeTransferLib for IVault;
    using MathUtils for uint256;
    using SignedMath for int256;
    using EnumerableMap for EnumerableMap.MarketRequestMap;

    error MarketLogic_InvalidLeverage();
    error MarketLogic_InvalidReserveFactor();
    error MarketLogic_InvalidMaxVelocity();
    error MarketLogic_InvalidSkewScale();
    error MarketLogic_InvalidSkewScalar();
    error MarketLogic_InvalidLiquidityScalar();
    error MarketLogic_InsufficientAvailableTokens();
    error MarketLogic_InvalidKey();
    error MarketLogic_RequestNotOwner();
    error MarketLogic_RequestNotExpired();
    error MarketLogic_InvalidTicker();
    error MarketLogic_PriceIsZero();
    error MarketLogic_InvalidCumulativeAllocation();
    error MarketLogic_InvalidAllocation();
    error MarketLogic_InvalidCaller();
    error MarketLogic_MaxAssetsReached();
    error MarketLogic_TokenAlreadyExists();
    error MarketLogic_TokenDoesNotExist();
    error MarketLogic_MinimumAssetsReached();
    error MarketLogic_FailedToTransferETH();
    error MarketLogic_FailedToRemoveRequest();
    error MarketLogic_FailedToAddRequest();
    error MarketLogic_AllocationLength();

    event FeesWithdrawn(uint256 _longFees, uint256 _shortFees);
    event DepositExecuted(
        bytes32 indexed key, address indexed owner, address tokenIn, uint256 amountIn, uint256 mintAmount
    );
    event WithdrawalExecuted(
        bytes32 indexed key, address indexed owner, address tokenOut, uint256 marketTokenAmountIn, uint256 amountOut
    );
    event RequestCanceled(bytes32 indexed key, address indexed owner);
    event RequestCreated(bytes32 indexed key, address indexed owner, address tokenIn, uint256 amountIn, bool isDeposit);
    event MarketStateUpdated(string ticker, bool isLong);
    event TokenAdded(string ticker);
    event TokenRemoved(string ticker);

    uint8 private constant TOTAL_ALLOCATION = 100;
    // Max 100 assets per market (could fit 12 more in last uint256, but 100 used for simplicity)
    // Fits 16 allocations per uint256
    uint8 private constant MAX_ASSETS = 100;
    uint32 private constant MIN_LEVERAGE = 1; // Min 1x Leverage
    uint32 private constant MAX_LEVERAGE = 1000; // Max 1000x leverage
    uint64 private constant MIN_MAINTENANCE_MARGIN = 50; // 0.5%
    uint64 private constant MAX_MAINTENANCE_MARGIN = 1000; // 10%
    uint64 private constant MIN_RESERVE_FACTOR = 1000; // 10% reserve factor
    uint64 private constant MAX_RESERVE_FACTOR = 5000; // 50% reserve factor
    int64 private constant MIN_VELOCITY = 10; // 0.1% per day
    int64 private constant MAX_VELOCITY = 2000; // 20% per day
    int256 private constant MIN_SKEW_SCALE = 1000; // $1000
    int256 private constant MAX_SKEW_SCALE = 10_000_000_000; // $10 Bn
    int16 private constant MAX_SCALAR = 10000;
    uint48 private constant TIME_TO_EXPIRATION = 1 minutes;
    string private constant LONG_TICKER = "WETH";
    string private constant SHORT_TICKER = "USDC";

    // The rest of the 80% of the fees go to the FeeDistributor to distribute to LPs
    uint256 private constant FEES_TO_OWNER = 0.1e18; // 10% to Owner
    uint256 private constant FEES_TO_PROTOCOL = 0.1e18; // 10% to Protocol

    /**
     * ============================= Validations =============================
     */
    function validateConfig(Pool.Config calldata _config) internal pure {
        /* 1. Validate the initial inputs */
        // Check Leverage is within bounds
        if (_config.maxLeverage < MIN_LEVERAGE || _config.maxLeverage > MAX_LEVERAGE) {
            revert MarketLogic_InvalidLeverage();
        }
        // Check maintenance margin is within bounds
        if (_config.maintenanceMargin < MIN_MAINTENANCE_MARGIN || _config.maintenanceMargin > MAX_MAINTENANCE_MARGIN) {
            revert MarketLogic_InvalidLeverage();
        }
        // Check the Reserve Factor is within bounds
        if (_config.reserveFactor < MIN_RESERVE_FACTOR || _config.reserveFactor > MAX_RESERVE_FACTOR) {
            revert MarketLogic_InvalidReserveFactor();
        }
        /* 2. Validate the Funding Values */
        // Check the Max Velocity is within bounds
        if (_config.maxFundingVelocity < MIN_VELOCITY || _config.maxFundingVelocity > MAX_VELOCITY) {
            revert MarketLogic_InvalidMaxVelocity();
        }
        // Check the Skew Scale is within bounds
        if (_config.skewScale < MIN_SKEW_SCALE || _config.skewScale > MAX_SKEW_SCALE) {
            revert MarketLogic_InvalidSkewScale();
        }
        /* 3. Validate Impact Values */
        // Check Skew Scalars are > 0 and <= 100%
        if (_config.positiveSkewScalar <= 0 || _config.positiveSkewScalar > MAX_SCALAR) {
            revert MarketLogic_InvalidSkewScalar();
        }
        if (_config.negativeSkewScalar <= 0 || _config.negativeSkewScalar > MAX_SCALAR) {
            revert MarketLogic_InvalidSkewScalar();
        }
        // Check negative skew scalar is >= positive skew scalar
        if (_config.negativeSkewScalar < _config.positiveSkewScalar) {
            revert MarketLogic_InvalidSkewScalar();
        }
        // Check Liquidity Scalars are > 0 and <= 100%
        if (_config.positiveLiquidityScalar <= 0 || _config.positiveLiquidityScalar > MAX_SCALAR) {
            revert MarketLogic_InvalidLiquidityScalar();
        }
        if (_config.negativeLiquidityScalar <= 0 || _config.negativeLiquidityScalar > MAX_SCALAR) {
            revert MarketLogic_InvalidLiquidityScalar();
        }
        // Check negative liquidity scalar is >= positive liquidity scalar
        if (_config.negativeLiquidityScalar < _config.positiveLiquidityScalar) {
            revert MarketLogic_InvalidLiquidityScalar();
        }
    }

    function validateAction(
        IVault.State memory _initialState,
        uint256 _amountIn,
        uint256 _amountOut,
        bool _isLongToken,
        bool _isDeposit
    ) internal view {
        // Cache the state after
        IVault.State memory updatedState = IVault(address(this)).getState(_isLongToken);
        // Validate the Vault State Delta
        if (_isDeposit) {
            MarketUtils.validateDeposit(_initialState, updatedState, _amountIn, _isLongToken);
        } else {
            MarketUtils.validateWithdrawal(_initialState, updatedState, _amountIn, _amountOut, _isLongToken);
        }
    }

    /**
     * ============================= Admin Functions =============================
     */
    function batchWithdrawFees(
        address _weth,
        address _usdc,
        address _feeDistributor,
        address _feeReceiver,
        address _poolOwner,
        uint256 _longAccumulatedFees,
        uint256 _shortAccumulatedFees
    ) internal {
        uint256 longFees = _longAccumulatedFees;
        uint256 shortFees = _shortAccumulatedFees;
        // calculate percentages and distribute percentage to owner and feeDistributor
        uint256 longOwnerFees = longFees.percentage(FEES_TO_OWNER);
        uint256 shortOwnerFees = shortFees.percentage(FEES_TO_OWNER);
        uint256 longDistributorFee = longFees - (longOwnerFees * 2); // 2 because 10% to owner and 10% to protocol
        uint256 shortDistributorFee = shortFees - (shortOwnerFees * 2);

        // Send Fees to Distribute to LPs
        IERC20(_weth).approve(_feeDistributor, longDistributorFee);
        IERC20(_usdc).approve(_feeDistributor, shortDistributorFee);
        IFeeDistributor(_feeDistributor).accumulateFees(longDistributorFee, shortDistributorFee);
        // Send Fees to Protocol
        IERC20(_weth).safeTransfer(_feeReceiver, longOwnerFees);
        IERC20(_usdc).safeTransfer(_feeReceiver, shortOwnerFees);
        // Send Fees to Owner
        IERC20(_weth).safeTransfer(_poolOwner, longOwnerFees);
        IERC20(_usdc).safeTransfer(_poolOwner, shortOwnerFees);

        emit FeesWithdrawn(longFees, shortFees);
    }

    /**
     * ============================= Request Functions =============================
     */
    function createRequest(
        EnumerableMap.MarketRequestMap storage requests,
        address _owner,
        address _transferToken, // Token In for Deposits, Out for Withdrawals
        uint256 _amountIn,
        uint256 _executionFee,
        bytes32 _priceRequestKey,
        bytes32 _pnlRequestKey,
        address _weth,
        bool _reverseWrap,
        bool _isDeposit
    ) internal {
        IMarket.Input memory request = IMarket.Input({
            amountIn: _amountIn,
            executionFee: _executionFee,
            owner: _owner,
            requestTimestamp: uint48(block.timestamp),
            isLongToken: _transferToken == _weth,
            reverseWrap: _reverseWrap,
            isDeposit: _isDeposit,
            key: _generateKey(_owner, _transferToken, _amountIn, _isDeposit),
            priceRequestKey: _priceRequestKey,
            pnlRequestKey: _pnlRequestKey
        });
        if (!requests.set(request.key, request)) revert MarketLogic_FailedToAddRequest();
        emit RequestCreated(request.key, _owner, _transferToken, _amountIn, _isDeposit);
    }

    function cancelRequest(
        EnumerableMap.MarketRequestMap storage requests,
        bytes32 _key,
        address _caller,
        address _weth,
        address _usdc,
        address _marketToken
    ) internal returns (address tokenOut, uint256 amountOut, bool shouldUnwrap) {
        IMarket market = IMarket(address(this));
        // Check the Request Exists
        if (!market.requestExists(_key)) revert MarketLogic_InvalidKey();
        // Check the caller owns the request
        IMarket.Input memory request = market.getRequest(_key);
        if (request.owner != _caller) revert MarketLogic_RequestNotOwner();
        // Ensure the request has passed the expiration time
        if (request.requestTimestamp + TIME_TO_EXPIRATION > block.timestamp) revert MarketLogic_RequestNotExpired();
        // Delete the request
        if (!requests.remove(_key)) revert MarketLogic_FailedToRemoveRequest();
        // Set Token Out and Should Unwrap
        if (request.isDeposit) {
            // If is deposit, token out is the token in
            tokenOut = request.isLongToken ? _weth : _usdc;
            shouldUnwrap = request.reverseWrap;
        } else {
            // If is withdrawal, token out is market tokens
            tokenOut = _marketToken;
            shouldUnwrap = false;
        }
        amountOut = request.amountIn;
        // Fire event
        emit RequestCanceled(_key, _caller);
    }

    /**
     * ============================= Market State Update =============================
     */
    function addToken(
        IPriceFeed priceFeed,
        Pool.Storage storage marketStorage,
        Pool.Config calldata _config,
        string memory _ticker,
        bytes calldata _newAllocations,
        bytes32 _priceRequestKey
    ) internal {
        IMarket market = IMarket(address(this));
        if (msg.sender != address(this)) revert MarketLogic_InvalidCaller();
        if (market.getAssetsInMarket() >= MAX_ASSETS) revert MarketLogic_MaxAssetsReached();
        if (market.isAssetInMarket(_ticker)) revert MarketLogic_TokenAlreadyExists();
        // Add asset to storage
        market.addAsset(_ticker);
        // Reallocate
        reallocate(priceFeed, _newAllocations, _priceRequestKey);
        // Initialize Storage
        Pool.initialize(marketStorage, _config);
        emit TokenAdded(_ticker);
    }

    function removeToken(
        IPriceFeed priceFeed,
        string memory _ticker,
        bytes calldata _newAllocations,
        bytes32 _priceRequestKey
    ) internal {
        IMarket market = IMarket(address(this));
        if (msg.sender != address(this)) revert MarketLogic_InvalidCaller();
        if (!market.isAssetInMarket(_ticker)) revert MarketLogic_TokenDoesNotExist();
        uint256 len = market.getAssetsInMarket();
        if (len == 1) revert MarketLogic_MinimumAssetsReached();
        // Remove the Asset
        market.removeAsset(_ticker);
        // Reallocate
        reallocate(priceFeed, _newAllocations, _priceRequestKey);
        // Fire Event
        emit TokenRemoved(_ticker);
    }

    /// @dev - Caller must've requested a price before calling this function
    /// @dev - Price request needs to contain all tickers in the market + long / short tokens, or will revert
    function reallocate(IPriceFeed priceFeed, bytes calldata _allocations, bytes32 _priceRequestKey) internal {
        IMarket market = IMarket(address(this));

        // Validate the Price Request
        uint48 requestTimestamp = Oracle.getRequestTimestamp(priceFeed, _priceRequestKey);

        // Fetch token prices
        uint256 longTokenPrice = Oracle.getPrice(priceFeed, LONG_TICKER, requestTimestamp);
        uint256 shortTokenPrice = Oracle.getPrice(priceFeed, SHORT_TICKER, requestTimestamp);

        // Copy tickers to memory
        string[] memory assetTickers = market.getTickers();
        if (_allocations.length != assetTickers.length) revert MarketLogic_AllocationLength();

        uint8 total = 0;

        // Iterate over each byte in allocations calldata
        for (uint256 i = 0; i < _allocations.length;) {
            uint8 allocationValue = uint8(_allocations[i]);
            // Update Storage
            market.setAllocationShare(assetTickers[i], allocationValue);
            // Check the allocation value -> new max open interest must be > current open interest
            _validateOpenInterest(market, priceFeed, assetTickers[i], requestTimestamp, longTokenPrice, shortTokenPrice);
            // Increment total
            total += allocationValue;
            unchecked {
                ++i;
            }
        }

        if (total != TOTAL_ALLOCATION) revert MarketLogic_InvalidCumulativeAllocation();
    }

    /**
     * ============================= Token Transfers =============================
     */
    function transferOutTokens(
        address _to,
        address _tokenOut,
        uint256 _amount,
        uint256 _availableTokens,
        bool _isLongToken,
        bool _shouldUnwrap
    ) internal {
        if (_amount > _availableTokens) revert MarketLogic_InsufficientAvailableTokens();
        if (_isLongToken) {
            if (_shouldUnwrap) {
                IWETH(_tokenOut).withdraw(_amount);
                SafeTransferLib.safeTransferETH(_to, _amount);
            } else {
                IERC20(_tokenOut).safeTransfer(_to, _amount);
            }
        } else {
            IERC20(_tokenOut).safeTransfer(_to, _amount);
        }
    }

    /**
     * ========================= Private Functions =========================
     */
    function _validateOpenInterest(
        IMarket market,
        IPriceFeed priceFeed,
        string memory _ticker,
        uint48 _requestTimestamp,
        uint256 _longSignedPrice,
        uint256 _shortSignedPrice
    ) private view {
        // Get the index price and the index base unit
        uint256 indexPrice = Oracle.getPrice(priceFeed, _ticker, _requestTimestamp);
        uint256 indexBaseUnit = Oracle.getBaseUnit(priceFeed, _ticker);
        // Get the Long Max Oi
        uint256 longMaxOi =
            MarketUtils.getAvailableOiUsd(market, _ticker, indexPrice, _longSignedPrice, indexBaseUnit, true);
        (uint256 longOi, uint256 shortOi) = market.getOpenInterestValues(_ticker);
        // Get the Current oi
        if (longMaxOi < longOi) revert MarketLogic_InvalidAllocation();
        // Get the Short Max Oi
        uint256 shortMaxOi =
            MarketUtils.getAvailableOiUsd(market, _ticker, indexPrice, _shortSignedPrice, indexBaseUnit, false);
        // Get the Current oi
        if (shortMaxOi < shortOi) revert MarketLogic_InvalidAllocation();
    }

    function _generateKey(address _owner, address _tokenIn, uint256 _tokenAmount, bool _isDeposit)
        private
        view
        returns (bytes32)
    {
        return keccak256(abi.encode(_owner, _tokenIn, _tokenAmount, _isDeposit, block.timestamp));
    }
}
