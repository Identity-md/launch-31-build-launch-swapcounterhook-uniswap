// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {CurrencySettler} from "v4-core/test/utils/CurrencySettler.sol";

/// @notice A router that puts several swaps inside a single `unlock`, settling only the net.
/// @dev `PoolSwapTest` opens one lock per swap, so a test written on it cannot tell "counted once
/// per swap" apart from "counted once per transaction" or "once per lock". This can: the swaps
/// share a lock, a transaction and a `msg.sender`, and only the sum of their deltas is settled at
/// the end. Anything a hook accumulates across them has to come from the swaps themselves.
///
/// The caller must have approved this router for both currencies. Native currencies are not
/// supported — a batch of swaps in both directions has no single payer for ETH.
contract BatchSwapRouter is IUnlockCallback {
    using CurrencySettler for Currency;
    using TransientStateLibrary for IPoolManager;

    IPoolManager public immutable manager;

    struct CallbackData {
        address sender;
        PoolKey key;
        SwapParams[] swaps;
    }

    constructor(IPoolManager _manager) {
        manager = _manager;
    }

    /// @notice Runs every entry of `swaps` against `key`, in order, in one lock.
    function swapMany(PoolKey memory key, SwapParams[] memory swaps) external {
        manager.unlock(abi.encode(CallbackData(msg.sender, key, swaps)));
    }

    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        require(msg.sender == address(manager), "not the manager");

        CallbackData memory data = abi.decode(rawData, (CallbackData));

        for (uint256 i = 0; i < data.swaps.length; i++) {
            manager.swap(data.key, data.swaps[i], "");
        }

        _resolve(data.key.currency0, data.sender);
        _resolve(data.key.currency1, data.sender);

        return "";
    }

    /// @dev Pays what this router owes out of `sender`'s balance, and forwards what it is owed.
    function _resolve(Currency currency, address sender) internal {
        int256 delta = manager.currencyDelta(address(this), currency);
        if (delta < 0) {
            currency.settle(manager, sender, uint256(-delta), false);
        } else if (delta > 0) {
            currency.take(manager, sender, uint256(delta), false);
        }
    }
}
