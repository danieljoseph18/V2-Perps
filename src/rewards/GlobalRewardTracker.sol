// SPDX-License-Identifier: MIT

pragma solidity 0.8.23;

import {IERC20} from "../tokens/interfaces/IERC20.sol";
import {SafeTransferLib} from "../libraries/SafeTransferLib.sol";
import {ReentrancyGuard} from "../utils/ReentrancyGuard.sol";
import {IFeeDistributor} from "./interfaces/IFeeDistributor.sol";
import {IGlobalRewardTracker} from "./interfaces/IGlobalRewardTracker.sol";
import {OwnableRoles} from "../auth/OwnableRoles.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {ILiquidityLocker} from "./interfaces/ILiquidityLocker.sol";
import {EnumerableSetLib} from "../libraries/EnumerableSetLib.sol";

contract GlobalRewardTracker is IERC20, ReentrancyGuard, IGlobalRewardTracker, OwnableRoles {
    using SafeTransferLib for IERC20;
    using EnumerableSetLib for EnumerableSetLib.AddressSet;

    uint256 public constant BASIS_POINTS_DIVISOR = 10000;
    uint256 public constant PRECISION = 1e30;

    uint8 public constant decimals = 18;

    bool public isInitialized;

    ILiquidityLocker public liquidityLocker;

    string public name;
    string public symbol;
    address private weth;
    address private usdc;

    address public distributor;
    /**
     * Mapping to store multiple deposit tokens. Store total deposit supply.
     */
    mapping(address depositToken => bool) public isDepositToken;
    mapping(address depositToken => uint256) public totalDepositSupply;
    mapping(address user => EnumerableSetLib.AddressSet) private userDepositTokens;

    uint256 public override(IERC20) totalSupply;
    mapping(address => uint256) public balances;
    mapping(address => mapping(address => uint256)) public allowances;

    uint256 public cumulativeWethRewardPerToken;
    uint256 public cumulativeUsdcRewardPerToken;

    mapping(address account => mapping(address depositToken => StakeData)) private stakeData;

    bool public inPrivateTransferMode;
    bool public inPrivateStakingMode;
    bool public inPrivateClaimingMode;
    mapping(address => bool) public isHandler;

    constructor(string memory _name, string memory _symbol) {
        _initializeOwner(msg.sender);
        name = _name;
        symbol = _symbol;
    }

    /**
     * =========================================== Setter Functions ===========================================
     */
    function initialize(address _distributor, address _liquidityLocker) external onlyOwner {
        if (isInitialized) revert RewardTracker_AlreadyInitialized();
        isInitialized = true;
        distributor = _distributor;
        liquidityLocker = ILiquidityLocker(_liquidityLocker);
    }

    function addDepositToken(address _depositToken) external onlyRoles(_ROLE_0) {
        isDepositToken[_depositToken] = true;
    }

    function setInPrivateTransferMode(bool _inPrivateTransferMode) external onlyOwner {
        inPrivateTransferMode = _inPrivateTransferMode;
    }

    function setInPrivateStakingMode(bool _inPrivateStakingMode) external onlyOwner {
        inPrivateStakingMode = _inPrivateStakingMode;
    }

    function setInPrivateClaimingMode(bool _inPrivateClaimingMode) external onlyOwner {
        inPrivateClaimingMode = _inPrivateClaimingMode;
    }

    function setHandler(address _handler, bool _isActive) external onlyOwner {
        isHandler[_handler] = _isActive;
    }

    /**
     * =========================================== Core Functions ===========================================
     */
    function stake(address _depositToken, uint256 _amount) external nonReentrant {
        if (inPrivateStakingMode) revert RewardTracker_ActionDisbaled();
        _validateDepositToken(_depositToken);
        _stake(msg.sender, msg.sender, _depositToken, _amount);
    }

    function stakeForAccount(address _fundingAccount, address _account, address _depositToken, uint256 _amount)
        external
        nonReentrant
    {
        _validateHandler();
        _validateDepositToken(_depositToken);
        _stake(_fundingAccount, _account, _depositToken, _amount);
    }

    function unstake(address _depositToken, uint256 _amount) external nonReentrant {
        if (inPrivateStakingMode) revert RewardTracker_ActionDisbaled();
        _validateDepositToken(_depositToken);
        _unstake(msg.sender, _depositToken, _amount, msg.sender);
    }

    function unstakeForAccount(address _account, address _depositToken, uint256 _amount, address _receiver)
        external
        nonReentrant
    {
        _validateHandler();
        _validateDepositToken(_depositToken);
        _unstake(_account, _depositToken, _amount, _receiver);
    }

    function transfer(address _recipient, uint256 _amount) external override(IERC20) returns (bool) {
        _transfer(msg.sender, _recipient, _amount);
        return true;
    }

    function approve(address _spender, uint256 _amount) external override(IERC20) returns (bool) {
        _approve(msg.sender, _spender, _amount);
        return true;
    }

    function transferFrom(address _sender, address _recipient, uint256 _amount)
        external
        override(IERC20)
        returns (bool)
    {
        if (isHandler[msg.sender]) {
            _transfer(_sender, _recipient, _amount);
            return true;
        }

        uint256 nextAllowance = allowances[_sender][msg.sender] - _amount;
        _approve(_sender, msg.sender, nextAllowance);
        _transfer(_sender, _recipient, _amount);
        return true;
    }

    function updateRewards(address _depositToken) external nonReentrant {
        _updateRewards(address(0), _depositToken);
    }

    function claim(address _depositToken, address _receiver)
        external
        nonReentrant
        returns (uint256 wethAmount, uint256 usdcAmount)
    {
        if (inPrivateClaimingMode) revert RewardTracker_ActionDisbaled();
        return _claim(msg.sender, _depositToken, _receiver);
    }

    function claimForAccount(address _account, address _depositToken, address _receiver)
        external
        nonReentrant
        returns (uint256 wethAmount, uint256 usdcAmount)
    {
        _validateHandler();
        return _claim(_account, _depositToken, _receiver);
    }

    /**
     * =========================================== Getter Functions ===========================================
     */
    function allowance(address _owner, address _spender) external view override(IERC20) returns (uint256) {
        return allowances[_owner][_spender];
    }

    function balanceOf(address _account) external view override(IERC20, IGlobalRewardTracker) returns (uint256) {
        return balances[_account];
    }

    function tokensPerInterval(address _depositToken)
        external
        view
        returns (uint256 wethTokensPerInterval, uint256 usdcTokensPerInterval)
    {
        (wethTokensPerInterval, usdcTokensPerInterval) = IFeeDistributor(distributor).tokensPerInterval(_depositToken);
    }

    function claimable(address _account, address _depositToken)
        public
        view
        returns (uint256 wethAmount, uint256 usdcAmount)
    {
        uint256 stakedAmount = stakeData[_account][_depositToken].stakedAmount;
        if (stakedAmount == 0) {
            return (
                stakeData[_account][_depositToken].claimableWethReward,
                stakeData[_account][_depositToken].claimableUsdcReward
            );
        }
        uint256 supply = totalSupply;
        (uint256 pendingWeth, uint256 pendingUsdc) = IFeeDistributor(distributor).pendingRewards(_depositToken);
        pendingWeth *= PRECISION;
        pendingUsdc *= PRECISION;
        uint256 nextCumulativeWethRewardPerToken = cumulativeWethRewardPerToken + (pendingWeth / supply);
        uint256 nextCumulativeUsdcRewardPerToken = cumulativeUsdcRewardPerToken + (pendingUsdc / supply);
        wethAmount = stakeData[_account][_depositToken].claimableWethReward
            + (
                stakedAmount
                    * (nextCumulativeWethRewardPerToken - stakeData[_account][_depositToken].prevCumulativeWethPerToken)
            ) / PRECISION;

        usdcAmount = stakeData[_account][_depositToken].claimableUsdcReward
            + (
                stakedAmount
                    * (nextCumulativeUsdcRewardPerToken - stakeData[_account][_depositToken].prevCumulativeUsdcPerToken)
            ) / PRECISION;
    }

    function getStakeData(address _account, address _depositToken) external view returns (StakeData memory) {
        return stakeData[_account][_depositToken];
    }

    function getUserDepositTokens(address _user) external view returns (address[] memory) {
        return userDepositTokens[_user].values();
    }

    /**
     * =========================================== Internal Functions ===========================================
     */
    function _claim(address _account, address _depositToken, address _receiver)
        private
        returns (uint256 wethAmount, uint256 usdcAmount)
    {
        _updateRewards(_account, _depositToken);

        wethAmount = stakeData[_account][_depositToken].claimableWethReward;
        stakeData[_account][_depositToken].claimableWethReward = 0;
        usdcAmount = stakeData[_account][_depositToken].claimableUsdcReward;
        stakeData[_account][_depositToken].claimableUsdcReward = 0;

        if (wethAmount > 0) IERC20(weth).safeTransfer(_receiver, wethAmount);
        if (usdcAmount > 0) IERC20(usdc).safeTransfer(_receiver, usdcAmount);

        emit Claim(_receiver, wethAmount, usdcAmount);
    }

    function _mint(address _account, uint256 _amount) internal {
        if (_account == address(0)) revert RewardTracker_ZeroAddress();

        totalSupply = totalSupply + _amount;
        balances[_account] = balances[_account] + _amount;

        emit Transfer(address(0), _account, _amount);
    }

    function _burn(address _account, uint256 _amount) internal {
        if (_account == address(0)) revert RewardTracker_ZeroAddress();

        balances[_account] = balances[_account] - _amount;
        totalSupply = totalSupply - _amount;

        emit Transfer(_account, address(0), _amount);
    }

    function _transfer(address _sender, address _recipient, uint256 _amount) private {
        if (_sender == address(0)) revert RewardTracker_ZeroAddress();
        if (_recipient == address(0)) revert RewardTracker_ZeroAddress();

        if (inPrivateTransferMode) _validateHandler();

        balances[_sender] = balances[_sender] - _amount;
        balances[_recipient] = balances[_recipient] + _amount;

        emit Transfer(_sender, _recipient, _amount);
    }

    function _approve(address _owner, address _spender, uint256 _amount) private {
        if (_owner == address(0)) revert RewardTracker_ZeroAddress();
        if (_spender == address(0)) revert RewardTracker_ZeroAddress();

        allowances[_owner][_spender] = _amount;

        emit Approval(_owner, _spender, _amount);
    }

    function _validateHandler() private view {
        if (!isHandler[msg.sender]) revert RewardTracker_Forbidden();
    }

    function _validateDepositToken(address _depositToken) private view {
        if (!isDepositToken[_depositToken]) revert RewardTracker_InvalidDepositToken();
    }

    function _stake(address _fundingAccount, address _account, address _depositToken, uint256 _amount) private {
        if (_amount == 0) revert RewardTracker_InvalidAmount();

        IERC20(_depositToken).safeTransferFrom(_fundingAccount, address(this), _amount);

        if (!userDepositTokens[_account].contains(_depositToken)) {
            userDepositTokens[_account].add(_depositToken);
        }

        _updateRewards(_account, _depositToken);

        stakeData[_account][_depositToken].stakedAmount = stakeData[_account][_depositToken].stakedAmount + _amount;
        stakeData[_account][_depositToken].depositBalance = stakeData[_account][_depositToken].depositBalance + _amount;
        totalDepositSupply[_depositToken] += _amount;

        _mint(_account, _amount);
    }

    function _unstake(address _account, address _depositToken, uint256 _amount, address _receiver) private {
        if (_amount == 0) revert RewardTracker_InvalidAmount();

        if (!userDepositTokens[_account].contains(_depositToken)) {
            revert RewardTracker_InvalidDepositToken();
        }

        _updateRewards(_account, _depositToken);

        uint256 stakedAmount = stakeData[_account][_depositToken].stakedAmount;
        if (stakeData[_account][_depositToken].stakedAmount < _amount) revert RewardTracker_AmountExceedsStake();

        stakeData[_account][_depositToken].stakedAmount = stakedAmount - _amount;

        uint256 depositBalance = stakeData[_account][_depositToken].depositBalance;
        if (depositBalance < _amount) revert RewardTracker_AmountExceedsBalance();
        if (_amount == depositBalance) {
            if (!userDepositTokens[_account].remove(_depositToken)) revert RewardTracker_FailedToRemoveDepositToken();
        }
        stakeData[_account][_depositToken].depositBalance = depositBalance - _amount;
        totalDepositSupply[_depositToken] -= _amount;

        _burn(_account, _amount);
        IERC20(_depositToken).safeTransfer(_receiver, _amount);
    }

    function _updateRewards(address _account, address _depositToken) private {
        (uint256 wethReward, uint256 usdcReward) = IFeeDistributor(distributor).distribute(_depositToken);

        uint256 supply = totalSupply;
        uint256 _cumulativeWethRewardPerToken = cumulativeWethRewardPerToken;
        uint256 _cumulativeUsdcRewardPerToken = cumulativeUsdcRewardPerToken;
        if (supply > 0) {
            if (wethReward > 0) {
                _cumulativeWethRewardPerToken = _cumulativeWethRewardPerToken + ((wethReward * PRECISION) / supply);
                cumulativeWethRewardPerToken = _cumulativeWethRewardPerToken;
            }
            if (usdcReward > 0) {
                _cumulativeUsdcRewardPerToken = _cumulativeUsdcRewardPerToken + ((usdcReward * PRECISION) / supply);
                cumulativeUsdcRewardPerToken = _cumulativeUsdcRewardPerToken;
            }
        }

        // cumulativeRewardPerToken can only increase
        // so if cumulativeRewardPerToken is zero, it means there are no rewards yet
        if (_cumulativeWethRewardPerToken == 0 && _cumulativeUsdcRewardPerToken == 0) {
            return;
        }

        if (_account != address(0)) {
            _updateRewardsForAccount(
                _account, _depositToken, _cumulativeWethRewardPerToken, _cumulativeUsdcRewardPerToken
            );
        }
    }

    /// @dev internal function to prevent STD Err
    function _updateRewardsForAccount(
        address _account,
        address _depositToken,
        uint256 _cumulativeWethRewardPerToken,
        uint256 _cumulativeUsdcRewardPerToken
    ) private {
        uint256 stakedAmount = stakeData[_account][_depositToken].stakedAmount;
        uint256 accountWethReward = (
            stakedAmount
                * (_cumulativeWethRewardPerToken - stakeData[_account][_depositToken].prevCumulativeWethPerToken)
        ) / PRECISION;
        uint256 _claimableWethReward = stakeData[_account][_depositToken].claimableWethReward + accountWethReward;
        uint256 accountUsdcReward = (
            stakedAmount
                * (_cumulativeUsdcRewardPerToken - stakeData[_account][_depositToken].prevCumulativeUsdcPerToken)
        ) / PRECISION;
        uint256 _claimableUsdcReward = stakeData[_account][_depositToken].claimableUsdcReward + accountUsdcReward;

        stakeData[_account][_depositToken].claimableWethReward = _claimableWethReward;
        stakeData[_account][_depositToken].prevCumulativeWethPerToken = _cumulativeWethRewardPerToken;
        stakeData[_account][_depositToken].claimableUsdcReward = _claimableUsdcReward;
        stakeData[_account][_depositToken].prevCumulativeUsdcPerToken = _cumulativeUsdcRewardPerToken;

        if (stakeData[_account][_depositToken].stakedAmount > 0) {
            if (_claimableWethReward > 0) {
                uint256 nextCumulativeReward =
                    stakeData[_account][_depositToken].cumulativeWethRewards + accountWethReward;

                stakeData[_account][_depositToken].averageStakedAmount = (
                    (
                        stakeData[_account][_depositToken].averageStakedAmount
                            * stakeData[_account][_depositToken].cumulativeWethRewards
                    ) / nextCumulativeReward
                ) + (stakedAmount * accountWethReward) / nextCumulativeReward;

                stakeData[_account][_depositToken].cumulativeWethRewards = nextCumulativeReward;
            }
            if (_claimableUsdcReward > 0) {
                uint256 nextCumulativeReward =
                    stakeData[_account][_depositToken].cumulativeUsdcRewards + accountUsdcReward;

                stakeData[_account][_depositToken].averageStakedAmount = (
                    (
                        stakeData[_account][_depositToken].averageStakedAmount
                            * stakeData[_account][_depositToken].cumulativeUsdcRewards
                    ) / nextCumulativeReward
                ) + (stakedAmount * accountUsdcReward) / nextCumulativeReward;

                stakeData[_account][_depositToken].cumulativeUsdcRewards = nextCumulativeReward;
            }
        }
    }
}
