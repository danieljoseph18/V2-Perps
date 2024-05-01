// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {GlobalRewardTracker} from "./GlobalRewardTracker.sol";
import {ReentrancyGuard} from "../utils/ReentrancyGuard.sol";
import {IERC20} from "../tokens/interfaces/IERC20.sol";
import {TransferStakedTokens} from "./TransferStakedTokens.sol";
import {OwnableRoles} from "../auth/OwnableRoles.sol";
import {ILiquidityLocker} from "./interfaces/ILiquidityLocker.sol";

/// @title LiquidityLocker
/// @dev Contract that allows users to lock LP tokens for a set duration in exchange for XP at various multipliers.
/// @notice Users can still claim rev-share from their reward tokens.
contract LiquidityLocker is ILiquidityLocker, OwnableRoles, ReentrancyGuard {
    GlobalRewardTracker public rewardTracker;
    TransferStakedTokens public stakeTransferrer;

    address public immutable WETH;
    address public immutable USDC;

    // Single Struct to avoid Parallel Data Structures
    struct LockData {
        mapping(uint256 id => Position position) positions;
        uint256[] positionIds;
        uint256 lockedAmount;
        uint256 averageLockedAmounts;
        uint256 claimableWethReward;
        uint256 claimableUsdcReward;
        uint256 previousCumulativeWethRewardPerToken;
        uint256 previousCumulativeUsdcRewardPerToken;
        uint256 cumulativeWethRewards;
        uint256 cumulativeUsdcRewards;
    }

    // Address => Index => Position
    mapping(address user => LockData) private lockData;
    mapping(address => bool) private isHandler;

    uint16 public constant TIER1_DURATION = 1 hours;
    uint32 public constant TIER2_DURATION = 30 days;
    uint32 public constant TIER3_DURATION = 90 days;
    uint32 public constant TIER4_DURATION = 180 days;
    uint128 private constant PRECISION = 10e30;

    uint256 public nextPositionId;

    uint256 public cumulativeWethRewardPerToken;
    uint256 public cumulativeUsdcRewardPerToken;
    uint256 public wethBalance;
    uint256 public usdcBalance;

    constructor(address _rewardTracker, address _transferStakedTokens, address _weth, address _usdc) {
        require(_rewardTracker != address(0));
        _initializeOwner(msg.sender);
        rewardTracker = GlobalRewardTracker(_rewardTracker);
        stakeTransferrer = TransferStakedTokens(_transferStakedTokens);
        WETH = _weth;
        USDC = _usdc;
    }

    function setHandler(address _handler, bool _isActive) external onlyOwner {
        isHandler[_handler] = _isActive;
    }

    /**
     * =========================================== Core Functions ===========================================
     */

    /// @notice Used to lock RewardTracker tokens for a set durations.
    /// @dev The user must approve the TransferStakedTokens contract to spend their tokens.
    /// @param tier The tier of the position.
    /// @param amount The amount of tokens to lock.
    /// @param _depositToken The address of the deposit token.
    function lockLiquidity(uint8 tier, uint256 amount, address _depositToken) external {
        if (uint256(tier) > 3) revert LiquidityLocker_InvalidTier();
        if (amount == 0) revert LiquidityLocker_InvalidAmount();
        if (rewardTracker.balanceOf(msg.sender) < amount) revert LiquidityLocker_InsufficientFunds();
        uint40 duration = _getDuration(tier);

        stakeTransferrer.transferFrom(msg.sender, address(this), address(rewardTracker), _depositToken, amount);

        _updateRewards(msg.sender, _depositToken);

        uint256 id = nextPositionId;
        nextPositionId = nextPositionId + 1;

        Position memory newPosition =
            Position(amount, tier, uint40(block.timestamp), uint40(block.timestamp) + duration, msg.sender);
        lockData[msg.sender].positions[id] = newPosition;
        lockData[msg.sender].positionIds.push(id);
        lockData[msg.sender].lockedAmount = lockData[msg.sender].lockedAmount + amount;
        wethBalance = wethBalance + amount;

        emit LiquidityLocker_LiquidityLocked(msg.sender, id, amount, tier);
    }

    /// @notice Used to unlock RewardTracker tokens after the set duration has passed.
    /// @param index The index of the position to unlock. Can use getter to find.
    function unlockLiquidity(uint256 index, address _depositToken) public {
        Position memory position = lockData[msg.sender].positions[index];
        if (position.depositAmount == 0) revert LiquidityLocker_EmptyPosition();
        if (position.unlockDate > block.timestamp) revert LiquidityLocker_DurationNotFinished();
        if (rewardTracker.balanceOf(address(this)) < position.depositAmount) {
            revert LiquidityLocker_InsufficientFunds();
        }
        if (position.owner != msg.sender) revert LiquidityLocker_InvalidUser();

        _updateRewards(msg.sender, _depositToken);

        lockData[msg.sender].lockedAmount = lockData[msg.sender].lockedAmount - position.depositAmount;
        wethBalance = wethBalance - position.depositAmount;
        delete lockData[msg.sender].positions[index];
        uint256[] storage userPositions = lockData[msg.sender].positionIds;
        for (uint256 i = 0; i < userPositions.length;) {
            if (userPositions[i] == index) {
                userPositions[i] = userPositions[userPositions.length - 1];
                userPositions.pop();
                break;
            }
            unchecked {
                ++i;
            }
        }

        stakeTransferrer.transfer(msg.sender, address(rewardTracker), _depositToken, position.depositAmount);

        emit LiquidityLocker_LiquidityUnlocked(msg.sender, index, position.depositAmount, position.tier);
    }

    /// @notice Used to unlock all expired positions.
    function unlockAllPositions(address _depositToken) external {
        uint256[] memory userPositions = lockData[msg.sender].positionIds;
        if (userPositions.length == 0) revert LiquidityLocker_NoPositions();
        for (uint256 i = 0; i < userPositions.length;) {
            if (lockData[msg.sender].positions[userPositions[i]].unlockDate <= block.timestamp) {
                unlockLiquidity(userPositions[i], _depositToken);
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Used to claim pending WETH/XP rewards accumulated. Callable at any time.
    function claimPendingRewards(address _depositToken) external nonReentrant returns (uint256, uint256) {
        return _claimPendingRewards(msg.sender, _depositToken);
    }

    /// @notice Used to claim WETH/XP for a user externally.
    function claimRewardsForAccount(address _account, address _depositToken)
        external
        nonReentrant
        returns (uint256, uint256)
    {
        _validateHandler();
        return _claimPendingRewards(_account, _depositToken);
    }

    /**
     * =========================================== Getter Functions ===========================================
     */

    /// @notice Returns the amount of claimable WETH rewards.
    /// @param _user The address of the user to check.
    /// @param _depositToken The address of the deposit token.
    function getClaimableTokenRewards(address _user, address _depositToken)
        external
        view
        returns (uint256 wethReward, uint256 usdcReward)
    {
        uint256 totalLocked = lockData[_user].lockedAmount;
        if (totalLocked == 0) {
            return (lockData[_user].claimableWethReward, lockData[_user].claimableUsdcReward);
        }
        uint256 wethBal = wethBalance;
        uint256 usdcBal = usdcBalance;
        (uint256 pendingWethRewards, uint256 pendingUsdcRewards) = rewardTracker.claimable(address(this), _depositToken);
        pendingWethRewards *= PRECISION;
        pendingUsdcRewards *= PRECISION;
        uint256 nextCumulativeWethRewardPerToken = cumulativeWethRewardPerToken + (pendingWethRewards / wethBal);
        uint256 nextCumulativeUsdcRewardPerToken = cumulativeUsdcRewardPerToken + (pendingUsdcRewards / usdcBal);
        wethReward = lockData[_user].claimableWethReward
            + (totalLocked * (nextCumulativeWethRewardPerToken - lockData[_user].previousCumulativeWethRewardPerToken))
                / PRECISION;
        usdcReward = lockData[_user].claimableUsdcReward
            + (totalLocked * (nextCumulativeUsdcRewardPerToken - lockData[_user].previousCumulativeUsdcRewardPerToken))
                / PRECISION;
    }

    /// @notice Returns the amount of time left of a locked position.
    /// @param _user The address of the user to check.
    /// @param _index The index of the position to check. Can use getter to get values.
    function getRemainingLockDuration(address _user, uint256 _index) public view returns (uint256) {
        Position memory position = lockData[_user].positions[_index];
        if (position.unlockDate <= block.timestamp) {
            return 0;
        } else {
            return position.unlockDate - block.timestamp;
        }
    }

    /// @notice Getter function for all of a users locked positions.
    /// @param _user The address of the user to check.
    function getUserPositionIds(address _user) external view returns (uint256[] memory) {
        return lockData[_user].positionIds;
    }

    /// @notice Getter function for a specific locked position.
    /// @param _tier The tiers to check total staked amounts for.
    /// @param _user The address of the user to check.
    function getUserTotalStakedAmountForTier(uint8 _tier, address _user) external view returns (uint256) {
        uint256 total;
        uint256[] memory userPositions = lockData[_user].positionIds;
        for (uint256 i = 0; i < userPositions.length; ++i) {
            Position memory position = lockData[_user].positions[userPositions[i]];
            if (position.tier == _tier) {
                total = total + position.depositAmount;
            }
        }
        return total;
    }

    /**
     * =========================================== Private Functions ===========================================
     */

    /// @notice Crucial function. Claims WETH from the RewardTracker and updates the contract state.
    /// @dev Adaptation of the RewardTracker's _updateReward function. Essentially collates rewards and divides them up by the same mechanism.
    /// @param _account The address of the user to update.
    function _updateRewards(address _account, address _depositToken) private {
        (uint256 wethReward, uint256 usdcReward) = rewardTracker.claim(_depositToken, address(this));

        uint256 wethBal = wethBalance;
        uint256 usdcBal = usdcBalance;

        uint256 _cumulativeWethRewardPerToken = cumulativeWethRewardPerToken;
        if (wethBal > 0 && wethReward > 0) {
            _cumulativeWethRewardPerToken = _cumulativeWethRewardPerToken + ((wethReward * PRECISION) / wethBal);
            cumulativeWethRewardPerToken = _cumulativeWethRewardPerToken;
        }

        uint256 _cumulativeUsdcRewardPerToken = cumulativeUsdcRewardPerToken;
        if (usdcBal > 0 && usdcReward > 0) {
            _cumulativeUsdcRewardPerToken = _cumulativeUsdcRewardPerToken + ((usdcReward * PRECISION) / usdcBal);
            cumulativeUsdcRewardPerToken = _cumulativeUsdcRewardPerToken;
        }

        if (_account != address(0)) {
            _updateRewardsForAccount(_account, _cumulativeWethRewardPerToken, _cumulativeUsdcRewardPerToken);
        }
    }

    function _updateRewardsForAccount(
        address _account,
        uint256 _cumulativeWethRewardPerToken,
        uint256 _cumulativeUsdcRewardPerToken
    ) private {
        uint256 totalLocked = lockData[_account].lockedAmount;
        uint256 wethAccountReward = (
            totalLocked * (_cumulativeWethRewardPerToken - lockData[_account].previousCumulativeWethRewardPerToken)
        ) / PRECISION;
        uint256 _claimableWethReward = lockData[_account].claimableWethReward + wethAccountReward;
        uint256 usdcAccountReward = (
            totalLocked * (_cumulativeUsdcRewardPerToken - lockData[_account].previousCumulativeUsdcRewardPerToken)
        ) / PRECISION;
        uint256 _claimableUsdcReward = lockData[_account].claimableUsdcReward + usdcAccountReward;

        lockData[_account].claimableWethReward = _claimableWethReward;
        lockData[_account].previousCumulativeWethRewardPerToken = _cumulativeWethRewardPerToken;
        lockData[_account].claimableUsdcReward = _claimableUsdcReward;
        lockData[_account].previousCumulativeUsdcRewardPerToken = _cumulativeUsdcRewardPerToken;

        if (lockData[_account].lockedAmount > 0) {
            if (_claimableWethReward > 0) {
                uint256 nextCumulativeReward = lockData[_account].cumulativeWethRewards + wethAccountReward;

                lockData[_account].averageLockedAmounts = (
                    (lockData[_account].averageLockedAmounts * lockData[_account].cumulativeWethRewards)
                        / nextCumulativeReward
                ) + (totalLocked * wethAccountReward) / nextCumulativeReward;

                lockData[_account].cumulativeWethRewards = nextCumulativeReward;
            }
            if (_claimableUsdcReward > 0) {
                uint256 nextCumulativeReward = lockData[_account].cumulativeUsdcRewards + usdcAccountReward;

                lockData[_account].averageLockedAmounts = (
                    (lockData[_account].averageLockedAmounts * lockData[_account].cumulativeUsdcRewards)
                        / nextCumulativeReward
                ) + (totalLocked * usdcAccountReward) / nextCumulativeReward;

                lockData[_account].cumulativeUsdcRewards = nextCumulativeReward;
            }
        }
    }

    function _claimPendingRewards(address _user, address _depositToken) private returns (uint256, uint256) {
        _updateRewards(_user, _depositToken);

        uint256 userWethReward = lockData[_user].claimableWethReward;
        lockData[_user].claimableWethReward = 0;
        uint256 userUsdcReward = lockData[_user].claimableUsdcReward;
        lockData[_user].claimableUsdcReward = 0;

        if (userWethReward != 0 && IERC20(WETH).balanceOf(address(this)) >= userWethReward) {
            IERC20(WETH).transfer(_user, userWethReward);
        }
        if (userUsdcReward != 0 && IERC20(USDC).balanceOf(address(this)) >= userUsdcReward) {
            IERC20(USDC).transfer(_user, userUsdcReward);
        }

        emit LiquidityLocker_RewardsClaimed(_user, userWethReward, userUsdcReward);
        return (userWethReward, userUsdcReward);
    }

    /// @notice Returns the duration of a locked position by tier.
    /// @param tier The tier of the position.
    function _getDuration(uint8 tier) private pure returns (uint40) {
        if (tier == 0) {
            return TIER1_DURATION; // 1hr cooldown
        } else if (tier == 1) {
            return TIER2_DURATION; // 30 days
        } else if (tier == 2) {
            return TIER3_DURATION; // 90 days
        } else {
            return TIER4_DURATION; // 180 days
        }
    }

    function _validateHandler() private view {
        if (!isHandler[msg.sender]) {
            revert LiquidityLocker_InvalidHandler();
        }
    }
}
