//  ,----,------------------------------,------.
//   | ## |                              |    - |
//   | ## |                              |    - |
//   |    |------------------------------|    - |
//   |    ||............................||      |
//   |    ||,-                        -.||      |
//   |    ||___                      ___||    ##|
//   |    ||---`--------------------'---||      |
//   `--mb'|_|______________________==__|`------'

//    ____  ____  ___ _   _ _____ _____ ____
//   |  _ \|  _ \|_ _| \ | |_   _|___ /|  _ \
//   | |_) | |_) || ||  \| | | |   |_ \| |_) |
//   |  __/|  _ < | || |\  | | |  ___) |  _ <
//   |_|   |_| \_\___|_| \_| |_| |____/|_| \_\

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.21;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {RoleValidation} from "../access/RoleValidation.sol";
import {ILiquidityVault} from "../markets/interfaces/ILiquidityVault.sol";
import {IWUSDC} from "../token/interfaces/IWUSDC.sol";
import {TradeHelper} from "./TradeHelper.sol";

/// @dev Needs Vault Role
contract TradeVault is RoleValidation {
    using SafeERC20 for IWUSDC;

    IWUSDC public immutable WUSDC;
    ILiquidityVault public liquidityVault;

    mapping(bytes32 _marketKey => uint256 _collateral) public longCollateral;
    mapping(bytes32 _marketKey => uint256 _collateral) public shortCollateral;
    mapping(address _user => uint256 _rewards) public liquidationRewards;

    event TransferOutTokens(bytes32 indexed _marketKey, address indexed _to, uint256 _collateralDelta, bool _isLong);
    event LossesTransferred(uint256 indexed _amount);
    event UpdateCollateralBalance(bytes32 indexed _marketKey, uint256 _amount, bool _isLong, bool _isIncrease);
    event ExecutionFeeSent(address indexed _executor, uint256 indexed _fee);
    event PositionCollateralLiquidated(
        address indexed _liquidator,
        uint256 indexed _liqFee,
        bytes32 indexed _marketKey,
        uint256 _totalCollateral,
        uint256 _fundingOwed,
        bool _isLong
    );

    error TradeVault_InvalidToken();
    error TradeVault_IncorrectMarketKey();
    error TradeVault_ZeroAddressTransfer();
    error TradeVault_ZeroBalanceTransfer();
    error TradeVault_InsufficientCollateral();
    error TradeVault_InsufficientCollateralToClaim();
    error TradeVault_InsufficientBalance();
    error TradeVault_ExecutionFeeTransferFailed();

    constructor(address _wusdc, address _liquidityVault, address _roleStorage) RoleValidation(_roleStorage) {
        WUSDC = IWUSDC(_wusdc);
        liquidityVault = ILiquidityVault(_liquidityVault);
    }

    receive() external payable {}

    function transferOutTokens(bytes32 _marketKey, address _to, uint256 _collateralDelta, bool _isLong)
        external
        onlyTradeStorage
    {
        if (longCollateral[_marketKey] == 0 && shortCollateral[_marketKey] == 0) revert TradeVault_IncorrectMarketKey();
        if (_to == address(0)) revert TradeVault_ZeroAddressTransfer();
        if (_collateralDelta == 0) revert TradeVault_ZeroBalanceTransfer();
        if (_isLong) {
            if (longCollateral[_marketKey] < _collateralDelta) revert TradeVault_InsufficientCollateral();
        } else {
            if (shortCollateral[_marketKey] < _collateralDelta) revert TradeVault_InsufficientCollateral();
        }
        uint256 amount = _collateralDelta;
        _isLong ? longCollateral[_marketKey] -= amount : shortCollateral[_marketKey] -= amount;
        WUSDC.safeTransfer(_to, amount);
        emit TransferOutTokens(_marketKey, _to, _collateralDelta, _isLong);
    }

    function transferToLiquidityVault(uint256 _amount) external onlyTradeStorage {
        _sendTokensToLiquidityVault(_amount);
    }

    function updateCollateralBalance(bytes32 _marketKey, uint256 _amount, bool _isLong, bool _isIncrease)
        external
        onlyRouter
    {
        _updateCollateralBalance(_marketKey, _amount, _isLong, _isIncrease);
    }

    function swapFundingAmount(bytes32 _marketKey, uint256 _amount, bool _isLong) external onlyTradeStorage {
        _swapFundingAmount(_marketKey, _amount, _isLong);
    }

    function liquidatePositionCollateral(
        address _liquidator,
        uint256 _liqFee,
        bytes32 _marketKey,
        uint256 _totalCollateral,
        uint256 _fundingOwed,
        bool _isLong
    ) external onlyTradeStorage {
        // funding
        _swapFundingAmount(_marketKey, _fundingOwed, _isLong);

        WUSDC.safeTransfer(_liquidator, _liqFee);

        uint256 remainingCollateral = _totalCollateral - _fundingOwed - _liqFee;
        if (remainingCollateral > 0) {
            if (_isLong) {
                longCollateral[_marketKey] -= remainingCollateral;
            } else {
                shortCollateral[_marketKey] -= remainingCollateral;
            }
            _sendTokensToLiquidityVault(remainingCollateral);
        }
        emit PositionCollateralLiquidated(_liquidator, _liqFee, _marketKey, _totalCollateral, _fundingOwed, _isLong);
    }

    function claimFundingFees(bytes32 _marketKey, address _user, uint256 _claimed, bool _isLong)
        external
        onlyTradeStorage
    {
        if (_isLong) {
            if (shortCollateral[_marketKey] < _claimed) revert TradeVault_InsufficientCollateralToClaim();
        } else {
            if (longCollateral[_marketKey] < _claimed) revert TradeVault_InsufficientCollateralToClaim();
        }
        // transfer funding from the counter parties' liquidity pool
        _updateCollateralBalance(_marketKey, _claimed, _isLong, false);
        // transfer funding to the user
        WUSDC.safeTransfer(_user, _claimed);
    }

    function sendExecutionFee(address payable _executor, uint256 _executionFee) external onlyTradeStorage {
        if (address(this).balance < _executionFee) revert TradeVault_InsufficientBalance();
        (bool success,) = _executor.call{value: _executionFee}("");
        if (!success) revert TradeVault_ExecutionFeeTransferFailed();
        emit ExecutionFeeSent(_executor, _executionFee);
    }

    function _swapFundingAmount(bytes32 _marketKey, uint256 _amount, bool _isLong) internal {
        if (_isLong) {
            longCollateral[_marketKey] -= _amount;
            shortCollateral[_marketKey] += _amount;
        } else {
            shortCollateral[_marketKey] -= _amount;
            longCollateral[_marketKey] += _amount;
        }
    }

    function _updateCollateralBalance(bytes32 _marketKey, uint256 _amount, bool _isLong, bool _isIncrease) internal {
        if (_isLong) {
            _isIncrease ? longCollateral[_marketKey] += _amount : longCollateral[_marketKey] -= _amount;
        } else {
            _isIncrease ? shortCollateral[_marketKey] += _amount : shortCollateral[_marketKey] -= _amount;
        }
        emit UpdateCollateralBalance(_marketKey, _amount, _isLong, _isIncrease);
    }

    function _sendTokensToLiquidityVault(uint256 _amount) internal {
        if (_amount == 0) revert TradeVault_ZeroBalanceTransfer();
        liquidityVault.accumulateFees(_amount);
        WUSDC.safeTransfer(address(liquidityVault), _amount);
        emit LossesTransferred(_amount);
    }
}
