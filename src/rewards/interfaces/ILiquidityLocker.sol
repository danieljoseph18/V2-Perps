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
        uint40 lockedAt;
        uint40 unlockDate;
        address owner;
    }
}
