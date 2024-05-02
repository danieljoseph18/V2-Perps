// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v5.0.0) (utils/structs/EnumerableMap.sol)
// This file was procedurally generated from scripts/generate/templates/EnumerableMap.js.

pragma solidity 0.8.23;

import {EnumerableSetLib} from "./EnumerableSetLib.sol";
import {IMarketFactory} from "../factory/interfaces/IMarketFactory.sol";
import {Pool} from "../markets/Pool.sol";
import {IPriceFeed} from "../oracle/interfaces/IPriceFeed.sol";

/**
 * @dev Custom implementation of OpenZeppelin's EnumerableMap library.
 * https://solidity.readthedocs.io/en/latest/types.html#mapping-types[`mapping`]
 * type.
 *
 * Maps have the following properties:
 *
 * - Entries are added, removed, and checked for existence in constant time
 * (O(1)).
 * - Entries are enumerated in O(n). No guarantees are made on the ordering.
 *
 * ```solidity
 * contract Example {
 *     // Add the library methods
 *     using EnumerableMap for EnumerableMap.UintToAddressMap;
 *
 *     // Declare a set state variable
 *     EnumerableMap.UintToAddressMap private myMap;
 * }
 * ```
 *
 * The following new map types are introducted:
 *
 * - `bytes32 -> DeployParams` (`DeployMap`)
 * - `bytes32 -> Pool.Input` (`MarketMap`)
 * - `bytes32 -> IPriceFeed.RequestData` (`PriceMap`)
 *
 * [WARNING]
 * ====
 * Trying to delete such a structure from storage will likely result in data corruption, rendering the structure
 * unusable.
 * See https://github.com/ethereum/solidity/pull/11843[ethereum/solidity#11843] for more info.
 *
 * In order to clean an EnumerableMap, you can either remove all elements one by one or create a fresh instance using an
 * array of EnumerableMap.
 * ====
 */
library EnumerableMap {
    using EnumerableSetLib for EnumerableSetLib.Bytes32Set;

    /**
     * @dev Query for a nonexistent map key.
     */
    error EnumerableMapNonexistentKey(bytes32 key);

    /**
     * ======================================== Market Creation Requests ========================================
     */
    struct DeployMap {
        EnumerableSetLib.Bytes32Set _keys;
        mapping(bytes32 => IMarketFactory.DeployParams) _values;
    }

    /**
     * @dev Adds a key-value pair to a map, or updates the value for an existing
     * key. O(1).
     *
     * Returns true if the key was added to the map, that is if it was not
     * already present.
     */
    function set(DeployMap storage map, bytes32 key, IMarketFactory.DeployParams calldata value)
        internal
        returns (bool)
    {
        map._values[key] = value;
        return map._keys.add(key);
    }

    /**
     * @dev Removes a key-value pair from a map. O(1).
     *
     * Returns true if the key was removed from the map, that is if it was present.
     */
    function remove(DeployMap storage map, bytes32 key) internal returns (bool) {
        delete map._values[key];
        return map._keys.remove(key);
    }

    /**
     * @dev Returns true if the key is in the map. O(1).
     */
    function contains(DeployMap storage map, bytes32 key) internal view returns (bool) {
        return map._keys.contains(key);
    }

    /**
     * @dev Returns the number of key-value pairs in the map. O(1).
     */
    function length(DeployMap storage map) internal view returns (uint256) {
        return map._keys.length();
    }

    /**
     * @dev Returns the key-value pair stored at position `index` in the map. O(1).
     *
     * Note that there are no guarantees on the ordering of entries inside the
     * array, and it may change when more entries are added or removed.
     *
     * Requirements:
     *
     * - `index` must be strictly less than {length}.
     */
    function at(DeployMap storage map, uint256 index)
        internal
        view
        returns (bytes32, IMarketFactory.DeployParams memory)
    {
        bytes32 key = map._keys.at(index);
        return (key, map._values[key]);
    }

    /**
     * @dev Tries to returns the value associated with `key`. O(1).
     * Does not revert if `key` is not in the map.
     */
    function tryGet(DeployMap storage map, bytes32 key)
        internal
        view
        returns (bool, IMarketFactory.DeployParams memory)
    {
        IMarketFactory.DeployParams memory value = map._values[key];
        if (value.owner == address(0)) {
            return (contains(map, key), value);
        } else {
            return (true, value);
        }
    }

    /**
     * @dev Returns the value associated with `key`. O(1).
     *
     * Requirements:
     *
     * - `key` must be in the map.
     */
    function get(DeployMap storage map, bytes32 key) internal view returns (IMarketFactory.DeployParams memory) {
        IMarketFactory.DeployParams memory value = map._values[key];
        if (value.owner == address(0) && !contains(map, key)) {
            revert EnumerableMapNonexistentKey(key);
        }
        return value;
    }

    /**
     * @dev Return the an array containing all the keys
     *
     * WARNING: This operation will copy the entire storage to memory, which can be quite expensive. This is designed
     * to mostly be used by view accessors that are queried without any gas fees. Developers should keep in mind that
     * this function has an unbounded cost, and using it as part of a state-changing function may render the function
     * uncallable if the map grows to a point where copying to memory consumes too much gas to fit in a block.
     */
    function keys(DeployMap storage map) internal view returns (bytes32[] memory) {
        return map._keys.values();
    }

    /**
     * ======================================== Market Deposits / Withdrawals ========================================
     */
    struct MarketMap {
        EnumerableSetLib.Bytes32Set _keys;
        mapping(bytes32 => Pool.Input) _values;
    }

    /**
     * @dev Adds a key-value pair to a map, or updates the value for an existing
     * key. O(1).
     */
    function set(MarketMap storage map, bytes32 key, Pool.Input memory value) internal returns (bool) {
        map._values[key] = value;
        return map._keys.add(key);
    }

    /**
     * @dev Removes a key-value pair from a map. O(1).
     */
    function remove(MarketMap storage map, bytes32 key) internal returns (bool) {
        delete map._values[key];
        return map._keys.remove(key);
    }

    /**
     * @dev Returns true if the key is in the map. O(1).
     */
    function contains(MarketMap storage map, bytes32 key) internal view returns (bool) {
        return map._keys.contains(key);
    }

    /**
     * @dev Returns the number of key-value pairs in the map. O(1).
     */
    function length(MarketMap storage map) internal view returns (uint256) {
        return map._keys.length();
    }

    /**
     * @dev Returns the key-value pair stored at position `index` in the map. O(1).
     *
     * Note that there are no guarantees on the ordering of entries inside the
     * array, and it may change when more entries are added or removed.
     *
     * Requirements:
     *
     * - `index` must be strictly less than {length}.
     */
    function at(MarketMap storage map, uint256 index) internal view returns (bytes32, Pool.Input memory) {
        bytes32 key = map._keys.at(index);
        return (key, map._values[key]);
    }

    /**
     * @dev Tries to returns the value associated with `key`. O(1).
     * Does not revert if `key` is not in the map.
     */
    function tryGet(MarketMap storage map, bytes32 key) internal view returns (bool, Pool.Input memory) {
        Pool.Input memory value = map._values[key];
        if (value.owner == address(0)) {
            return (contains(map, key), value);
        } else {
            return (true, value);
        }
    }

    /**
     * @dev Returns the value associated with `key`. O(1).
     *
     * Requirements:
     *
     * - `key` must be in the map.
     */
    function get(MarketMap storage map, bytes32 key) internal view returns (Pool.Input memory) {
        Pool.Input memory value = map._values[key];
        if (value.owner == address(0) && !contains(map, key)) {
            revert EnumerableMapNonexistentKey(key);
        }
        return value;
    }

    /**
     * @dev Return the an array containing all the keys
     *
     * WARNING: This operation will copy the entire storage to memory, which can be quite expensive. This is designed
     * to mostly be used by view accessors that are queried without any gas fees. Developers should keep in mind that
     * this function has an unbounded cost, and using it as part of a state-changing function may render the function
     * uncallable if the map grows to a point where copying to memory consumes too much gas to fit in a block.
     */
    function keys(MarketMap storage map) internal view returns (bytes32[] memory) {
        return map._keys.values();
    }

    /**
     * ======================================== Price Feed Requests ========================================
     */
    struct PriceMap {
        EnumerableSetLib.Bytes32Set _keys;
        mapping(bytes32 => IPriceFeed.RequestData) _values;
    }

    /**
     * @dev Adds a key-value pair to a map, or updates the value for an existing
     * key. O(1).
     */
    function set(PriceMap storage map, bytes32 key, IPriceFeed.RequestData memory value) internal returns (bool) {
        map._values[key] = value;
        return map._keys.add(key);
    }

    /**
     * @dev Removes a key-value pair from a map. O(1).
     */
    function remove(PriceMap storage map, bytes32 key) internal returns (bool) {
        delete map._values[key];
        return map._keys.remove(key);
    }

    /**
     * @dev Returns true if the key is in the map. O(1).
     */
    function contains(PriceMap storage map, bytes32 key) internal view returns (bool) {
        return map._keys.contains(key);
    }

    /**
     * @dev Returns the number of key-value pairs in the map. O(1).
     */
    function length(PriceMap storage map) internal view returns (uint256) {
        return map._keys.length();
    }

    /**
     * @dev Returns the key-value pair stored at position `index` in the map. O(1).
     *
     * Note that there are no guarantees on the ordering of entries inside the
     * array, and it may change when more entries are added or removed.
     *
     * Requirements:
     *
     * - `index` must be strictly less than {length}.
     */
    function at(PriceMap storage map, uint256 index) internal view returns (bytes32, IPriceFeed.RequestData memory) {
        bytes32 key = map._keys.at(index);
        return (key, map._values[key]);
    }

    /**
     * @dev Tries to returns the value associated with `key`. O(1).
     * Does not revert if `key` is not in the map.
     */
    function tryGet(PriceMap storage map, bytes32 key) internal view returns (bool, IPriceFeed.RequestData memory) {
        IPriceFeed.RequestData memory value = map._values[key];
        if (value.requester == address(0)) {
            return (contains(map, key), value);
        } else {
            return (true, value);
        }
    }

    /**
     * @dev Returns the value associated with `key`. O(1).
     *
     * Requirements:
     *
     * - `key` must be in the map.
     */
    function get(PriceMap storage map, bytes32 key) internal view returns (IPriceFeed.RequestData memory) {
        IPriceFeed.RequestData memory value = map._values[key];
        if (value.requester == address(0) && !contains(map, key)) {
            revert EnumerableMapNonexistentKey(key);
        }
        return value;
    }

    /**
     * @dev Return the an array containing all the keys
     *
     * WARNING: This operation will copy the entire storage to memory, which can be quite expensive. This is designed
     * to mostly be used by view accessors that are queried without any gas fees. Developers should keep in mind that
     * this function has an unbounded cost, and using it as part of a state-changing function may render the function
     * uncallable if the map grows to a point where copying to memory consumes too much gas to fit in a block.
     */
    function keys(PriceMap storage map) internal view returns (bytes32[] memory) {
        return map._keys.values();
    }
}
