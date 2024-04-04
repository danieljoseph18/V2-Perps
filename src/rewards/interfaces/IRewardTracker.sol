// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

interface IRewardTracker {
    error RewardTracker_ActionDisbaled();
    error RewardTracker_InvalidAmount();
    error RewardTracker_ZeroAddress();
    error RewardTracker_AlreadyInitialized();
    error RewardTracker_Forbidden();
    error RewardTracker_InvalidDepositToken();
    error RewardTracker_AmountExceedsStake();
    error RewardTracker_AmountExceedsBalance();

    event Claim(address receiver, uint256 wethAmount, uint256 usdcAmount);

    struct StakeData {
        uint256 depositBalance;
        uint256 stakedAmount;
        uint256 averageStakedAmount;
        uint256 claimableWethReward;
        uint256 claimableUsdcReward;
        uint256 prevCumulativeWethPerToken;
        uint256 prevCumulativeUsdcPerToken;
        uint256 cumulativeWethRewards;
        uint256 cumulativeUsdcRewards;
    }

    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function stake(uint256 amount) external;
    function stakeForAccount(address fundingAccount, address account, uint256 amount) external;
    function unstake(uint256 amount) external;
    function unstakeForAccount(address account, uint256 amount, address receiver) external;
    function transfer(address recipient, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function tokensPerInterval() external view returns (uint256 wethTokensPerInterval, uint256 usdcTokensPerInterval);
    function updateRewards() external;
    function getStakeData(address _account) external view returns (StakeData memory);
    function claim(address _receiver) external returns (uint256 wethAmount, uint256 usdcAmount);
    function claimForAccount(address _account, address _receiver)
        external
        returns (uint256 wethAmount, uint256 usdcAmount);
    function claimable(address account) external view returns (uint256 wethAmount, uint256 usdcAmount);
}
