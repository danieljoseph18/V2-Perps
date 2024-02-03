// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

interface ITradeVault {
    // Events
    event TransferOutTokens(address _market, address indexed _to, uint256 _collateralDelta, bool _isLong);
    event LossesTransferred(uint256 indexed _amount);
    event UpdateCollateralBalance(address _market, uint256 _amount, bool _isLong, bool _isIncrease);
    event ExecutionFeeSent(address indexed _executor, uint256 indexed _fee);
    event PositionCollateralLiquidated(
        address indexed _liquidator,
        uint256 indexed _liqFee,
        address _market,
        uint256 _totalCollateral,
        uint256 _collateralFundingOwed,
        bool _isLong
    );

    // Public variables
    function longCollateral(address _market) external view returns (uint256);
    function shortCollateral(address _market) external view returns (uint256);

    // Functions
    function transferOutTokens(address _market, address _to, uint256 _collateralDelta, bool _isLong) external;
    function transferToLiquidityVault(uint256 _amount) external;
    function updateCollateralBalance(address _market, uint256 _amount, bool _isLong, bool _isIncrease) external;
    function swapFundingAmount(address _market, uint256 _amount, bool _isLong) external;
    function liquidatePositionCollateral(
        address _liquidator,
        uint256 _liqFee,
        address _market,
        uint256 _totalCollateral,
        uint256 _collateralFundingOwed,
        bool _isLong
    ) external;
    function claimFundingFees(address _market, address _user, uint256 _claimed, bool _isLong) external;
    function sendExecutionFee(address payable _executor, uint256 _executionFee) external;
}
