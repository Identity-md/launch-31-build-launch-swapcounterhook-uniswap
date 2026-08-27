// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Hooks} from "v4-core/src/libraries/Hooks.sol";

/// @title HookFlags
/// @notice The permission bits a Uniswap v4 hook carries in the low 14 bits of its own address.
/// @dev Every constant here is an alias of the matching flag in `Hooks`, so this library cannot
/// drift from v4-core: if upstream moves a bit, this moves with it. The point of the aliases is a
/// name that reads the same as the field in `Hooks.Permissions` (`afterSwapReturnDelta` ->
/// `AFTER_SWAP_RETURN_DELTA`), which is what a deployer mines an address against and what a
/// reviewer compares a hook's declaration to.
library HookFlags {
    /// @notice Mask of every permission bit — the low 14 bits of an address, and nothing above them.
    uint160 internal constant ALL = Hooks.ALL_HOOK_MASK;

    uint160 internal constant BEFORE_INITIALIZE = Hooks.BEFORE_INITIALIZE_FLAG;
    uint160 internal constant AFTER_INITIALIZE = Hooks.AFTER_INITIALIZE_FLAG;

    uint160 internal constant BEFORE_ADD_LIQUIDITY = Hooks.BEFORE_ADD_LIQUIDITY_FLAG;
    uint160 internal constant AFTER_ADD_LIQUIDITY = Hooks.AFTER_ADD_LIQUIDITY_FLAG;

    uint160 internal constant BEFORE_REMOVE_LIQUIDITY = Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG;
    uint160 internal constant AFTER_REMOVE_LIQUIDITY = Hooks.AFTER_REMOVE_LIQUIDITY_FLAG;

    uint160 internal constant BEFORE_SWAP = Hooks.BEFORE_SWAP_FLAG;
    uint160 internal constant AFTER_SWAP = Hooks.AFTER_SWAP_FLAG;

    uint160 internal constant BEFORE_DONATE = Hooks.BEFORE_DONATE_FLAG;
    uint160 internal constant AFTER_DONATE = Hooks.AFTER_DONATE_FLAG;

    uint160 internal constant BEFORE_SWAP_RETURN_DELTA = Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG;
    uint160 internal constant AFTER_SWAP_RETURN_DELTA = Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
    uint160 internal constant AFTER_ADD_LIQUIDITY_RETURN_DELTA = Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG;
    uint160 internal constant AFTER_REMOVE_LIQUIDITY_RETURN_DELTA = Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG;

    /// @notice The permissions `hook`'s address advertises to the pool manager.
    /// @param hook The address a hook is (or would be) deployed at.
    /// @return The permission bits carried by that address, with everything above bit 13 cleared.
    function flagsOf(address hook) internal pure returns (uint160) {
        return uint160(hook) & ALL;
    }

    /// @notice Whether `hook` advertises exactly `flags` and no other permission.
    /// @dev Exact, not a subset test, and deliberately so. The pool manager calls precisely the
    /// callbacks the address advertises, so an address carrying a bit the implementation did not
    /// declare is one v4 will call for a callback the hook does not implement. A hook constructor
    /// that validates its own address (`Hooks.validateHookPermissions`) rejects such an address, so
    /// mining against a subset test would find salts whose deployment then reverts.
    /// @param hook The address a hook is (or would be) deployed at.
    /// @param flags The permission bits the implementation declares; bits above 13 are ignored.
    /// @return True when the address advertises the declared permissions and nothing more.
    function matches(address hook, uint160 flags) internal pure returns (bool) {
        return flagsOf(hook) == (flags & ALL);
    }
}
