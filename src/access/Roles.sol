// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

library Roles {
    struct MarketRoles {
        address tradeStorage;
        address configurator;
    }

    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 public constant MARKET_FACTORY = keccak256("MARKET_FACTORY");
    bytes32 public constant POSITION_MANAGER = keccak256("POSITION_MANAGER");
    bytes32 public constant CONFIGURATOR = keccak256("CONFIGURATOR");
    bytes32 public constant TRADE_STORAGE = keccak256("TRADE_STORAGE");
    bytes32 public constant ROUTER = keccak256("ROUTER");
}
