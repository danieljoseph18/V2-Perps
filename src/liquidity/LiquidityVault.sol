// SPDX-License-Identifier: BUSL-1.1

pragma solidity 0.8.23;

import {ILiquidityVault} from "./interfaces/ILiquidityVault.sol";
import {ERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {RoleValidation} from "../access/RoleValidation.sol";
import {Deposit} from "./Deposit.sol";
import {Withdrawal} from "./Withdrawal.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {ReentrancyGuard} from "@solmate/utils/ReentrancyGuard.sol";
import {IPriceOracle} from "../oracle/interfaces/IPriceOracle.sol";
import {IDataOracle} from "../oracle/interfaces/IDataOracle.sol";
import {PriceImpact} from "../libraries/PriceImpact.sol";
import {Fee} from "../libraries/Fee.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

// Stores all funds for the protocol
/// @dev Needs Vault Role
contract LiquidityVault is ILiquidityVault, ERC20, RoleValidation, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using Address for address payable;

    uint256 public constant MAX_SLIPPAGE = 9999; // 99.99%
    uint256 public constant SCALING_FACTOR = 1e18;

    IERC20 public immutable LONG_TOKEN;
    IERC20 public immutable SHORT_TOKEN;
    uint8 private immutable LONG_TOKEN_DECIMALS;
    uint8 private immutable SHORT_TOKEN_DECIMALS;

    IPriceOracle priceOracle;
    IDataOracle dataOracle;
    address marketMaker;

    uint32 minTimeToExpiration;
    uint256 minExecutionFee; // in Wei
    uint256 depositFee; // 18 D.P
    uint256 withdrawalFee; // 18 D.P

    uint256 private longTokenBalance;
    uint256 private shortTokenBalance;
    uint256 private accumulatedFees;
    uint256 private longTokensReserved;
    uint256 private shortTokensReserved;

    bool isInitialised;

    mapping(bytes32 => Deposit.Data) public depositRequests;
    EnumerableSet.Bytes32Set private depositKeys;
    mapping(bytes32 => Withdrawal.Data) public withdrawalRequests;
    EnumerableSet.Bytes32Set private withdrawalKeys;
    mapping(address user => mapping(bool isLong => uint256 reserved)) public reservedAmounts;

    constructor(
        IERC20 _longToken,
        IERC20 _shortToken,
        uint8 _longTokenDecimals,
        uint8 _shortTokenDecimals,
        string memory _name,
        string memory _symbol,
        address _roleStorage
    ) ERC20(_name, _symbol) RoleValidation(_roleStorage) {
        LONG_TOKEN = _longToken;
        SHORT_TOKEN = _shortToken;
        LONG_TOKEN_DECIMALS = _longTokenDecimals;
        SHORT_TOKEN_DECIMALS = _shortTokenDecimals;
    }

    function initialise(
        IPriceOracle _priceOracle,
        IDataOracle _dataOracle,
        address _marketMaker,
        uint32 _minTimeToExpiration,
        uint256 _minExecutionFee,
        uint256 _depositFee,
        uint256 _withdrawalFee
    ) external onlyAdmin {
        require(!isInitialised, "LiquidityVault: already initialised");
        priceOracle = _priceOracle;
        dataOracle = _dataOracle;
        marketMaker = _marketMaker;
        minExecutionFee = _minExecutionFee;
        minTimeToExpiration = _minTimeToExpiration;
        depositFee = _depositFee;
        withdrawalFee = _withdrawalFee;
    }

    function updateFees(uint256 _minExecutionFee, uint256 _depositFee, uint256 _withdrawalFee)
        external
        onlyConfigurator
    {
        minExecutionFee = _minExecutionFee;
        depositFee = _depositFee;
        withdrawalFee = _withdrawalFee;
    }

    ///////////////////////////////
    // TRADING RELATED FUNCTIONS //
    ///////////////////////////////

    // q - do we need any input validation for _user?
    // e.g user could be a contract, could he reject this function call?
    // q - what must hold true in order to transfer profit to a user???
    function transferPositionProfit(address _user, uint256 _amount, bool _isLong) external onlyTradeStorage {
        require(_amount != 0, "LV: Invalid Profit Amount");
        require(_user != address(0), "LV: Zero Address");
        // check enough in pool to transfer position
        // @audit - is this check correct?
        if (_isLong) {
            require(_amount <= longTokenBalance - longTokensReserved, "LV: Insufficient Funds");
            longTokenBalance -= _amount;
            IERC20(address(LONG_TOKEN)).safeTransfer(_user, _amount);
        } else {
            require(_amount <= shortTokenBalance - shortTokensReserved, "LV: Insufficient Funds");
            shortTokenBalance -= _amount;
            IERC20(address(SHORT_TOKEN)).safeTransfer(_user, _amount);
        }
        emit ProfitTransferred(_user, _amount, _isLong);
    }

    function accumulateFees(uint256 _amount) external onlyFeeAccumulator {
        require(_amount != 0, "LV: Invalid Acc Fee");
        accumulatedFees += _amount;
        emit FeesAccumulated(_amount);
    }

    /// @dev Used to reserve / unreserve funds for open positions
    // q - do we need a reserve factor to cap reserves to a % of the available liquidity
    function updateReservation(address _user, int256 _amount, bool _isLong) external onlyTradeStorage {
        require(_amount != 0, "LV: Invalid Res Amount");
        uint256 amt;
        if (_amount > 0) {
            amt = uint256(_amount);
            if (_isLong) {
                require(amt <= longTokenBalance, "LV: Insufficient Long Liq");
                longTokenBalance += amt;
                reservedAmounts[_user][true] += amt;
            } else {
                require(amt <= shortTokenBalance, "LV: Insufficient Short Liq");
                shortTokenBalance += amt;
                reservedAmounts[_user][false] += amt;
            }
        } else {
            amt = uint256(-_amount);
            if (_isLong) {
                require(reservedAmounts[_user][true] >= amt, "LV: Insufficient Reserves");
                require(longTokenBalance >= amt, "LV: Insufficient Long Liq");
                longTokenBalance -= amt;
                reservedAmounts[_user][true] -= amt;
            } else {
                require(reservedAmounts[_user][false] >= amt, "LV: Insufficient Reserves");
                require(shortTokenBalance >= amt, "LV: Insufficient Short Liq");
                shortTokenBalance -= amt;
                reservedAmounts[_user][false] -= amt;
            }
        }
        emit LiquidityReserved(_user, amt, _amount > 0, _isLong);
    }

    ///////////////////////
    // DEPOSIT EXECUTION //
    ///////////////////////

    function executeDeposit(bytes32 _key) external nonReentrant onlyKeeper {
        // fetch and cache
        require(depositKeys.contains(_key), "LiquidityVault: invalid key");
        Deposit.Data memory data = depositRequests[_key];
        // remove from storage
        depositKeys.remove(_key);
        delete depositRequests[_key];
        // get price signed to the block number of the request
        uint256 longTokenPrice = priceOracle.getSignedPrice(data.params.tokenIn, data.blockNumber);
        uint256 shortTokenPrice = priceOracle.getSignedPrice(data.params.tokenIn, data.blockNumber);
        // calculate the value of the assets provided
        bool isLongToken = data.params.tokenIn == address(LONG_TOKEN);
        // calculate price impact
        uint256 impactedPrice = PriceImpact.executeForMarket(
            PriceImpact.Params({
                longTokenBalance: longTokenBalance,
                shortTokenBalance: shortTokenBalance,
                longTokenPrice: longTokenPrice,
                shortTokenPrice: shortTokenPrice,
                amount: data.params.amountIn,
                isIncrease: true,
                isLongToken: isLongToken,
                longTokenDecimals: LONG_TOKEN_DECIMALS,
                shortTokenDecimals: SHORT_TOKEN_DECIMALS,
                marketMaker: marketMaker,
                marketKey: keccak256(abi.encode(data.params.tokenIn))
            })
        );
        // calculate fees
        uint256 fee = Fee.calculateForDeposit(data.params.amountIn, depositFee);
        // calculate amount remaining after fee and price impact
        uint256 remaining = data.params.amountIn - fee;

        // update storage
        if (isLongToken) {
            longTokenBalance += remaining;
        } else {
            shortTokenBalance += remaining;
        }
        accumulatedFees += fee;

        // send execution fee to keeper
        payable(msg.sender).sendValue(data.params.executionFee);

        // mint market tokens to the user
        uint256 mintAmount = _calculateMintAmount(
            _calculateUsdValue(isLongToken, impactedPrice, remaining), longTokenPrice, shortTokenPrice
        );
        _mint(data.params.owner, mintAmount);
        // fire event
        emit DepositExecuted(_key, data.params.owner, data.params.tokenIn, data.params.amountIn, mintAmount);
    }

    //////////////////////////
    // WITHDRAWAL EXECUTION //
    //////////////////////////

    // @audit - review
    function executeWithdrawal(bytes32 _key) external nonReentrant onlyKeeper {
        // fetch and cache
        require(withdrawalKeys.contains(_key), "LiquidityVault: invalid key");
        Withdrawal.Data memory data = withdrawalRequests[_key];

        _burn(msg.sender, data.params.marketTokenAmountIn);
        // remove from storage
        withdrawalKeys.remove(_key);
        delete withdrawalRequests[_key];
        // get price signed to the block number of the request
        uint256 longTokenPrice = priceOracle.getSignedPrice(data.params.tokenOut, data.blockNumber);
        uint256 shortTokenPrice = priceOracle.getSignedPrice(data.params.tokenOut, data.blockNumber);
        // calculate the value of the assets provided
        bool isLongToken = data.params.tokenOut == address(LONG_TOKEN);
        // calculate price impact
        uint256 impactedPrice = PriceImpact.executeForMarket(
            PriceImpact.Params({
                longTokenBalance: longTokenBalance,
                shortTokenBalance: shortTokenBalance,
                longTokenPrice: longTokenPrice,
                shortTokenPrice: shortTokenPrice,
                amount: data.params.marketTokenAmountIn,
                isIncrease: false,
                isLongToken: isLongToken,
                longTokenDecimals: LONG_TOKEN_DECIMALS,
                shortTokenDecimals: SHORT_TOKEN_DECIMALS,
                marketMaker: marketMaker,
                marketKey: keccak256(abi.encode(data.params.tokenOut))
            })
        );

        uint256 amountOut = _calculateAmountOut(
            data.params.tokenOut, data.params.marketTokenAmountIn, longTokenPrice, shortTokenPrice, impactedPrice
        );

        // calculate fees
        uint256 fee = Fee.calculateForWithdrawal(amountOut, withdrawalFee);
        // calculate amount remaining after fee and price impact
        uint256 remaining = amountOut - fee;

        // update storage
        if (isLongToken) {
            longTokenBalance -= amountOut;
        } else {
            shortTokenBalance -= amountOut;
        }
        accumulatedFees += fee;

        // send execution fee to keeper
        payable(msg.sender).sendValue(data.params.executionFee);

        // transfer tokens to user
        IERC20(data.params.tokenOut).safeTransfer(data.params.owner, remaining);

        // fire event
        emit WithdrawalExecuted(
            _key, data.params.owner, data.params.tokenOut, data.params.marketTokenAmountIn, remaining
        );
    }

    //////////////////////
    // DEPOSIT CREATION //
    //////////////////////

    // Function to create a deposit request
    // Note -> need to add ability to create deposit in eth
    function createDeposit(Deposit.Params memory _params) external payable nonReentrant {
        require(_params.executionFee >= minExecutionFee, "LiquidityVault: execution fee too low");
        require(msg.value == _params.executionFee, "LiquidityVault: invalid execution fee");
        require(
            _params.tokenIn == address(LONG_TOKEN) || _params.tokenIn == address(SHORT_TOKEN),
            "LiquidityVault: invalid token"
        );
        require(_params.owner == msg.sender, "LiquidityVault: invalid owner");
        require(_params.maxSlippage < MAX_SLIPPAGE, "LiquidityVault: invalid slippage");

        // Transfer tokens from user to this contract
        IERC20(_params.tokenIn).safeTransferFrom(_params.owner, address(this), _params.amountIn);

        // Store the request -> Use Block.number as a nonce
        uint32 blockNumber = uint32(block.number);
        Deposit.Data memory deposit = Deposit.Data({
            params: _params,
            blockNumber: blockNumber,
            expirationTimestamp: uint32(block.timestamp) + minTimeToExpiration
        });

        // Request Required Data for the Block
        dataOracle.requestBlockData(blockNumber);

        bytes32 key = Deposit.generateKey(_params.owner, _params.tokenIn, _params.amountIn, deposit.blockNumber);

        depositKeys.add(key);
        depositRequests[key] = deposit;
        emit DepositRequestCreated(key, _params.owner, _params.tokenIn, _params.amountIn, deposit.blockNumber);
    }

    // Request must be expired for a user to cancel it
    function cancelDeposit(bytes32 _key) external nonReentrant {
        Deposit.Data memory deposit = depositRequests[_key];
        require(deposit.params.owner == msg.sender, "LiquidityVault: invalid owner");
        require(depositKeys.contains(_key), "LiquidityVault: invalid key");
        require(deposit.expirationTimestamp < block.timestamp, "LiquidityVault: deposit not expired");

        depositKeys.remove(_key);
        delete depositRequests[_key];

        // Transfer tokens back to user
        IERC20(deposit.params.tokenIn).safeTransfer(msg.sender, deposit.params.amountIn);

        emit DepositRequestCancelled(_key, deposit.params.owner, deposit.params.tokenIn, deposit.params.amountIn);
    }

    /////////////////////////
    // WITHDRAWAL CREATION //
    /////////////////////////

    // Function to create a withdrawal request
    function createWithdrawal(Withdrawal.Params memory _params) external payable nonReentrant {
        require(_params.executionFee >= minExecutionFee, "LiquidityVault: execution fee too low");
        require(msg.value == _params.executionFee, "LiquidityVault: invalid execution fee");
        require(
            _params.tokenOut == address(LONG_TOKEN) || _params.tokenOut == address(SHORT_TOKEN),
            "LiquidityVault: invalid token"
        );
        require(_params.owner == msg.sender, "LiquidityVault: invalid owner");
        require(_params.maxSlippage < MAX_SLIPPAGE, "LiquidityVault: invalid slippage");

        // transfer market tokens to contract
        IERC20(address(this)).safeTransferFrom(_params.owner, address(this), _params.marketTokenAmountIn);

        // Store the request -> Use Block.number as a nonce
        uint32 blockNumber = uint32(block.number);
        Withdrawal.Data memory withdrawal = Withdrawal.Data({
            params: _params,
            blockNumber: blockNumber,
            expirationTimestamp: uint32(block.timestamp) + minTimeToExpiration
        });

        // Request Required Data for the Block
        dataOracle.requestBlockData(blockNumber);

        bytes32 key =
            Withdrawal.generateKey(_params.owner, _params.tokenOut, _params.marketTokenAmountIn, withdrawal.blockNumber);

        withdrawalKeys.add(key);
        withdrawalRequests[key] = withdrawal;

        emit WithdrawalRequestCreated(
            key, _params.owner, _params.tokenOut, _params.marketTokenAmountIn, withdrawal.blockNumber
        );
    }

    function cancelWithdrawal(bytes32 _key) external nonReentrant {
        Withdrawal.Data memory withdrawal = withdrawalRequests[_key];
        require(withdrawal.params.owner == msg.sender, "LiquidityVault: invalid owner");
        require(withdrawalKeys.contains(_key), "LiquidityVault: invalid key");
        require(withdrawal.expirationTimestamp < block.timestamp, "LiquidityVault: withdrawal not expired");

        withdrawalKeys.remove(_key);
        delete withdrawalRequests[_key];

        emit WithdrawalRequestCancelled(
            _key, withdrawal.params.owner, withdrawal.params.tokenOut, withdrawal.params.marketTokenAmountIn
        );
    }

    /////////////////////////
    // INTERNAL FUNCTIONS //
    ////////////////////////

    function _calculateUsdValue(bool _isLongToken, uint256 _price, uint256 _amount) internal view returns (uint256) {
        if (_isLongToken) {
            return (_amount * _price) / 10 ** LONG_TOKEN_DECIMALS;
        } else {
            return (_amount * _price) / 10 ** SHORT_TOKEN_DECIMALS;
        }
    }

    function _calculateMintAmount(uint256 _valueUsd, uint256 _longTokenPrice, uint256 _shortTokenPrice)
        internal
        view
        returns (uint256 mintAmount)
    {
        uint256 lpTokenPrice = _getLiquidityTokenPrice(_longTokenPrice, _shortTokenPrice, uint32(block.number));
        mintAmount = lpTokenPrice == 0 ? _valueUsd : Math.mulDiv(_valueUsd, SCALING_FACTOR, lpTokenPrice);
    }

    function _calculateAmountOut(
        address _tokenOut,
        uint256 _marketTokenAmount,
        uint256 _longTokenPrice,
        uint256 _shortTokenPrice,
        uint256 _impactedPrice
    ) internal view returns (uint256 amountOut) {
        uint256 lpTokenPrice = _getLiquidityTokenPrice(_longTokenPrice, _shortTokenPrice, uint32(block.number));
        uint256 marketTokenValueUsd = (lpTokenPrice * _marketTokenAmount / SCALING_FACTOR);
        amountOut = _tokenOut == address(LONG_TOKEN)
            ? Math.mulDiv(marketTokenValueUsd, 10 ** LONG_TOKEN_DECIMALS, _impactedPrice)
            : Math.mulDiv(marketTokenValueUsd, 10 ** SHORT_TOKEN_DECIMALS, _impactedPrice);
    }

    function _getLiquidityTokenPrice(uint256 _longTokenPrice, uint256 _shortTokenPrice, uint32 _blockNumber)
        internal
        view
        returns (uint256 lpTokenPrice)
    {
        // market token price = (worth of market pool in USD) / total supply
        uint256 aum = _getAum(_longTokenPrice, _shortTokenPrice, _blockNumber);
        uint256 supply = totalSupply();
        if (aum == 0 || supply == 0) {
            lpTokenPrice = 0;
        } else {
            lpTokenPrice = Math.mulDiv(aum, SCALING_FACTOR, supply);
        }
    }

    function _getAum(uint256 _longTokenPrice, uint256 _shortTokenPrice, uint32 _blockNumber)
        internal
        view
        returns (uint256 aum)
    {
        // Get Values in USD
        uint256 longTokenValue = (longTokenBalance * _longTokenPrice) / (10 ** LONG_TOKEN_DECIMALS);
        uint256 shortTokenValue = (shortTokenBalance * _shortTokenPrice) / (10 ** SHORT_TOKEN_DECIMALS);

        // Calculate PNL
        int256 pnl = dataOracle.getCumulativeNetPnl(_blockNumber);

        // Calculate AUM
        aum = pnl >= 0
            ? longTokenValue + shortTokenValue + uint256(pnl)
            : longTokenValue + shortTokenValue - uint256(-pnl);
    }
}
