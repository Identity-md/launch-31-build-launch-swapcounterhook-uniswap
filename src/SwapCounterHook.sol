// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";

/// @title SwapCounterHook
/// @notice Counts the swaps a pool has served. One `afterSwap`, one counter, nothing else.
/// @dev What this contract deliberately does not have, and what must stay absent if it is changed:
///
/// - No owner, admin, or privileged address. Nothing here is gated on an identity, so there is no
///   key whose loss or misuse matters and no answer needed to "who may call this".
/// - No funds. It never takes, settles, mints, donates or holds a currency, and it declares no
///   `*ReturnDelta` permission, so the pool manager never asks it to move value. `afterSwap`
///   returns a zero delta, which is the only delta it is allowed to return with
///   `afterSwapReturnDelta` off — a non-zero one would make the manager revert.
/// - No withdrawal path and no fee: there is nothing to withdraw and nothing to charge.
/// - No constructor argument beyond the pool manager, which a v4 hook cannot avoid — it is baked
///   into the creation code the deployment address is mined from.
/// - No upgradeability, no proxy, no `selfdestruct`, no setter. The counter only ever moves one
///   way, one step at a time, driven by the pool manager. Behaviour after deployment is final.
///
/// A hook that holds nothing and grants nobody authority has no question to answer about who may
/// withdraw or about what a second deployment at a CREATE2 address could reach.
///
/// The one invariant worth stating: `swapCount[id]` is monotonically non-decreasing and rises by
/// exactly one per completed swap on the pool `id` identifies. It is never reset, never decremented
/// and never written from anywhere but `_afterSwap`, which only the pool manager can reach. The
/// increment is a plain `+= 1` under Solidity's checked arithmetic — a `uint256` counting one per
/// swap cannot be made to overflow, and the check is not worth suppressing to save the gas.
contract SwapCounterHook is BaseHook {
    /// @notice Swaps served by each pool, keyed by pool id.
    /// @dev Public: the generated getter is the read path, and `getSwapCount` names the same value.
    mapping(PoolId poolId => uint256 swaps) public swapCount;

    /// @param _poolManager The pool manager whose callbacks this hook answers. Immutable, and part
    /// of the creation code the hook's address is mined from.
    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    /// @notice The swaps counted for a pool.
    /// @param poolId The id of the pool, `PoolKey.toId()`.
    /// @return The number of swaps `poolId` has served since this hook was deployed.
    function getSwapCount(PoolId poolId) public view returns (uint256) {
        return swapCount[poolId];
    }

    /// @inheritdoc BaseHook
    /// @dev `afterSwap` alone. Every other permission is false, including both return-delta flags:
    /// this hook observes, it does not price, block, or take. These bits are also what the hook's
    /// address is mined for, and `BaseHook`'s constructor refuses to deploy at an address that
    /// disagrees with them.
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice Counts the swap that just completed.
    /// @dev Reached only through `BaseHook.afterSwap`, which is `onlyPoolManager`. The swap's
    /// sender, params and delta are all ignored: every swap counts once, whoever routed it and
    /// whichever way it went. Returns a zero delta, so the pool's accounting is untouched.
    /// @return The `afterSwap` selector, as v4 requires, and a zero hook delta.
    function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        swapCount[key.toId()] += 1;
        return (IHooks.afterSwap.selector, int128(0));
    }
}
