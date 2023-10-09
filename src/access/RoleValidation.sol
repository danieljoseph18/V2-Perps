// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {RoleStorage} from "./RoleStorage.sol";
import {Roles} from "./Roles.sol";

// inheritance adds gas bloating, reconfigure with all required roles
contract RoleValidation {
    RoleStorage public immutable roleStorage;

    modifier onlyAdmin() {
        require(roleStorage.hasRole(Roles.DEFAULT_ADMIN_ROLE, msg.sender), "Sender must be admin");
        _;
    }

    modifier onlyModerator() {
        require(roleStorage.hasRole(Roles.MODERATOR, msg.sender), "Sender must be a moderator");
        _;
    }

    modifier onlyMarketMaker() {
        require(roleStorage.hasRole(Roles.MARKET_MAKER, msg.sender), "Sender must be market maker");
        _;
    }

    modifier onlyLiquidator() {
        require(roleStorage.hasRole(Roles.LIQUIDATOR, msg.sender), "Sender must be liquidator");
        _;
    }

    modifier onlyExecutor() {
        require(roleStorage.hasRole(Roles.EXECUTOR, msg.sender), "Sender must be executor");
        _;
    }

    modifier onlyConfigurator() {
        require(roleStorage.hasRole(Roles.CONFIGURATOR, msg.sender), "Sender must be configurator");
        _;
    }

    modifier onlyFactory() {
        require(roleStorage.hasRole(Roles.FACTORY, msg.sender), "Sender must be factory");
        _;
    }

    modifier onlyTradeStorage() {
        require(roleStorage.hasRole(Roles.TRADE_STORAGE, msg.sender), "Sender must be storage");
        _;
    }

    modifier onlyVault() {
        require(roleStorage.hasRole(Roles.VAULT, msg.sender), "Sender must be vault");
        _;
    }

    modifier onlyKeeper() {
        require(roleStorage.hasRole(Roles.KEEPER, msg.sender), "Sender must be keeper");
        _;
    }

    modifier onlyRouter() {
        require(roleStorage.hasRole(Roles.ROUTER, msg.sender), "Sender must be router");
        _;
    }

    modifier onlyStateUpdater() {
        require(roleStorage.hasRole(Roles.STATE_UPDATER, msg.sender), "Sender must be state updater");
        _;
    }

    modifier onlyStateKeeper() {
        require(roleStorage.hasRole(Roles.STATE_KEEPER, msg.sender), "Sender must be state keeper");
        _;
    }

    modifier onlyMarketStorage() {
        require(roleStorage.hasRole(Roles.MARKET_STORAGE, msg.sender), "Sender must be market storage");
        _;
    }

    constructor(RoleStorage _roleStorage) {
        roleStorage = _roleStorage;
    }
}
