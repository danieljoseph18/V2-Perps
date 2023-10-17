// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

interface ITradeVault {
    function updateCollateralBalance(bytes32 _marketKey, uint256 _amount, bool _isLong, bool _isIncrease) external;
    function shortCollateral(bytes32 _marketKey) external view returns (uint256);
    function longCollateral(bytes32 _marketKey) external view returns (uint256);
    function transferOutTokens(address _token, bytes32 _marketKey, address _to, uint256 _collateralDelta, bool _isLong)
        external;
}
