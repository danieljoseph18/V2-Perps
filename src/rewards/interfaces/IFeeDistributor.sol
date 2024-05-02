// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

interface IFeeDistributor {
    function pendingRewards(address _vault) external view returns (uint256 wethAmount, uint256 usdcAmount);
    function distribute(address _vault) external returns (uint256 wethAmount, uint256 usdcAmount);
    function accumulateFees(uint256 _wethAmount, uint256 _usdcAmount) external;
    function tokensPerInterval(address _vault)
        external
        view
        returns (uint256 wethTokensPerInterval, uint256 usdcTokensPerInterval);
    function addVault(address _vault) external;
}
