// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IMarket} from "./interfaces/IMarket.sol";
import {IMarketToken, IERC20} from "./interfaces/IMarketToken.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IFeeDistributor} from "../rewards/interfaces/IFeeDistributor.sol";
import {IPriceFeed} from "../oracle/interfaces/IPriceFeed.sol";
import {ITradeStorage} from "../positions/interfaces/ITradeStorage.sol";
import {MarketUtils} from "./MarketUtils.sol";
import {Funding} from "../libraries/Funding.sol";
import {Borrowing} from "../libraries/Borrowing.sol";
import {IWETH} from "../tokens/interfaces/IWETH.sol";
import {MathUtils} from "../libraries/MathUtils.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {EnumerableMap} from "../libraries/EnumerableMap.sol";

library MarketLogic {
    using SafeERC20 for IERC20;
    using SafeERC20 for IMarketToken;
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
    error MarketLogic_InvalidPriceRequest();
    error MarketLogic_InvalidCumulativeAllocation();
    error MarketLogic_InvalidAllocation();
    error MarketLogic_InvalidCaller();
    error MarketLogic_MaxAssetsReached();
    error MarketLogic_TokenAlreadyExists();
    error MarketLogic_FailedToAddAssetId();
    error MarketLogic_TokenDoesNotExist();
    error MarketLogic_MinimumAssetsReached();
    error MarketLogic_FailedToRemoveAssetId();
    error MarketLogic_FailedToTransferETH();
    error MarketLogic_InvalidOpenInterestDelta();
    error MarketLogic_FailedToRemoveRequest();
    error MarketLogic_FailedToAddRequest();

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

    uint256 private constant BITMASK_16 = type(uint256).max >> (256 - 16);
    uint16 private constant TOTAL_ALLOCATION = 10000;
    // Max 100 assets per market (could fit 12 more in last uint256, but 100 used for simplicity)
    // Fits 16 allocations per uint256
    uint8 private constant MAX_ASSETS = 100;
    uint32 private constant MIN_LEVERAGE = 100; // Min 1x Leverage
    uint32 private constant MAX_LEVERAGE = 1000_00; // Max 1000x leverage
    uint64 private constant MIN_RESERVE_FACTOR = 0.1e18; // 10% reserve factor
    uint64 private constant MAX_RESERVE_FACTOR = 0.5e18; // 50% reserve factor
    int64 private constant MIN_VELOCITY = 0.001e18; // 0.1% per day
    int64 private constant MAX_VELOCITY = 0.2e18; // 20% per day
    int256 private constant MIN_SKEW_SCALE = 1000e30; // $1000
    int256 private constant MAX_SKEW_SCALE = 10_000_000_000e30; // $10 Bn
    int64 private constant SIGNED_SCALAR = 1e18;
    uint64 private constant SCALING_FACTOR = 1e18;
    uint48 private constant TIME_TO_EXPIRATION = 1 minutes;
    uint256 private constant LONG_BASE_UNIT = 1e18;
    uint256 private constant SHORT_BASE_UNIT = 1e6;
    string private constant LONG_TICKER = "WETH";
    string private constant SHORT_TICKER = "USDC";

    // The rest of the 80% of the fees go to the FeeDistributor to distribute to LPs
    uint256 private constant FEES_TO_OWNER = 0.1e18; // 10% to Owner
    uint256 private constant FEES_TO_PROTOCOL = 0.1e18; // 10% to Protocol

    modifier validAction(uint256 _amountIn, uint256 _amountOut, bool _isLongToken, bool _isDeposit) {
        // Cache the State Before
        IMarket.State memory initialState = IMarket(address(this)).getState(_isLongToken);
        _;
        // Cache the state after
        IMarket.State memory updatedState = IMarket(address(this)).getState(_isLongToken);
        // Validate the Vault State Delta
        if (_isDeposit) {
            MarketUtils.validateDeposit(initialState, updatedState, _amountIn, _isLongToken);
        } else {
            MarketUtils.validateWithdrawal(initialState, updatedState, _amountIn, _amountOut, _isLongToken);
        }
    }

    // @audit - can make private and move validation function into here
    function validateConfig(IMarket.Config calldata _config) internal pure {
        /* 1. Validate the initial inputs */
        // Check Leverage is within bounds
        if (_config.maxLeverage < MIN_LEVERAGE || _config.maxLeverage > MAX_LEVERAGE) {
            revert MarketLogic_InvalidLeverage();
        }
        // Check the Reserve Factor is within bounds
        if (_config.reserveFactor < MIN_RESERVE_FACTOR || _config.reserveFactor > MAX_RESERVE_FACTOR) {
            revert MarketLogic_InvalidReserveFactor();
        }
        /* 2. Validate the Funding Values */
        // Check the Max Velocity is within bounds
        if (_config.funding.maxVelocity < MIN_VELOCITY || _config.funding.maxVelocity > MAX_VELOCITY) {
            revert MarketLogic_InvalidMaxVelocity();
        }
        // Check the Skew Scale is within bounds
        if (_config.funding.skewScale < MIN_SKEW_SCALE || _config.funding.skewScale > MAX_SKEW_SCALE) {
            revert MarketLogic_InvalidSkewScale();
        }
        /* 3. Validate Impact Values */
        // Check Skew Scalars are > 0 and <= 100%
        if (_config.impact.positiveSkewScalar <= 0 || _config.impact.positiveSkewScalar > SIGNED_SCALAR) {
            revert MarketLogic_InvalidSkewScalar();
        }
        if (_config.impact.negativeSkewScalar <= 0 || _config.impact.negativeSkewScalar > SIGNED_SCALAR) {
            revert MarketLogic_InvalidSkewScalar();
        }
        // Check negative skew scalar is >= positive skew scalar
        if (_config.impact.negativeSkewScalar < _config.impact.positiveSkewScalar) {
            revert MarketLogic_InvalidSkewScalar();
        }
        // Check Liquidity Scalars are > 0 and <= 100%
        if (_config.impact.positiveLiquidityScalar <= 0 || _config.impact.positiveLiquidityScalar > SIGNED_SCALAR) {
            revert MarketLogic_InvalidLiquidityScalar();
        }
        if (_config.impact.negativeLiquidityScalar <= 0 || _config.impact.negativeLiquidityScalar > SIGNED_SCALAR) {
            revert MarketLogic_InvalidLiquidityScalar();
        }
        // Check negative liquidity scalar is >= positive liquidity scalar
        if (_config.impact.negativeLiquidityScalar < _config.impact.positiveLiquidityScalar) {
            revert MarketLogic_InvalidLiquidityScalar();
        }
    }

    function batchWithdrawFees(
        address _weth,
        address _usdc,
        address _feeDistributor,
        address _feeReceiver,
        address _poolOwner,
        uint256 _longAccumulatedFees,
        uint256 _shortAccumulatedFees
    ) external {
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
                (bool success,) = _to.call{value: _amount}("");
                if (!success) revert MarketLogic_FailedToTransferETH();
            } else {
                IERC20(_tokenOut).safeTransfer(_to, _amount);
            }
        } else {
            IERC20(_tokenOut).safeTransfer(_to, _amount);
        }
    }

    function createRequest(
        EnumerableMap.MarketRequestMap storage requests,
        address _owner,
        address _transferToken, // Token In for Deposits, Out for Withdrawals
        uint256 _amountIn,
        uint256 _executionFee,
        bytes32 _priceRequestId,
        bytes32 _pnlRequestId,
        address _weth,
        bool _reverseWrap,
        bool _isDeposit
    ) external {
        IMarket.Input memory request = IMarket.Input({
            amountIn: _amountIn,
            executionFee: _executionFee,
            owner: _owner,
            expirationTimestamp: uint48(block.timestamp) + TIME_TO_EXPIRATION,
            isLongToken: _transferToken == _weth,
            reverseWrap: _reverseWrap,
            isDeposit: _isDeposit,
            key: _generateKey(_owner, _transferToken, _amountIn, _isDeposit),
            priceRequestId: _priceRequestId,
            pnlRequestId: _pnlRequestId
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
    ) external returns (address tokenOut, uint256 amountOut, bool shouldUnwrap) {
        IMarket market = IMarket(address(this));
        // Check the Request Exists
        if (!market.requestExists(_key)) revert MarketLogic_InvalidKey();
        // Check the caller owns the request
        IMarket.Input memory request = market.getRequest(_key);
        if (request.owner != _caller) revert MarketLogic_RequestNotOwner();
        // Ensure the request has passed the expiration time
        if (request.expirationTimestamp > block.timestamp) revert MarketLogic_RequestNotExpired();
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

    function addToken(
        IPriceFeed priceFeed,
        IMarket.MarketStorage storage marketStorage,
        IMarket.Config calldata _config,
        string memory _ticker,
        uint256[] calldata _newAllocations,
        bytes32 _priceRequestId
    ) internal {
        IMarket market = IMarket(address(this));
        if (msg.sender != address(this)) revert MarketLogic_InvalidCaller();
        if (market.getAssetsInMarket() >= MAX_ASSETS) revert MarketLogic_MaxAssetsReached();
        if (market.isAssetInMarket(_ticker)) revert MarketLogic_TokenAlreadyExists();
        // Valdiate Config
        validateConfig(_config);
        // Add asset to storage
        market.addAsset(_ticker);
        // Reallocate
        reallocate(priceFeed, _newAllocations, _priceRequestId);
        // Initialize Storage
        marketStorage.config = _config;
        marketStorage.funding.lastFundingUpdate = uint48(block.timestamp);
        marketStorage.borrowing.lastBorrowUpdate = uint48(block.timestamp);
        emit TokenAdded(_ticker);
    }

    function removeToken(
        IPriceFeed priceFeed,
        string memory _ticker,
        uint256[] calldata _newAllocations,
        bytes32 _priceRequestId
    ) internal {
        IMarket market = IMarket(address(this));
        if (msg.sender != address(this)) revert MarketLogic_InvalidCaller();
        if (!market.isAssetInMarket(_ticker)) revert MarketLogic_TokenDoesNotExist();
        uint256 len = market.getAssetsInMarket();
        if (len == 1) revert MarketLogic_MinimumAssetsReached();
        // Remove the Asset
        market.removeAsset(_ticker);
        // Reallocate
        reallocate(priceFeed, _newAllocations, _priceRequestId);
        // Fire Event
        emit TokenRemoved(_ticker);
    }

    /// @dev - Caller must've requested a price before calling this function
    /// @dev - Price request needs to contain all tickers in the market + long / short tokens, or will revert
    // @audit - can we use a storage pointer for this?
    function reallocate(IPriceFeed priceFeed, uint256[] memory _allocations, bytes32 _priceRequestId) internal {
        IMarket market = IMarket(address(this));
        if (msg.sender != address(this)) revert MarketLogic_InvalidCaller();
        // Fetch token prices
        if (priceFeed.getRequester(_priceRequestId) != msg.sender) revert MarketLogic_InvalidPriceRequest();
        uint256 longTokenPrice = priceFeed.getPrices(_priceRequestId, LONG_TICKER).med;
        uint256 shortTokenPrice = priceFeed.getPrices(_priceRequestId, SHORT_TICKER).med;
        // Copy tickers to memory
        string[] memory assetTickers = market.getTickers();
        uint256 assetLen = assetTickers.length;
        uint256 total;
        uint256 len = _allocations.length;
        for (uint256 i = 0; i < len;) {
            uint256 allocation = _allocations[i];
            for (uint256 j = 0; j < 16 && i * 16 + j < assetLen;) {
                // Extract Allocation Value using bitshifting
                uint256 allocationValue = (allocation >> (240 - j * 16)) & BITMASK_16;
                // Increment Total
                total += allocationValue;
                // Update Storage
                market.setAllocationShare(assetTickers[i * 16 + j], allocationValue);
                // Check the allocation value -> new max open interest must be > current open interest
                _validateOpenInterest(
                    market, priceFeed, assetTickers[i * 16 + j], _priceRequestId, longTokenPrice, shortTokenPrice
                );
                // Iterate
                unchecked {
                    ++j;
                }
            }
            unchecked {
                ++i;
            }
        }

        if (total != TOTAL_ALLOCATION) revert MarketLogic_InvalidCumulativeAllocation();
        // Clear the prices
        priceFeed.clearSignedPrices(market, _priceRequestId);
    }

    function executeDeposit(
        IPriceFeed priceFeed,
        EnumerableMap.MarketRequestMap storage requests,
        IMarket.ExecuteDeposit calldata _params,
        address _tokenIn
    ) internal validAction(_params.deposit.amountIn, 0, _params.deposit.isLongToken, true) {
        if (_params.market != IMarket(address(this))) revert MarketLogic_InvalidCaller();
        // Transfer deposit tokens from msg.sender
        IERC20(_tokenIn).safeTransferFrom(msg.sender, address(this), _params.deposit.amountIn);
        // Delete Deposit Request -> keep
        if (!requests.remove(_params.key)) revert MarketLogic_FailedToRemoveRequest();

        (uint256 afterFeeAmount, uint256 fee, uint256 mintAmount) = MarketUtils.calculateDepositAmounts(_params);

        // update storage -> keep
        _params.market.accumulateFees(fee, _params.deposit.isLongToken);
        _params.market.updatePoolBalance(afterFeeAmount, _params.deposit.isLongToken, true);

        // Clear Signed Prices and Pnl
        priceFeed.clearSignedPrices(_params.market, _params.deposit.priceRequestId);
        priceFeed.clearCumulativePnl(_params.market, _params.deposit.pnlRequestId);

        emit DepositExecuted(_params.key, _params.deposit.owner, _tokenIn, _params.deposit.amountIn, mintAmount);
        // mint tokens to user
        IMarketToken(_params.marketToken).mint(_params.deposit.owner, mintAmount);
    }

    function executeWithdrawal(
        IPriceFeed priceFeed,
        EnumerableMap.MarketRequestMap storage requests,
        IMarket.ExecuteWithdrawal calldata _params,
        address _tokenOut,
        uint256 _availableTokens // tokenBalance - tokensReserved
    ) internal validAction(_params.withdrawal.amountIn, _params.amountOut, _params.withdrawal.isLongToken, false) {
        if (_params.market != IMarket(address(this))) revert MarketLogic_InvalidCaller();
        // Transfer Market Tokens in from msg.sender
        IMarketToken(_params.marketToken).safeTransferFrom(msg.sender, address(this), _params.withdrawal.amountIn);
        // Delete the Withdrawal from Storage
        if (!requests.remove(_params.key)) revert MarketLogic_FailedToRemoveRequest();

        // Calculate Amount Out after Fee
        uint256 transferAmountOut = MarketUtils.calculateWithdrawalAmounts(_params);

        // Calculate amount out / aum before burning
        IMarketToken(_params.marketToken).burn(address(this), _params.withdrawal.amountIn);

        // accumulate the fee
        _params.market.accumulateFees(_params.amountOut - transferAmountOut, _params.withdrawal.isLongToken);
        // validate whether the pool has enough tokens
        if (transferAmountOut > _availableTokens) revert MarketLogic_InsufficientAvailableTokens();
        // decrease the pool
        _params.market.updatePoolBalance(_params.amountOut, _params.withdrawal.isLongToken, false);

        // Clear Signed Prices and Pnl
        priceFeed.clearSignedPrices(_params.market, _params.withdrawal.priceRequestId);
        priceFeed.clearCumulativePnl(_params.market, _params.withdrawal.pnlRequestId);

        emit WithdrawalExecuted(
            _params.key, _params.withdrawal.owner, _tokenOut, _params.withdrawal.amountIn, transferAmountOut
        );
        // transfer tokens to user
        transferOutTokens(
            _params.withdrawal.owner,
            _tokenOut,
            transferAmountOut,
            _availableTokens,
            _params.withdrawal.isLongToken,
            _params.withdrawal.reverseWrap
        );
    }

    function updateMarketState(
        IMarket.MarketStorage storage marketStorage,
        string calldata _ticker,
        uint256 _sizeDelta,
        uint256 _indexPrice,
        uint256 _impactedPrice,
        bool _isLong,
        bool _isIncrease
    ) internal {
        IMarket market = IMarket(address(this));
        // If invalid ticker, revert
        if (!market.isAssetInMarket(_ticker)) revert MarketLogic_InvalidTicker();
        // 1. Depends on Open Interest Delta to determine Skew
        marketStorage.funding = Funding.updateState(market, marketStorage.funding, _ticker, _indexPrice);
        if (_sizeDelta != 0) {
            // Use Impacted Price for Entry
            // 2. Relies on Open Interest Delta
            _updateWeightedAverages(
                marketStorage,
                market,
                _ticker,
                _impactedPrice == 0 ? _indexPrice : _impactedPrice, // If no price impact, set to the index price
                _isIncrease ? int256(_sizeDelta) : -int256(_sizeDelta),
                _isLong
            );
            // 3. Updated pre-borrowing rate if size delta > 0
            if (_isIncrease) {
                if (_isLong) {
                    marketStorage.openInterest.longOpenInterest += _sizeDelta;
                } else {
                    marketStorage.openInterest.shortOpenInterest += _sizeDelta;
                }
            } else {
                if (_isLong) {
                    marketStorage.openInterest.longOpenInterest -= _sizeDelta;
                } else {
                    marketStorage.openInterest.shortOpenInterest -= _sizeDelta;
                }
            }
        }
        // 4. Relies on Updated Open interest
        marketStorage.borrowing = Borrowing.updateState(market, marketStorage.borrowing, _ticker, _isLong);
        // Fire Event
        emit MarketStateUpdated(_ticker, _isLong);
    }

    /**
     * Updates the weighted average values for the market. Both rely on the market condition pre-open interest update.
     */
    function _updateWeightedAverages(
        IMarket.MarketStorage storage marketStorage,
        IMarket market,
        string calldata _ticker,
        uint256 _priceUsd,
        int256 _sizeDeltaUsd,
        bool _isLong
    ) private {
        if (_priceUsd == 0) revert MarketLogic_PriceIsZero();
        if (_sizeDeltaUsd == 0) return;

        if (_isLong) {
            marketStorage.pnl.longAverageEntryPriceUsd = MarketUtils.calculateWeightedAverageEntryPrice(
                marketStorage.pnl.longAverageEntryPriceUsd,
                marketStorage.openInterest.longOpenInterest,
                _sizeDeltaUsd,
                _priceUsd
            );
            marketStorage.borrowing.weightedAvgCumulativeLong =
                Borrowing.getNextAverageCumulative(market, _ticker, _sizeDeltaUsd, true);
        } else {
            marketStorage.pnl.shortAverageEntryPriceUsd = MarketUtils.calculateWeightedAverageEntryPrice(
                marketStorage.pnl.shortAverageEntryPriceUsd,
                marketStorage.openInterest.shortOpenInterest,
                _sizeDeltaUsd,
                _priceUsd
            );
            marketStorage.borrowing.weightedAvgCumulativeShort =
                Borrowing.getNextAverageCumulative(market, _ticker, _sizeDeltaUsd, false);
        }
    }

    function _validateOpenInterest(
        IMarket market,
        IPriceFeed priceFeed,
        string memory _ticker,
        bytes32 _priceRequestId,
        uint256 _longSignedPrice,
        uint256 _shortSignedPrice
    ) private view {
        // Get the index price and the index base unit
        uint256 indexPrice = priceFeed.getPrices(_priceRequestId, _ticker).med;
        uint256 indexBaseUnit = priceFeed.baseUnits(_ticker);
        // Get the Long Max Oi
        uint256 longMaxOi = MarketUtils.getAvailableOiUsd(
            market, _ticker, indexPrice, _longSignedPrice, indexBaseUnit, LONG_BASE_UNIT, true
        );
        IMarket.OpenInterestValues memory oi = market.getStorage(_ticker).openInterest;
        // Get the Current oi
        if (longMaxOi < oi.longOpenInterest) revert MarketLogic_InvalidAllocation();
        // Get the Short Max Oi
        uint256 shortMaxOi = MarketUtils.getAvailableOiUsd(
            market, _ticker, indexPrice, _shortSignedPrice, indexBaseUnit, SHORT_BASE_UNIT, false
        );
        // Get the Current oi
        if (shortMaxOi < oi.shortOpenInterest) revert MarketLogic_InvalidAllocation();
    }

    function _generateKey(address _owner, address _tokenIn, uint256 _tokenAmount, bool _isDeposit)
        private
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(_owner, _tokenIn, _tokenAmount, _isDeposit));
    }
}
