// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IMarketToken} from "./interfaces/IMarketToken.sol";
import {RoleValidation} from "../access/RoleValidation.sol";

contract MarketToken is ERC20, IMarketToken, RoleValidation {
    constructor(string memory name, string memory symbol, address _roleStorage)
        ERC20(name, symbol)
        RoleValidation(_roleStorage)
    {}

    function mint(address account, uint256 amount) external onlyMinter(address(this)) {
        _mint(account, amount);
    }

    function burn(address account, uint256 amount) external onlyMinter(address(this)) {
        _burn(account, amount);
    }
}
