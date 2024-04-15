// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

library Roles {
    struct MarketRoles {
        address tradeStorage;
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
    // Local
    bytes32 public constant ROUTER = keccak256("ROUTER");
    // Global
    bytes32 public constant MARKET_KEEPER = keccak256("MARKET_KEEPER");
}
