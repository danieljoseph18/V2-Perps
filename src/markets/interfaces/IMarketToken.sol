// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IMarketToken is IERC20 {
    function mint(address account, uint256 amount) external;
    function burn(address account, uint256 amount) external;
}
