// SPDX-License-Identifier: MIT

pragma solidity 0.8.23;

import {IERC20} from "../tokens/interfaces/IERC20.sol";
import {SafeTransferLib} from "../libraries/SafeTransferLib.sol";
import {ReentrancyGuard} from "../utils/ReentrancyGuard.sol";
import {IFeeDistributor} from "./interfaces/IFeeDistributor.sol";
import {IRewardTracker} from "./interfaces/IRewardTracker.sol";
import {OwnableRoles} from "../auth/OwnableRoles.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {ILiquidityLocker} from "./interfaces/ILiquidityLocker.sol";

contract RewardTracker is IERC20, ReentrancyGuard, IRewardTracker, OwnableRoles {
    using SafeTransferLib for IERC20;

    uint256 public constant BASIS_POINTS_DIVISOR = 10000;
    uint256 public constant PRECISION = 1e30;

    uint8 public constant decimals = 18;

    bool public isInitialized;

    IMarket market;
    ILiquidityLocker public liquidityLocker;

    string public name;
    string public symbol;
    address private weth;
    address private usdc;

    address public distributor;
    address depositToken;

    uint256 public totalDepositSupply;

    uint256 public override(IERC20, IRewardTracker) totalSupply;
    mapping(address => uint256) public balances;
    mapping(address => mapping(address => uint256)) public allowances;

    uint256 public cumulativeWethRewardPerToken;
    uint256 public cumulativeUsdcRewardPerToken;

    mapping(address account => StakeData) private stakeData;

    bool public inPrivateTransferMode;
    bool public inPrivateStakingMode;
    bool public inPrivateClaimingMode;
    mapping(address => bool) public isHandler;

    constructor(IMarket _market, string memory _name, string memory _symbol) {
        _initializeOwner(msg.sender);
        market = _market;
        name = _name;
        symbol = _symbol;
    }

    /**
     * =============================== Setter Functions ===============================
     */
    function initialize(address _depositToken, address _distributor, address _liquidityLocker) external onlyOwner {
        if (isInitialized) revert RewardTracker_AlreadyInitialized();
        isInitialized = true;
        depositToken = _depositToken;
        distributor = _distributor;
        liquidityLocker = ILiquidityLocker(_liquidityLocker);
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
     * =============================== Core Functions ===============================
     */
    function stake(uint256 _amount) external nonReentrant {
        if (inPrivateStakingMode) revert RewardTracker_ActionDisbaled();
        _stake(msg.sender, msg.sender, _amount);
    }

    function stakeForAccount(address _fundingAccount, address _account, uint256 _amount) external nonReentrant {
        _validateHandler();
        _stake(_fundingAccount, _account, _amount);
    }

    function unstake(uint256 _amount) external nonReentrant {
        if (inPrivateStakingMode) revert RewardTracker_ActionDisbaled();
        _unstake(msg.sender, _amount, msg.sender);
    }

    function unstakeForAccount(address _account, uint256 _amount, address _receiver) external nonReentrant {
        _validateHandler();
        _unstake(_account, _amount, _receiver);
    }

    function transfer(address _recipient, uint256 _amount) external override(IERC20, IRewardTracker) returns (bool) {
        _transfer(msg.sender, _recipient, _amount);
        return true;
    }

    function approve(address _spender, uint256 _amount) external override(IERC20, IRewardTracker) returns (bool) {
        _approve(msg.sender, _spender, _amount);
        return true;
    }

    function transferFrom(address _sender, address _recipient, uint256 _amount)
        external
        override(IERC20, IRewardTracker)
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

    function updateRewards() external nonReentrant {
        _updateRewards(address(0));
    }

    function claim(address _receiver) external nonReentrant returns (uint256 wethAmount, uint256 usdcAmount) {
        if (inPrivateClaimingMode) revert RewardTracker_ActionDisbaled();
        return _claim(msg.sender, _receiver);
    }

    function claimForAccount(address _account, address _receiver)
        external
        nonReentrant
        returns (uint256 wethAmount, uint256 usdcAmount)
    {
        _validateHandler();
        return _claim(_account, _receiver);
    }

    /**
     * =============================== Getter Functions ===============================
     */
    function allowance(address _owner, address _spender)
        external
        view
        override(IERC20, IRewardTracker)
        returns (uint256)
    {
        return allowances[_owner][_spender];
    }

    function balanceOf(address _account) external view override(IERC20, IRewardTracker) returns (uint256) {
        return balances[_account];
    }

    function tokensPerInterval() external view returns (uint256 wethTokensPerInterval, uint256 usdcTokensPerInterval) {
        (wethTokensPerInterval, usdcTokensPerInterval) = IFeeDistributor(distributor).tokensPerInterval(market);
    }

    function claimable(address _account) public view returns (uint256 wethAmount, uint256 usdcAmount) {
        uint256 stakedAmount = stakeData[_account].stakedAmount;
        if (stakedAmount == 0) {
            return (stakeData[_account].claimableWethReward, stakeData[_account].claimableUsdcReward);
        }
        uint256 supply = totalSupply;
        (uint256 pendingWeth, uint256 pendingUsdc) = IFeeDistributor(distributor).pendingRewards(market);
        pendingWeth *= PRECISION;
        pendingUsdc *= PRECISION;
        uint256 nextCumulativeWethRewardPerToken = cumulativeWethRewardPerToken + (pendingWeth / supply);
        uint256 nextCumulativeUsdcRewardPerToken = cumulativeUsdcRewardPerToken + (pendingUsdc / supply);
        wethAmount = stakeData[_account].claimableWethReward
            + (stakedAmount * (nextCumulativeWethRewardPerToken - stakeData[_account].prevCumulativeWethPerToken))
                / PRECISION;

        usdcAmount = stakeData[_account].claimableUsdcReward
            + (stakedAmount * (nextCumulativeUsdcRewardPerToken - stakeData[_account].prevCumulativeUsdcPerToken))
                / PRECISION;
    }

    function getStakeData(address _account) external view returns (StakeData memory) {
        return stakeData[_account];
    }

    /**
     * =============================== Internal Functions ===============================
     */
    function _claim(address _account, address _receiver) private returns (uint256 wethAmount, uint256 usdcAmount) {
        _updateRewards(_account);

        wethAmount = stakeData[_account].claimableWethReward;
        stakeData[_account].claimableWethReward = 0;
        usdcAmount = stakeData[_account].claimableUsdcReward;
        stakeData[_account].claimableUsdcReward = 0;

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

    function _stake(address _fundingAccount, address _account, uint256 _amount) private {
        if (_amount == 0) revert RewardTracker_InvalidAmount();

        IERC20(depositToken).safeTransferFrom(_fundingAccount, address(this), _amount);

        _updateRewards(_account);

        stakeData[_account].stakedAmount = stakeData[_account].stakedAmount + _amount;
        stakeData[_account].depositBalance = stakeData[_account].depositBalance + _amount;
        totalDepositSupply = totalDepositSupply + _amount;

        _mint(_account, _amount);
    }

    function _unstake(address _account, uint256 _amount, address _receiver) private {
        if (_amount == 0) revert RewardTracker_InvalidAmount();

        _updateRewards(_account);

        uint256 stakedAmount = stakeData[_account].stakedAmount;
        if (stakeData[_account].stakedAmount < _amount) revert RewardTracker_AmountExceedsStake();

        stakeData[_account].stakedAmount = stakedAmount - _amount;

        uint256 depositBalance = stakeData[_account].depositBalance;
        if (depositBalance < _amount) revert RewardTracker_AmountExceedsBalance();
        stakeData[_account].depositBalance = depositBalance - _amount;
        totalDepositSupply = totalDepositSupply - _amount;

        _burn(_account, _amount);
        IERC20(depositToken).safeTransfer(_receiver, _amount);
    }

    function _updateRewards(address _account) private {
        (uint256 wethReward, uint256 usdcReward) = IFeeDistributor(distributor).distribute(market);

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
            _updateRewardsForAccount(_account, _cumulativeWethRewardPerToken, _cumulativeUsdcRewardPerToken);
        }
    }

    /// @dev internal function to prevent STD Err
    function _updateRewardsForAccount(
        address _account,
        uint256 _cumulativeWethRewardPerToken,
        uint256 _cumulativeUsdcRewardPerToken
    ) private {
        uint256 stakedAmount = stakeData[_account].stakedAmount;
        uint256 accountWethReward = (
            stakedAmount * (_cumulativeWethRewardPerToken - stakeData[_account].prevCumulativeWethPerToken)
        ) / PRECISION;
        uint256 _claimableWethReward = stakeData[_account].claimableWethReward + accountWethReward;
        uint256 accountUsdcReward = (
            stakedAmount * (_cumulativeUsdcRewardPerToken - stakeData[_account].prevCumulativeUsdcPerToken)
        ) / PRECISION;
        uint256 _claimableUsdcReward = stakeData[_account].claimableUsdcReward + accountUsdcReward;

        stakeData[_account].claimableWethReward = _claimableWethReward;
        stakeData[_account].prevCumulativeWethPerToken = _cumulativeWethRewardPerToken;
        stakeData[_account].claimableUsdcReward = _claimableUsdcReward;
        stakeData[_account].prevCumulativeUsdcPerToken = _cumulativeUsdcRewardPerToken;

        if (stakeData[_account].stakedAmount > 0) {
            if (_claimableWethReward > 0) {
                uint256 nextCumulativeReward = stakeData[_account].cumulativeWethRewards + accountWethReward;

                stakeData[_account].averageStakedAmount = (
                    (stakeData[_account].averageStakedAmount * stakeData[_account].cumulativeWethRewards)
                        / nextCumulativeReward
                ) + (stakedAmount * accountWethReward) / nextCumulativeReward;

                stakeData[_account].cumulativeWethRewards = nextCumulativeReward;
            }
            if (_claimableUsdcReward > 0) {
                uint256 nextCumulativeReward = stakeData[_account].cumulativeUsdcRewards + accountUsdcReward;

                stakeData[_account].averageStakedAmount = (
                    (stakeData[_account].averageStakedAmount * stakeData[_account].cumulativeUsdcRewards)
                        / nextCumulativeReward
                ) + (stakedAmount * accountUsdcReward) / nextCumulativeReward;

                stakeData[_account].cumulativeUsdcRewards = nextCumulativeReward;
            }
        }
    }
}
