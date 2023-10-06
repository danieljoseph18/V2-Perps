// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Roles} from "./Roles.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

contract RoleStorage is AccessControl {
    constructor() {
        _grantRole(Roles.DEFAULT_ADMIN_ROLE, msg.sender);
    }
}