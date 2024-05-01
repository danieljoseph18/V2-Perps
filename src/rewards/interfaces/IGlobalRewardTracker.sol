// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {ILiquidityLocker} from "./ILiquidityLocker.sol";

interface IGlobalRewardTracker {
    error RewardTracker_ActionDisbaled();
    error RewardTracker_InvalidAmount();
    error RewardTracker_ZeroAddress();
    error RewardTracker_AlreadyInitialized();
    error RewardTracker_Forbidden();
    error RewardTracker_InvalidDepositToken();
    error RewardTracker_AmountExceedsStake();
    error RewardTracker_AmountExceedsBalance();
    error RewardTracker_FailedToRemoveDepositToken();

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

    function balanceOf(address account) external view returns (uint256);
    function claim(address _depositToken, address _receiver)
        external
        returns (uint256 wethAmount, uint256 usdcAmount);
    function claimable(address _account, address _depositToken)
        external
        view
        returns (uint256 wethAmount, uint256 usdcAmount);
    function liquidityLocker() external view returns (ILiquidityLocker);
    function getStakeData(address _account, address _depositToken) external view returns (StakeData memory);
    function unstakeForAccount(address _account, address _depositToken, uint256 _amount, address _receiver) external;
    function stakeForAccount(address _fundingAccount, address _account, address _depositToken, uint256 _amount)
        external;
    function initialize(address _distributor, address _liquidityLocker) external;
    function addDepositToken(address _depositToken) external;
}
