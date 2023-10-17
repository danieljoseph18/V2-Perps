// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {RoleValidation} from "../access/RoleValidation.sol";

contract TradeVault is RoleValidation {
    using SafeERC20 for IERC20;
    // contract responsible for handling all tokens

    address public collateralToken;
    mapping(bytes32 _marketKey => uint256 _collateral) public longCollateral;
    mapping(bytes32 _marketKey => uint256 _collateral) public shortCollateral;


    mapping(address _user => uint256 _rewards) public liquidationRewards;

    constructor(address _collateralToken) RoleValidation(roleStorage) {
        collateralToken = _collateralToken;
    }

    function transferOutTokens(address _token, bytes32 _marketKey, address _to, uint256 _collateralDelta, bool _isLong)
        external
        onlyTradeStorage
    {
        require(_token == collateralToken, "TradeVault: token not collateral");
        require(longCollateral[_marketKey] != 0, "TradeVault: incorrect market key");
        require(_to != address(0), "TradeVault: cannot transfer to 0 address");
        require(_collateralDelta != 0, "TradeVault: cannot transfer 0 tokens");
        require(_isLong ? longCollateral[_marketKey] >= _collateralDelta : shortCollateral[_marketKey] >= _collateralDelta, "TradeVault: insufficient collateral");
        // profit = size now - initial size => initial size is not their
        uint256 amount = _collateralDelta;
        _isLong ? longCollateral[_marketKey] -= amount : shortCollateral[_marketKey] -= amount;
        // NEED TO ALSO GET PNL FROM LIQUIDITY VAULT TO COVER THIS
        IERC20(_token).safeTransfer(_to, amount);
    }

    // Note Also needs to be callable from TradeStorage
    function updateCollateralBalance(bytes32 _marketKey, uint256 _amount, bool _isLong, bool _isIncrease) external onlyRouter {
        if (_isLong) {
            _isIncrease ? longCollateral[_marketKey] += _amount : longCollateral[_marketKey] -= _amount;
        } else {
            _isIncrease ? shortCollateral[_marketKey] += _amount : shortCollateral[_marketKey] -= _amount;
        }
    }

}
