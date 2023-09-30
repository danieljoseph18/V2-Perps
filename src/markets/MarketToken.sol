// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// Do we generate the name from the factory for individuality?
contract MarketToken is ERC20("MarketToken", "MKT") {

    // Need role priviledge to provide to the Market.sol contract associated
    // Only callable by the Market.sol contract

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }

    function burn(address account, uint256 amount) external {
        _burn(account, amount);
    }

}