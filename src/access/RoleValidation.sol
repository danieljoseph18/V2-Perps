// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {RoleStorage} from "./RoleStorage.sol";
import {Roles} from "./Roles.sol";

contract RoleValidation {
    RoleStorage public immutable roleStorage;

    error RoleValidation_AccessDenied();

    modifier onlyAdmin() {
        if (!roleStorage.hasRole(Roles.DEFAULT_ADMIN_ROLE, msg.sender)) revert RoleValidation_AccessDenied();
        _;
    }

    modifier onlyModerator() {
        if (!roleStorage.hasRole(Roles.MODERATOR, msg.sender)) revert RoleValidation_AccessDenied();
        _;
    }

    modifier onlyMarketMaker() {
        if (!roleStorage.hasRole(Roles.MARKET_MAKER, msg.sender)) revert RoleValidation_AccessDenied();
        _;
    }

    modifier onlyProcessor() {
        if (!roleStorage.hasRole(Roles.PROCESSOR, msg.sender)) revert RoleValidation_AccessDenied();
        _;
    }

    modifier onlyConfigurator() {
        if (!roleStorage.hasRole(Roles.CONFIGURATOR, msg.sender)) revert RoleValidation_AccessDenied();
        _;
    }

    modifier onlyTradeStorage() {
        if (!roleStorage.hasRole(Roles.TRADE_STORAGE, msg.sender)) revert RoleValidation_AccessDenied();
        _;
    }

    modifier onlyKeeper() {
        if (!roleStorage.hasRole(Roles.KEEPER, msg.sender)) revert RoleValidation_AccessDenied();
        _;
    }

    modifier onlyRouter() {
        if (!roleStorage.hasRole(Roles.ROUTER, msg.sender)) revert RoleValidation_AccessDenied();
        _;
    }

    modifier onlyStateKeeper() {
        if (!roleStorage.hasRole(Roles.STATE_KEEPER, msg.sender)) revert RoleValidation_AccessDenied();
        _;
    }

    modifier onlyFeeAccumulator() {
        if (!roleStorage.hasRole(Roles.FEE_ACCUMULATOR, msg.sender)) revert RoleValidation_AccessDenied();
        _;
    }

    modifier onlyKeeperOrSelf() {
        if (!roleStorage.hasRole(Roles.KEEPER, msg.sender) && !(msg.sender == address(this))) {
            revert RoleValidation_AccessDenied();
        }
        _;
    }

    modifier onlyRouterOrProcessor() {
        if (!roleStorage.hasRole(Roles.ROUTER, msg.sender) && !roleStorage.hasRole(Roles.PROCESSOR, msg.sender)) {
            revert RoleValidation_AccessDenied();
        }
        _;
    }

    modifier onlyLiquidationKeeper() {
        if (!roleStorage.hasRole(Roles.LIQUIDATOR, msg.sender)) revert RoleValidation_AccessDenied();
        _;
    }

    modifier onlyAdlKeeper() {
        if (!roleStorage.hasRole(Roles.ADL_KEEPER, msg.sender)) revert RoleValidation_AccessDenied();
        _;
    }

    constructor(address _roleStorage) {
        roleStorage = RoleStorage(_roleStorage);
    }
}
