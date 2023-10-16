// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {RoleValidation} from "../access/RoleValidation.sol";

contract TradeVault is RoleValidation {
    using SafeERC20 for IERC20;
    // contract responsible for handling all tokens

    mapping(bytes32 _marketKey => uint256 _collateral) public longCollateral;
    mapping(bytes32 _marketKey => uint256 _collateral) public shortCollateral;

    mapping(address _user => uint256 _rewards) public liquidationRewards;

    constructor() RoleValidation(roleStorage) {}

    // contract must be validated to transfer funds from TradeStorage
    // perhaps need to adopt a plugin transfer method like GMX V1
    // Note Should only Do 1 thing, transfer out tokens and update state
    // Separate PNL substitution
    function transferOutTokens(address _token, bytes32 _marketKey, address _to, uint256 _collateralDelta, bool _isLong)
        external
    {
        // profit = size now - initial size => initial size is not their
        uint256 amount = _collateralDelta;
        _isLong ? longCollateral[_marketKey] -= amount : shortCollateral[_marketKey] -= amount;
        // NEED TO ALSO GET PNL FROM LIQUIDITY VAULT TO COVER THIS
        IERC20(_token).safeTransfer(_to, amount);
    }
}
