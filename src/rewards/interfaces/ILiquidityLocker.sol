// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

interface ILiquidityLocker {
    error LiquidityLocker_InvalidTier();
    error LiquidityLocker_InvalidAmount();
    error LiquidityLocker_InsufficientFunds();
    error LiquidityLocker_EmptyPosition();
    error LiquidityLocker_DurationNotFinished();
    error LiquidityLocker_InvalidUser();
    error LiquidityLocker_NoPositions();
    error LiquidityLocker_InvalidHandler();

    event LiquidityLocker_LiquidityLocked(
        address indexed user, uint256 index, uint256 indexed amount, uint8 indexed tier
    );
    event LiquidityLocker_LiquidityUnlocked(
        address indexed user, uint256 index, uint256 indexed amount, uint8 indexed tier
    );
    event LiquidityLocker_RewardsClaimed(address indexed user, uint256 indexed wethAmount, uint256 indexed usdcAmount);

    struct Position {
        uint256 depositAmount;
        uint8 tier;
        uint64 lockedAt;
        uint64 unlockDate;
        address owner;
    }

    function setHandler(address _handler, bool _isActive) external;
    function lockLiquidity(uint8 tier, uint256 amount) external;
    function unlockLiquidity(uint256 index) external;
    function unlockAllPositions() external;
    function claimPendingRewards() external returns (uint256, uint256);
    function claimRewardsForAccount(address _account) external returns (uint256, uint256);
    function getClaimableTokenRewards(address user) external view returns (uint256 wethReward, uint256 usdcReward);
    function getRemainingLockDuration(address user, uint256 index) external view returns (uint256);
    function getUserPositionIds(address user) external view returns (uint256[] memory);
    function getUserTotalStakedAmountForTier(uint8 _tier, address _user) external view returns (uint256);
}
