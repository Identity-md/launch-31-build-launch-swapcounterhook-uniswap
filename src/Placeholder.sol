// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

/// @title Placeholder
/// @notice Stands in for the Uniswap v4 hook this repository exists to hold.
/// @dev It carries no hook behaviour on purpose. All it does is take the pool manager the way a
/// hook does — as a constructor argument that is baked into the creation code — so that `src/`
/// compiles against the vendored v4 libraries and the toolchain can be proven end to end before
/// any hook logic is written. Delete it when the hook lands.
contract Placeholder {
    /// @notice The pool manager a hook deployed from this project would be bound to.
    IPoolManager public immutable poolManager;

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }
}
