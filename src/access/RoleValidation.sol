// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {RoleStorage} from "./RoleStorage.sol";
import {Roles} from "./Roles.sol";

contract RoleValidation {
    RoleStorage public immutable roleStorage;

    error RoleValidation_AccessDenied();

    modifier onlyAdmin() {
        _validateRole(Roles.DEFAULT_ADMIN_ROLE);
        _;
    }

    modifier onlyMarketFactory() {
        _validateRole(Roles.MARKET_FACTORY);
        _;
    }

    modifier onlyPositionManager() {
        _validateRole(Roles.POSITION_MANAGER);
        _;
    }

    modifier onlyConfigurator(address _market) {
        _validateConfigurator(_market);
        _;
    }

    modifier onlyTradeStorage(address _market) {
        _validateTradeStorage(_market);
        _;
    }

    modifier onlyTradeStorageOrMarket(address _market) {
        _validateMarketOrTradeStorage(_market);
        _;
    }

    modifier onlyMarket(address _market) {
        _validateMarket(_market);
        _;
    }

    modifier onlyMinter(address _marketToken) {
        _validateMinter(_marketToken);
        _;
    }

    modifier onlyRouter() {
        _validateRole(Roles.ROUTER);
        _;
    }

    modifier onlyCallback() {
        _validateCallback();
        _;
    }

    constructor(address _roleStorage) {
        roleStorage = RoleStorage(_roleStorage);
    }

    function _validateRole(bytes32 _role) private view {
        if (!roleStorage.hasRole(_role, msg.sender)) revert RoleValidation_AccessDenied();
    }

    function _validateMarket(address _market) private view {
        if (msg.sender != _market) revert RoleValidation_AccessDenied();
    }

    function _validateMinter(address _marketToken) private view {
        if (roleStorage.getMinter(_marketToken) != msg.sender) revert RoleValidation_AccessDenied();
    }

    function _validateTradeStorage(address _market) private view {
        if (!roleStorage.hasTradeStorageRole(_market, msg.sender)) revert RoleValidation_AccessDenied();
    }

    function _validateMarketOrTradeStorage(address _market) private view {
        if (!roleStorage.hasTradeStorageRole(_market, msg.sender) && msg.sender != _market) {
            revert RoleValidation_AccessDenied();
        }
    }

    function _validateConfigurator(address _market) private view {
        if (!roleStorage.hasConfiguratorRole(_market, msg.sender)) revert RoleValidation_AccessDenied();
    }

    function _validateCallback() private view {
        if (msg.sender != address(this)) revert RoleValidation_AccessDenied();
    }
}
