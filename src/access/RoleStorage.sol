// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.21;

import {Roles} from "./Roles.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

contract RoleStorage is AccessControl {
    constructor() {
        _grantRole(Roles.DEFAULT_ADMIN_ROLE, msg.sender);
    }
}
