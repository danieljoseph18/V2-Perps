// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {RoleValidation} from "../access/RoleValidation.sol";
import {ILiquidityVault} from "../markets/interfaces/ILiquidityVault.sol";

contract TradeVault is RoleValidation {
    using SafeERC20 for IERC20;
    // contract responsible for handling all tokens

    ILiquidityVault public liquidityVault;

    mapping(bytes32 _marketKey => uint256 _collateral) public longCollateral;
    mapping(bytes32 _marketKey => uint256 _collateral) public shortCollateral;
    mapping(address _user => uint256 _rewards) public liquidationRewards;

    address public collateralToken;

    event TransferOutTokens(
        address indexed _token, bytes32 indexed _marketKey, address indexed _to, uint256 _collateralDelta, bool _isLong
    );
    event LossesTransferred(address indexed _token, uint256 indexed _amount);
    event UpdateCollateralBalance(bytes32 indexed _marketKey, uint256 _amount, bool _isLong, bool _isIncrease);

    error TradeVault_InvalidToken();
    error TradeVault_IncorrectMarketKey();
    error TradeVault_ZeroAddressTransfer();
    error TradeVault_ZeroBalanceTransfer();
    error TradeVault_InsufficientCollateral();

    constructor(address _collateralToken, ILiquidityVault _liquidityVault) RoleValidation(roleStorage) {
        collateralToken = _collateralToken;
        liquidityVault = _liquidityVault;
    }

    function transferOutTokens(address _token, bytes32 _marketKey, address _to, uint256 _collateralDelta, bool _isLong)
        external
        onlyTradeStorage
    {
        if (_token != collateralToken) revert TradeVault_InvalidToken();
        if (longCollateral[_marketKey] == 0 && shortCollateral[_marketKey] == 0) revert TradeVault_IncorrectMarketKey();
        if (_to == address(0)) revert TradeVault_ZeroAddressTransfer();
        if (_collateralDelta == 0) revert TradeVault_ZeroBalanceTransfer();
        if (_isLong) {
            if (longCollateral[_marketKey] < _collateralDelta) revert TradeVault_InsufficientCollateral();
        } else {
            if (shortCollateral[_marketKey] < _collateralDelta) revert TradeVault_InsufficientCollateral();
        }
        // profit = size now - initial size => initial size is not their
        uint256 amount = _collateralDelta;
        _isLong ? longCollateral[_marketKey] -= amount : shortCollateral[_marketKey] -= amount;
        // NEED TO ALSO GET PNL FROM LIQUIDITY VAULT TO COVER THIS
        IERC20(_token).safeTransfer(_to, amount);
        emit TransferOutTokens(_token, _marketKey, _to, _collateralDelta, _isLong);
    }

    /// @dev If a position loses, this function transfers losses to LV
    function transferLossToLiquidityVault(address _token, uint256 _amount) external onlyTradeStorage {
        if (_token != collateralToken) revert TradeVault_InvalidToken();
        if (_amount == 0) revert TradeVault_ZeroBalanceTransfer();
        liquidityVault.accumulateFees(_amount);
        IERC20(_token).safeTransfer(address(liquidityVault), _amount);
        emit LossesTransferred(_token, _amount);
    }

    // Note Also needs to be callable from TradeStorage
    function updateCollateralBalance(bytes32 _marketKey, uint256 _amount, bool _isLong, bool _isIncrease)
        external
        onlyRouter
    {
        if (_isLong) {
            _isIncrease ? longCollateral[_marketKey] += _amount : longCollateral[_marketKey] -= _amount;
        } else {
            _isIncrease ? shortCollateral[_marketKey] += _amount : shortCollateral[_marketKey] -= _amount;
        }
        emit UpdateCollateralBalance(_marketKey, _amount, _isLong, _isIncrease);
    }
}
