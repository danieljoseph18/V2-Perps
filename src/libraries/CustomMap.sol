// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v5.0.0) (utils/structs/EnumerableMap.sol)
// This file was procedurally generated from scripts/generate/templates/EnumerableMap.js.

pragma solidity 0.8.23;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IMarketFactory} from "../markets/interfaces/IMarketFactory.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
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
 * - `bytes32 -> DeployRequest` (`DeployRequestMap`)
 * - `bytes32 -> IMarket.Input` (`MarketRequestMap`)
 * - `bytes32 -> IPriceFeed.RequestData` (`PriceRequestMap`)
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
library CustomMap {
    using EnumerableSet for EnumerableSet.Bytes32Set;

    /**
     * @dev Query for a nonexistent map key.
     */
    error EnumerableMapNonexistentKey(bytes32 key);

    /**
     * ======================================== Market Creation Requests ========================================
     */
    struct DeployRequestMap {
        EnumerableSet.Bytes32Set _keys;
        mapping(bytes32 => IMarketFactory.DeployRequest) _values;
    }

    /**
     * @dev Adds a key-value pair to a map, or updates the value for an existing
     * key. O(1).
     *
     * Returns true if the key was added to the map, that is if it was not
     * already present.
     */
    function set(DeployRequestMap storage map, bytes32 key, IMarketFactory.DeployRequest calldata value)
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
    function remove(DeployRequestMap storage map, bytes32 key) internal returns (bool) {
        delete map._values[key];
        return map._keys.remove(key);
    }

    /**
     * @dev Returns true if the key is in the map. O(1).
     */
    function contains(DeployRequestMap storage map, bytes32 key) internal view returns (bool) {
        return map._keys.contains(key);
    }

    /**
     * @dev Returns the number of key-value pairs in the map. O(1).
     */
    function length(DeployRequestMap storage map) internal view returns (uint256) {
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
    function at(DeployRequestMap storage map, uint256 index)
        internal
        view
        returns (bytes32, IMarketFactory.DeployRequest memory)
    {
        bytes32 key = map._keys.at(index);
        return (key, map._values[key]);
    }

    /**
     * @dev Tries to returns the value associated with `key`. O(1).
     * Does not revert if `key` is not in the map.
     */
    function tryGet(DeployRequestMap storage map, bytes32 key)
        internal
        view
        returns (bool, IMarketFactory.DeployRequest memory)
    {
        IMarketFactory.DeployRequest memory value = map._values[key];
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
    function get(DeployRequestMap storage map, bytes32 key)
        internal
        view
        returns (IMarketFactory.DeployRequest memory)
    {
        IMarketFactory.DeployRequest memory value = map._values[key];
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
    function keys(DeployRequestMap storage map) internal view returns (bytes32[] memory) {
        return map._keys.values();
    }

    /**
     * ======================================== Market Deposits / Withdrawals ========================================
     */
    struct MarketRequestMap {
        EnumerableSet.Bytes32Set _keys;
        mapping(bytes32 => IMarket.Input) _values;
    }

    /**
     * @dev Adds a key-value pair to a map, or updates the value for an existing
     * key. O(1).
     */
    function set(MarketRequestMap storage map, bytes32 key, IMarket.Input calldata value) internal returns (bool) {
        map._values[key] = value;
        return map._keys.add(key);
    }

    /**
     * @dev Removes a key-value pair from a map. O(1).
     */
    function remove(MarketRequestMap storage map, bytes32 key) internal returns (bool) {
        delete map._values[key];
        return map._keys.remove(key);
    }

    /**
     * @dev Returns true if the key is in the map. O(1).
     */
    function contains(MarketRequestMap storage map, bytes32 key) internal view returns (bool) {
        return map._keys.contains(key);
    }

    /**
     * @dev Returns the number of key-value pairs in the map. O(1).
     */
    function length(MarketRequestMap storage map) internal view returns (uint256) {
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
    function at(MarketRequestMap storage map, uint256 index) internal view returns (bytes32, IMarket.Input memory) {
        bytes32 key = map._keys.at(index);
        return (key, map._values[key]);
    }

    /**
     * @dev Tries to returns the value associated with `key`. O(1).
     * Does not revert if `key` is not in the map.
     */
    function tryGet(MarketRequestMap storage map, bytes32 key) internal view returns (bool, IMarket.Input memory) {
        IMarket.Input memory value = map._values[key];
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
    function get(MarketRequestMap storage map, bytes32 key) internal view returns (IMarket.Input memory) {
        IMarket.Input memory value = map._values[key];
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
    function keys(MarketRequestMap storage map) internal view returns (bytes32[] memory) {
        return map._keys.values();
    }

    /**
     * ======================================== Price Feed Requests ========================================
     */
    struct PriceRequestMap {
        EnumerableSet.Bytes32Set _keys;
        mapping(bytes32 => IPriceFeed.RequestData) _values;
    }

    /**
     * @dev Adds a key-value pair to a map, or updates the value for an existing
     * key. O(1).
     */
    function set(PriceRequestMap storage map, bytes32 key, IPriceFeed.RequestData memory value)
        internal
        returns (bool)
    {
        map._values[key] = value;
        return map._keys.add(key);
    }

    /**
     * @dev Removes a key-value pair from a map. O(1).
     */
    function remove(PriceRequestMap storage map, bytes32 key) internal returns (bool) {
        delete map._values[key];
        return map._keys.remove(key);
    }

    /**
     * @dev Returns true if the key is in the map. O(1).
     */
    function contains(PriceRequestMap storage map, bytes32 key) internal view returns (bool) {
        return map._keys.contains(key);
    }

    /**
     * @dev Returns the number of key-value pairs in the map. O(1).
     */
    function length(PriceRequestMap storage map) internal view returns (uint256) {
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
    function at(PriceRequestMap storage map, uint256 index)
        internal
        view
        returns (bytes32, IPriceFeed.RequestData memory)
    {
        bytes32 key = map._keys.at(index);
        return (key, map._values[key]);
    }

    /**
     * @dev Tries to returns the value associated with `key`. O(1).
     * Does not revert if `key` is not in the map.
     */
    function tryGet(PriceRequestMap storage map, bytes32 key)
        internal
        view
        returns (bool, IPriceFeed.RequestData memory)
    {
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
    function get(PriceRequestMap storage map, bytes32 key) internal view returns (IPriceFeed.RequestData memory) {
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
    function keys(PriceRequestMap storage map) internal view returns (bytes32[] memory) {
        return map._keys.values();
    }
}
