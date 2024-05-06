// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IMarket} from "../markets/interfaces/IMarket.sol";
import {IVault} from "../markets/interfaces/IVault.sol";
import {IReferralStorage} from "../referrals/interfaces/IReferralStorage.sol";
import {IPriceFeed} from "../oracle/interfaces/IPriceFeed.sol";
import {Position} from "./Position.sol";
import {EnumerableSetLib} from "../libraries/EnumerableSetLib.sol";

library Trade {
    struct State {
        IVault vault;
        mapping(bytes32 _key => Position.Request _order) orders;
        EnumerableSetLib.Bytes32Set marketOrderKeys;
        EnumerableSetLib.Bytes32Set limitOrderKeys;
        mapping(bytes32 _positionKey => Position.Data) openPositions;
        mapping(bool _isLong => EnumerableSetLib.Bytes32Set _positionKeys) openPositionKeys;
        bool isInitialized;
    }
}
