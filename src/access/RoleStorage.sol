// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Roles} from "./Roles.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

contract RoleStorage is AccessControl {
    error RoleStorage_OnlyMarketMaker();
    error RoleStorage_InvalidSuperAdmin();

    mapping(address _market => Roles.MarketRoles) marketRoles;

    constructor() {
        _grantRole(Roles.DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /// @dev - Market Maker is able to set up the market roles and reconfigure them.
    function setMarketRoles(address _market, Roles.MarketRoles memory _roles) external {
        // Only the Market Maker can call
        if (!hasRole(Roles.MARKET_MAKER, msg.sender)) revert RoleStorage_OnlyMarketMaker();
        marketRoles[_market] = _roles;
    }

    /**
     * struct MarketRoles {
     *     address tradeStorage;
     *     address router;
     *     address stateKeeper;
     *     address configurator;
     * }
     */
    function hasTradeStorageRole(address _market, address _account) external view returns (bool) {
        return marketRoles[_market].tradeStorage == _account;
    }

    function hasStateKeeperRole(address _market, address _account) external view returns (bool) {
        return marketRoles[_market].stateKeeper == _account;
    }

    function hasConfiguratorRole(address _market, address _account) external view returns (bool) {
        return marketRoles[_market].configurator == _account;
    }

    function getTradeStorage(address _market) external view returns (address) {
        return marketRoles[_market].tradeStorage;
    }
}
