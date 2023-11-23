// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {RoleValidation} from "../access/RoleValidation.sol";

/// @dev Only Vaults can mint and burn tokens
contract MarketToken is ERC20("MarketToken", "MKT"), RoleValidation {
    constructor() RoleValidation(roleStorage) {}

    function mint(address account, uint256 amount) external onlyVault {
        _mint(account, amount);
    }

    function burn(address account, uint256 amount) external onlyVault {
        _burn(account, amount);
    }
}
