// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IERC20} from "src/tokens/interfaces/IERC20.sol";

interface IMockUSDC is IERC20 {
    function mint(address account, uint256 amount) external;
}
