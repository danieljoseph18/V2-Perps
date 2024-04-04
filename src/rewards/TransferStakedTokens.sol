// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IRewardTracker} from "./interfaces/IRewardTracker.sol";

// provide a way to transfer staked LP tokens by unstaking from the sender
// and staking for the receiver
contract TransferStakedTokens {
    error TransferStakedTokens_ZeroAddress();

    mapping(address => mapping(address => uint256)) public allowances;

    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor() {}

    function allowance(address _owner, address _spender) external view returns (uint256) {
        return allowances[_owner][_spender];
    }

    function approve(address _spender, uint256 _amount) external returns (bool) {
        _approve(msg.sender, _spender, _amount);
        return true;
    }

    function transfer(address _recipient, address _stakedToken, uint256 _amount) external returns (bool) {
        _transfer(msg.sender, _recipient, _stakedToken, _amount);
        return true;
    }

    function transferFrom(address _sender, address _recipient, address _stakedToken, uint256 _amount)
        external
        returns (bool)
    {
        uint256 nextAllowance = allowances[_sender][msg.sender] - _amount;
        _approve(_sender, msg.sender, nextAllowance);
        _transfer(_sender, _recipient, _stakedToken, _amount);
        return true;
    }

    function balanceOf(address _account, address _stakedToken) external view returns (uint256) {
        return IRewardTracker(_stakedToken).getStakeData(_account).depositBalance;
    }

    function totalSupply(address _stakedToken) external view returns (uint256) {
        return IERC20(_stakedToken).totalSupply();
    }

    function _approve(address _owner, address _spender, uint256 _amount) private {
        if (_owner == address(0) || _spender == address(0)) {
            revert TransferStakedTokens_ZeroAddress();
        }

        allowances[_owner][_spender] = _amount;

        emit Approval(_owner, _spender, _amount);
    }

    function _transfer(address _sender, address _recipient, address _stakedToken, uint256 _amount) private {
        if (_sender == address(0) || _recipient == address(0)) {
            revert TransferStakedTokens_ZeroAddress();
        }
        IRewardTracker(_stakedToken).unstakeForAccount(_sender, _amount, _sender);
        IRewardTracker(_stakedToken).stakeForAccount(_sender, _recipient, _amount);
    }
}
