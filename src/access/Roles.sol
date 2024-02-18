// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

library Roles {
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;

    bytes32 public constant MODERATOR = keccak256("MODERATOR");

    bytes32 public constant MARKET_MAKER = keccak256("MARKET_MAKER");

    bytes32 public constant PROCESSOR = keccak256("PROCESSOR");

    bytes32 public constant CONFIGURATOR = keccak256("CONFIGURATOR");

    bytes32 public constant TRADE_STORAGE = keccak256("TRADE_STORAGE");

    bytes32 public constant VAULT = keccak256("VAULT");

    bytes32 public constant KEEPER = keccak256("KEEPER");

    bytes32 public constant ROUTER = keccak256("ROUTER");

    bytes32 public constant STATE_UPDATER = keccak256("STATE_UPDATER");

    bytes32 public constant STATE_KEEPER = keccak256("STATE_KEEPER");

    bytes32 public constant FEE_ACCUMULATOR = keccak256("FEE_ACCUMULATOR");

    bytes32 public constant ADL_KEEPER = keccak256("ADL_KEEPER");

    bytes32 public constant LIQUIDATOR = keccak256("LIQUIDATOR");
}
