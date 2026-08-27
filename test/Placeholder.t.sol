// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {Placeholder} from "../src/Placeholder.sol";

/// @notice Proves the vendored toolchain works, so that a failure here is a failure of the setup
/// and not of whatever hook is written next.
/// @dev Deploying a real `PoolManager` exercises v4-core, and mining a salt with `HookMiner`
/// exercises v4-periphery — the two libraries a hook is built on. Both are compiled from `lib/`,
/// which is committed, so this passes with the network unplugged.
contract PlaceholderTest is Test {
    PoolManager manager;

    function setUp() public {
        manager = new PoolManager(address(this));
    }

    function test_placeholderIsBoundToThePoolManager() public {
        Placeholder placeholder = new Placeholder(IPoolManager(address(manager)));
        assertEq(address(placeholder.poolManager()), address(manager));
    }

    /// @dev v4 reads a hook's permissions off the low 14 bits of its address, so every hook this
    /// project ships has to be deployable at a mined address. This checks the mining path works.
    function test_anAddressCanBeMinedForHookFlags() public view {
        uint160 flags = Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG;

        (address hookAddress, bytes32 salt) = HookMiner.find(
            address(this), flags, type(Placeholder).creationCode, abi.encode(IPoolManager(address(manager)))
        );

        assertEq(uint160(hookAddress) & Hooks.ALL_HOOK_MASK, flags, "mined address does not carry the flags");
        assertEq(
            hookAddress,
            HookMiner.computeAddress(
                address(this),
                uint256(salt),
                abi.encodePacked(type(Placeholder).creationCode, abi.encode(IPoolManager(address(manager))))
            ),
            "salt does not reproduce the mined address"
        );
    }
}
