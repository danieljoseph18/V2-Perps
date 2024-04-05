// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

library Roles {
    struct MarketRoles {
        address tradeStorage;
        address stateKeeper;
        address configurator;
    }

    // Global
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
    // Global
    bytes32 public constant MARKET_FACTORY = keccak256("MARKET_FACTORY");
    // Global
    bytes32 public constant POSITION_MANAGER = keccak256("POSITION_MANAGER");
    // Local
    bytes32 public constant CONFIGURATOR = keccak256("CONFIGURATOR");
    // Local
    bytes32 public constant TRADE_STORAGE = keccak256("TRADE_STORAGE");
    // Global
    bytes32 public constant KEEPER = keccak256("KEEPER");
    // Local
    bytes32 public constant ROUTER = keccak256("ROUTER");
    // Local
    bytes32 public constant STATE_KEEPER = keccak256("STATE_KEEPER");
    // Global
    bytes32 public constant ADL_KEEPER = keccak256("ADL_KEEPER");
    // Global
    bytes32 public constant LIQUIDATOR = keccak256("LIQUIDATOR");
    // Global
    bytes32 public constant MARKET_KEEPER = keccak256("MARKET_KEEPER");
}
