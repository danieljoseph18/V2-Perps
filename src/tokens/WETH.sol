// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {ERC20} from "./ERC20.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {IWETH} from "./interfaces/IWETH.sol";

contract WETH is IWETH, ERC20 {
    error TransferFailed(address account, uint256 amount);

    constructor() ERC20("Wrapped Ether", "WETH", 18) {}

    // @dev mint WETH by depositing the Ether
    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    // @dev withdraw the Ether by burning WETH
    // @param amount the amount to withdraw
    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool success,) = msg.sender.call{value: amount}("");
        if (!success) {
            revert TransferFailed(msg.sender, amount);
        }
    }
}
