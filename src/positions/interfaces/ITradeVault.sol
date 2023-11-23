// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

interface ITradeVault {
    function updateCollateralBalance(bytes32 _marketKey, uint256 _amount, bool _isLong, bool _isIncrease) external;
    function shortCollateral(bytes32 _marketKey) external view returns (uint256);
    function longCollateral(bytes32 _marketKey) external view returns (uint256);
    function transferOutTokens(bytes32 _marketKey, address _to, uint256 _collateralDelta, bool _isLong) external;
    function transferLossToLiquidityVault(uint256 _amount) external;
    function liquidatePositionCollateral(
        bytes32 _marketKey,
        uint256 _totalCollateral,
        uint256 _fundingOwed,
        bool _isLong
    ) external;
    function swapFundingAmount(bytes32 _marketKey, uint256 _amount, bool _isLong) external;
    function claimFundingFees(bytes32 _marketKey, address _user, uint256 _claimed, bool _isLong) external;
}
