// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Roles} from "./Roles.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

contract RoleStorage is AccessControl {
    error RoleStorage_OnlyMarketFactory();

    mapping(address market => Roles.MarketRoles) private marketRoles;
    mapping(address marketToken => address minter) private minters;

    constructor() {
        _grantRole(Roles.DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /// @dev - Market Factory is able to set up the market roles and reconfigure them.
    function setMarketRoles(address _market, Roles.MarketRoles memory _roles) external {
        // Only the Market Factory can call
        if (!hasRole(Roles.MARKET_FACTORY, msg.sender)) revert RoleStorage_OnlyMarketFactory();
        marketRoles[_market] = _roles;
    }

    function setMinter(address _marketToken, address _minter) external {
        // Only the Market Factory can call
        if (!hasRole(Roles.MARKET_FACTORY, msg.sender)) revert RoleStorage_OnlyMarketFactory();
        minters[_marketToken] = _minter;
    }

    function hasTradeStorageRole(address _market, address _account) external view returns (bool) {
        return marketRoles[_market].tradeStorage == _account;
    }

    function hasConfiguratorRole(address _market, address _account) external view returns (bool) {
        return marketRoles[_market].configurator == _account;
    }

    function getMinter(address _marketToken) external view returns (address) {
        return minters[_marketToken];
    }

    function getTradeStorage(address _market) external view returns (address) {
        return marketRoles[_market].tradeStorage;
    }
}
