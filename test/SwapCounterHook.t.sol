// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {BalanceDelta, BalanceDeltaLibrary, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {ImmutableState} from "v4-periphery/src/base/ImmutableState.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";

import {SwapCounterHook} from "../src/SwapCounterHook.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {BatchSwapRouter} from "./utils/BatchSwapRouter.sol";

/// @notice The behaviour `SwapCounterHook` claims, checked against a real `PoolManager`.
/// @dev The hook is deployed the way it will be deployed for real — CREATE2 at an address mined
/// for its permission bits — and driven through the manager rather than called directly, because a
/// hook that only ever behaves correctly when a test calls it by hand has not been tested at all.
/// Where a test does call `afterSwap` directly it says so, and it is either checking the return
/// values v4 reads or checking that the call is refused.
///
/// Four pools are stood up in `setUp`, and they exist to make the counter's key observable:
///
/// - `hookedKey`      the pool under test.
/// - `sameTokensKey`  same two tokens, different fee tier, same hook. Differs from `hookedKey` only
///                    in the pool id, so a counter keyed on anything coarser than the id — the
///                    token pair, or the hook itself — would leak between the two.
/// - `otherTokensKey` a different pair entirely, same hook.
/// - `plainKey`       same tokens and fee as `hookedKey` but no hook, so its swaps must not be
///                    counted anywhere, and its output is what an unhooked swap costs.
contract SwapCounterHookTest is Deployers {
    using StateLibrary for IPoolManager;

    SwapCounterHook internal hook;
    BatchSwapRouter internal batchRouter;

    PoolKey internal hookedKey;
    PoolKey internal sameTokensKey;
    PoolKey internal otherTokensKey;
    PoolKey internal plainKey;

    PoolId internal hookedId;
    PoolId internal sameTokensId;
    PoolId internal otherTokensId;
    PoolId internal plainId;

    /// @dev The one permission the hook declares, and therefore the only bit its address may carry.
    uint160 internal constant EXPECTED_FLAGS = uint160(Hooks.AFTER_SWAP_FLAG);

    /// @dev Small enough to stay inside the seeded range at every price these tests reach.
    int256 internal constant SWAP_IN = 1e15;

    PoolSwapTest.TestSettings internal settings =
        PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        hook = deployHookAtMinedAddress(EXPECTED_FLAGS);

        batchRouter = new BatchSwapRouter(manager);
        IERC20Minimal(Currency.unwrap(currency0)).approve(address(batchRouter), type(uint256).max);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(batchRouter), type(uint256).max);

        (hookedKey, hookedId) =
            initPoolAndAddLiquidity(currency0, currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);
        (sameTokensKey, sameTokensId) =
            initPoolAndAddLiquidity(currency0, currency1, IHooks(address(hook)), 500, SQRT_PRICE_1_1);
        (plainKey, plainId) = initPoolAndAddLiquidity(currency0, currency1, IHooks(address(0)), 3000, SQRT_PRICE_1_1);

        Currency a = deployMintAndApproveCurrency();
        Currency b = deployMintAndApproveCurrency();
        (Currency c0, Currency c1) = Currency.unwrap(a) < Currency.unwrap(b) ? (a, b) : (b, a);
        (otherTokensKey, otherTokensId) = initPoolAndAddLiquidity(c0, c1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);
    }

    /*//////////////////////////////////////////////////////////////
                          COUNTING, PER SWAP
    //////////////////////////////////////////////////////////////*/

    /// @notice A single zero-for-one swap moves the counter by exactly one.
    function test_countsOneSwapZeroForOne() public {
        assertEq(hook.getSwapCount(hookedId), 0, "a fresh pool has counted nothing");

        swap(hookedKey, true, -SWAP_IN, ZERO_BYTES);

        assertEq(hook.getSwapCount(hookedId), 1);
    }

    /// @notice And so does a one-for-zero swap: direction is not part of what is counted.
    function test_countsOneSwapOneForZero() public {
        swap(hookedKey, false, -SWAP_IN, ZERO_BYTES);

        assertEq(hook.getSwapCount(hookedId), 1);
    }

    /// @notice Swaps in both directions accumulate into the same counter, one each.
    function test_countsEverySwapInBothDirections() public {
        uint256 expected;
        for (uint256 i = 0; i < 3; i++) {
            swap(hookedKey, true, -SWAP_IN, ZERO_BYTES);
            expected++;
            assertEq(hook.getSwapCount(hookedId), expected, "zero-for-one leg");

            swap(hookedKey, false, -SWAP_IN, ZERO_BYTES);
            expected++;
            assertEq(hook.getSwapCount(hookedId), expected, "one-for-zero leg");
        }

        assertEq(hook.getSwapCount(hookedId), 6);
    }

    /// @notice Exact-output swaps count the same as exact-input ones.
    /// @dev A positive `amountSpecified` takes a different path through `Pool.swap` and returns a
    /// differently shaped delta. The hook reads neither, and this pins that down.
    function test_countsExactOutputSwaps() public {
        swap(hookedKey, true, SWAP_IN, ZERO_BYTES);
        swap(hookedKey, false, SWAP_IN, ZERO_BYTES);

        assertEq(hook.getSwapCount(hookedId), 2);
    }

    /// @notice Two swaps inside one lock count twice, not once.
    /// @dev The distinction a per-transaction or per-lock counter would fail. Both swaps share a
    /// transaction, a lock and a `msg.sender`, and only their net delta is settled.
    function test_countsEachSwapInsideASingleLock() public {
        SwapParams[] memory swaps = new SwapParams[](3);
        swaps[0] = SwapParams({zeroForOne: true, amountSpecified: -SWAP_IN, sqrtPriceLimitX96: MIN_PRICE_LIMIT});
        swaps[1] = SwapParams({zeroForOne: false, amountSpecified: -SWAP_IN, sqrtPriceLimitX96: MAX_PRICE_LIMIT});
        swaps[2] = SwapParams({zeroForOne: true, amountSpecified: -SWAP_IN, sqrtPriceLimitX96: MIN_PRICE_LIMIT});

        batchRouter.swapMany(hookedKey, swaps);

        assertEq(hook.getSwapCount(hookedId), 3, "three swaps in one lock counted as three");
    }

    /// @notice The counter does not care which router the swap came through.
    /// @dev `sender` is the router, not the trader, and the hook ignores it. A second router must
    /// therefore be counted into the same total as the first.
    function test_countsSwapsFromAnyRouter() public {
        swap(hookedKey, true, -SWAP_IN, ZERO_BYTES);

        swapRouterNoChecks.swap(
            hookedKey, SwapParams({zeroForOne: true, amountSpecified: -SWAP_IN, sqrtPriceLimitX96: MIN_PRICE_LIMIT})
        );

        assertEq(hook.getSwapCount(hookedId), 2);
    }

    /// @notice Whoever sends the swap, it is one count.
    function testFuzz_countsSwapsFromAnySender(address trader) public {
        vm.assume(trader != address(0) && trader.code.length == 0);
        assumeNotPrecompile(trader);
        assumeNotForgeAddress(trader);

        IERC20Minimal token0 = IERC20Minimal(Currency.unwrap(currency0));
        token0.transfer(trader, uint256(SWAP_IN) * 2);

        vm.startPrank(trader);
        token0.approve(address(swapRouter), type(uint256).max);
        swapRouter.swap(
            hookedKey,
            SwapParams({zeroForOne: true, amountSpecified: -SWAP_IN, sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            settings,
            ZERO_BYTES
        );
        vm.stopPrank();

        assertEq(hook.getSwapCount(hookedId), 1);
    }

    /// @notice Hook data is ignored, including data shaped like something the hook might decode.
    function testFuzz_hookDataDoesNotChangeTheCount(bytes calldata hookData) public {
        vm.assume(hookData.length <= 512);

        swap(hookedKey, true, -SWAP_IN, hookData);

        assertEq(hook.getSwapCount(hookedId), 1);
    }

    /// @notice n swaps, n counts, for any n.
    function testFuzz_oneCountPerSwap(uint8 rawCount, bool firstDirection) public {
        uint256 count = bound(rawCount, 1, 12);

        bool zeroForOne = firstDirection;
        for (uint256 i = 0; i < count; i++) {
            swap(hookedKey, zeroForOne, -SWAP_IN, ZERO_BYTES);
            zeroForOne = !zeroForOne;
        }

        assertEq(hook.getSwapCount(hookedId), count);
    }

    /// @notice The size of the swap is not part of the increment.
    function testFuzz_swapSizeDoesNotChangeTheIncrement(uint256 rawAmount, bool zeroForOne) public {
        int256 amount = int256(bound(rawAmount, 1, 1e15));

        swap(hookedKey, zeroForOne, -amount, ZERO_BYTES);

        assertEq(hook.getSwapCount(hookedId), 1);
    }

    /*//////////////////////////////////////////////////////////////
                             THE READ PATH
    //////////////////////////////////////////////////////////////*/

    /// @notice `getSwapCount` and the generated getter are the same number, before and after swaps.
    function test_getSwapCountAgreesWithTheMapping() public {
        assertEq(hook.getSwapCount(hookedId), hook.swapCount(hookedId), "before any swap");

        swap(hookedKey, true, -SWAP_IN, ZERO_BYTES);
        swap(hookedKey, false, -SWAP_IN, ZERO_BYTES);

        assertEq(hook.getSwapCount(hookedId), hook.swapCount(hookedId), "after swaps");
        assertEq(hook.getSwapCount(hookedId), 2, "and it is the number of swaps");
    }

    /// @notice A pool nobody has swapped — or that does not exist — reads as zero, not as a revert.
    function testFuzz_unknownPoolsReadAsZero(bytes32 rawId) public view {
        PoolId id = PoolId.wrap(rawId);
        vm.assume(PoolId.unwrap(id) != PoolId.unwrap(hookedId));
        vm.assume(PoolId.unwrap(id) != PoolId.unwrap(sameTokensId));
        vm.assume(PoolId.unwrap(id) != PoolId.unwrap(otherTokensId));

        assertEq(hook.getSwapCount(id), 0);
        assertEq(hook.swapCount(id), 0);
    }

    /*//////////////////////////////////////////////////////////////
                         INDEPENDENCE BETWEEN POOLS
    //////////////////////////////////////////////////////////////*/

    /// @notice Two pools sharing this hook keep separate counts.
    /// @dev `sameTokensKey` differs from `hookedKey` in nothing but its fee tier, so it is the pool
    /// most likely to be confused with it.
    function test_poolsCountIndependently() public {
        for (uint256 i = 0; i < 3; i++) {
            swap(hookedKey, i % 2 == 0, -SWAP_IN, ZERO_BYTES);
        }
        swap(sameTokensKey, true, -SWAP_IN, ZERO_BYTES);
        swap(otherTokensKey, false, -SWAP_IN, ZERO_BYTES);
        swap(otherTokensKey, true, -SWAP_IN, ZERO_BYTES);

        assertEq(hook.getSwapCount(hookedId), 3, "pool under test");
        assertEq(hook.getSwapCount(sameTokensId), 1, "same tokens, other fee tier");
        assertEq(hook.getSwapCount(otherTokensId), 2, "other token pair");
    }

    /// @notice Swapping one pool leaves every other pool's count exactly where it was.
    function test_aSwapTouchesOnlyItsOwnPool() public {
        swap(sameTokensKey, true, -SWAP_IN, ZERO_BYTES);
        swap(otherTokensKey, true, -SWAP_IN, ZERO_BYTES);

        uint256 sameBefore = hook.getSwapCount(sameTokensId);
        uint256 otherBefore = hook.getSwapCount(otherTokensId);

        swap(hookedKey, true, -SWAP_IN, ZERO_BYTES);

        assertEq(hook.getSwapCount(hookedId), 1, "the swapped pool moved");
        assertEq(hook.getSwapCount(sameTokensId), sameBefore, "an untouched pool did not");
        assertEq(hook.getSwapCount(otherTokensId), otherBefore, "nor did the other one");
    }

    /// @notice A pool that does not name this hook is not counted anywhere.
    /// @dev `plainKey` is the same two tokens at the same fee, with the hooks field empty.
    function test_swapsOnAPoolWithoutTheHookAreNotCounted() public {
        swap(plainKey, true, -SWAP_IN, ZERO_BYTES);
        swap(plainKey, false, -SWAP_IN, ZERO_BYTES);

        assertEq(hook.getSwapCount(plainId), 0, "the unhooked pool's id");
        assertEq(hook.getSwapCount(hookedId), 0, "and nothing leaked into the hooked one");
        assertEq(hook.getSwapCount(sameTokensId), 0);
        assertEq(hook.getSwapCount(otherTokensId), 0);
    }

    /// @notice A pool whose currency0 is native ETH is counted like any other.
    /// @dev Native currencies settle through `msg.value` instead of a transfer, which is a
    /// different path through the manager and a plausible place for a hook to be skipped. It is
    /// also the only pool shape where the hook could be sent ETH, so that is checked too.
    function test_countsSwapsOnANativeEthPool() public {
        vm.deal(address(this), 100 ether);

        (PoolKey memory nativeK, PoolId nativeIdLocal) = initPoolAndAddLiquidityETH(
            CurrencyLibrary.ADDRESS_ZERO, currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1, 1 ether
        );

        swapNativeInput(nativeK, true, -SWAP_IN, ZERO_BYTES, uint256(SWAP_IN));
        assertEq(hook.getSwapCount(nativeIdLocal), 1, "the native-input swap");

        swapNativeInput(nativeK, false, -SWAP_IN, ZERO_BYTES, 0);
        assertEq(hook.getSwapCount(nativeIdLocal), 2, "and the swap back out");

        assertEq(address(hook).balance, 0, "the hook was sent ETH");
        assertEq(hook.getSwapCount(hookedId), 0, "the ERC-20 pool's count moved");
    }

    /// @notice A dynamic-fee pool naming this hook is counted like any other.
    /// @dev The hook implements no fee callback, so such a pool sits at a zero LP fee forever — it
    /// is still a pool, its swaps are still swaps, and they land on their own id.
    function test_countsSwapsOnADynamicFeePool() public {
        (PoolKey memory dynamicKey, PoolId dynamicId) = initPoolAndAddLiquidity(
            currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1
        );

        swap(dynamicKey, true, -SWAP_IN, ZERO_BYTES);
        swap(dynamicKey, false, -SWAP_IN, ZERO_BYTES);

        assertEq(hook.getSwapCount(dynamicId), 2);
        assertEq(hook.getSwapCount(hookedId), 0, "the static-fee pool's count moved");
    }

    /*//////////////////////////////////////////////////////////////
                        WHAT AFTERSWAP RETURNS
    //////////////////////////////////////////////////////////////*/

    /// @notice `afterSwap` answers with its own selector and a zero delta.
    /// @dev Called as the manager, because those two return values are exactly what the manager
    /// reads: a mismatched selector is `InvalidHookResponse`, and the delta is what it would charge
    /// the swapper if the hook were permitted to return one.
    function test_afterSwapReturnsTheSelectorAndAZeroDelta() public {
        vm.prank(address(manager));
        (bytes4 selector, int128 delta) = IHooks(address(hook))
            .afterSwap(
                address(this),
                hookedKey,
                SwapParams({zeroForOne: true, amountSpecified: -SWAP_IN, sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
                BalanceDeltaLibrary.ZERO_DELTA,
                ZERO_BYTES
            );

        assertEq(bytes32(selector), bytes32(IHooks.afterSwap.selector), "selector");
        assertEq(delta, int128(0), "hook delta");
        assertEq(hook.getSwapCount(hookedId), 1, "and the call counted");
    }

    /// @notice The zero delta holds whatever the swap looked like.
    function testFuzz_afterSwapAlwaysReturnsAZeroDelta(
        address sender,
        bool zeroForOne,
        int256 amountSpecified,
        int128 amount0,
        int128 amount1
    ) public {
        vm.prank(address(manager));
        (bytes4 selector, int128 delta) = IHooks(address(hook))
            .afterSwap(
                sender,
                hookedKey,
                SwapParams({zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: 0}),
                toBalanceDelta(amount0, amount1),
                ZERO_BYTES
            );

        assertEq(bytes32(selector), bytes32(IHooks.afterSwap.selector));
        assertEq(delta, int128(0));
    }

    /// @notice The hook takes nothing out of the swap it observes.
    /// @dev The zero delta is only half the claim; the other half is that the swapper ends up with
    /// exactly what an unhooked pool would have given. `plainKey` is that pool: same tokens, same
    /// fee, same seeded liquidity, same starting price. The two deltas have to match to the wei.
    function test_theHookDoesNotTouchTheSwapDelta() public {
        BalanceDelta hooked = swap(hookedKey, true, -SWAP_IN, ZERO_BYTES);
        BalanceDelta plain = swap(plainKey, true, -SWAP_IN, ZERO_BYTES);

        assertEq(hooked.amount0(), plain.amount0(), "amount0 differs from the unhooked pool");
        assertEq(hooked.amount1(), plain.amount1(), "amount1 differs from the unhooked pool");

        assertEq(IERC20Minimal(Currency.unwrap(currency0)).balanceOf(address(hook)), 0, "the hook holds currency0");
        assertEq(IERC20Minimal(Currency.unwrap(currency1)).balanceOf(address(hook)), 0, "the hook holds currency1");
        assertEq(manager.balanceOf(address(hook), currency0.toId()), 0, "the hook holds claims on currency0");
        assertEq(manager.balanceOf(address(hook), currency1.toId()), 0, "the hook holds claims on currency1");
    }

    /*//////////////////////////////////////////////////////////////
                     CALLERS THAT ARE NOT THE MANAGER
    //////////////////////////////////////////////////////////////*/

    /// @notice A direct `afterSwap` is refused, and refused without counting.
    /// @dev The whole value of the counter rests on this. If anyone could call `afterSwap` the
    /// number would say how many times someone called a function, not how many swaps a pool served.
    function testFuzz_afterSwapRefusesEveryCallerButTheManager(address caller) public {
        vm.assume(caller != address(manager));

        swap(hookedKey, true, -SWAP_IN, ZERO_BYTES);
        uint256 before = hook.getSwapCount(hookedId);

        vm.prank(caller);
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        IHooks(address(hook))
            .afterSwap(
                caller,
                hookedKey,
                SwapParams({zeroForOne: true, amountSpecified: -SWAP_IN, sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
                BalanceDeltaLibrary.ZERO_DELTA,
                ZERO_BYTES
            );

        assertEq(hook.getSwapCount(hookedId), before, "a refused call still moved the counter");
    }

    /// @notice Every callback the hook does not implement reverts, for the manager too.
    /// @dev `BaseHook` exposes all fourteen entry points whether or not the hook implements them.
    /// The undeclared ones must revert rather than quietly succeed: v4 reads the permissions off
    /// the address and will never call them, so a silent success would only ever be somebody
    /// getting a call through that the pool did not make. None of them may touch the counter.
    function test_undeclaredCallbacksRevertEvenForTheManager() public {
        swap(hookedKey, true, -SWAP_IN, ZERO_BYTES);
        uint256 before = hook.getSwapCount(hookedId);

        ModifyLiquidityParams memory liq = ModifyLiquidityParams(-60, 60, 1e18, bytes32(0));
        SwapParams memory params = SwapParams(true, -SWAP_IN, MIN_PRICE_LIMIT);

        expectHookNotImplemented(abi.encodeCall(IHooks.beforeInitialize, (address(this), hookedKey, SQRT_PRICE_1_1)));
        expectHookNotImplemented(abi.encodeCall(IHooks.afterInitialize, (address(this), hookedKey, SQRT_PRICE_1_1, 0)));
        expectHookNotImplemented(abi.encodeCall(IHooks.beforeAddLiquidity, (address(this), hookedKey, liq, "")));
        expectHookNotImplemented(
            abi.encodeCall(
                IHooks.afterAddLiquidity,
                (address(this), hookedKey, liq, BalanceDeltaLibrary.ZERO_DELTA, BalanceDeltaLibrary.ZERO_DELTA, "")
            )
        );
        expectHookNotImplemented(abi.encodeCall(IHooks.beforeRemoveLiquidity, (address(this), hookedKey, liq, "")));
        expectHookNotImplemented(
            abi.encodeCall(
                IHooks.afterRemoveLiquidity,
                (address(this), hookedKey, liq, BalanceDeltaLibrary.ZERO_DELTA, BalanceDeltaLibrary.ZERO_DELTA, "")
            )
        );
        expectHookNotImplemented(abi.encodeCall(IHooks.beforeSwap, (address(this), hookedKey, params, "")));
        expectHookNotImplemented(abi.encodeCall(IHooks.beforeDonate, (address(this), hookedKey, 1, 1, "")));
        expectHookNotImplemented(abi.encodeCall(IHooks.afterDonate, (address(this), hookedKey, 1, 1, "")));

        assertEq(hook.getSwapCount(hookedId), before, "an unimplemented callback moved the counter");
    }

    /// @dev Calls `data` on the hook as the pool manager and requires `HookNotImplemented`.
    function expectHookNotImplemented(bytes memory data) internal {
        vm.prank(address(manager));
        (bool ok, bytes memory returned) = address(hook).call(data);

        assertFalse(ok, "an undeclared callback did not revert");
        assertEq(bytes32(bytes4(returned)), bytes32(BaseHook.HookNotImplemented.selector), "not HookNotImplemented");
    }

    /*//////////////////////////////////////////////////////////////
                     THINGS THAT MUST NOT BE COUNTED
    //////////////////////////////////////////////////////////////*/

    /// @notice A swap that reverts is not counted.
    /// @dev Three ways to fail — a zero amount, a price limit already behind the pool, and a pool
    /// that was never initialized. The first two never reach the hook because `Pool.swap` rejects
    /// them first; the third never reaches it either. In all three the counter has to be where it
    /// was, which is also what the revert's state rollback gives us: this pins that no earlier
    /// write survives, not just that the call failed.
    function test_revertedSwapsAreNotCounted() public {
        swap(hookedKey, true, -SWAP_IN, ZERO_BYTES);
        uint256 before = hook.getSwapCount(hookedId);

        vm.expectRevert(IPoolManager.SwapAmountCannotBeZero.selector);
        swapRouter.swap(
            hookedKey,
            SwapParams({zeroForOne: true, amountSpecified: 0, sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            settings,
            ZERO_BYTES
        );
        assertEq(hook.getSwapCount(hookedId), before, "a zero-amount swap was counted");

        (uint160 current,,,) = manager.getSlot0(hookedId);
        vm.expectRevert(abi.encodeWithSelector(Pool.PriceLimitAlreadyExceeded.selector, current, current));
        swapRouter.swap(
            hookedKey,
            SwapParams({zeroForOne: true, amountSpecified: -SWAP_IN, sqrtPriceLimitX96: current}),
            settings,
            ZERO_BYTES
        );
        assertEq(hook.getSwapCount(hookedId), before, "a swap rejected on its price limit was counted");

        PoolKey memory neverInitialized = PoolKey({
            currency0: currency0, currency1: currency1, fee: 10_000, tickSpacing: 200, hooks: IHooks(address(hook))
        });
        vm.expectRevert(Pool.PoolNotInitialized.selector);
        swapRouter.swap(
            neverInitialized,
            SwapParams({zeroForOne: true, amountSpecified: -SWAP_IN, sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            settings,
            ZERO_BYTES
        );
        assertEq(hook.getSwapCount(neverInitialized.toId()), 0, "an uninitialized pool was counted");
        assertEq(hook.getSwapCount(hookedId), before);
    }

    /// @notice Everything a pool does that is not a swap leaves the counter alone.
    /// @dev Initializing, adding and removing liquidity and donating all run through the manager
    /// with this hook attached to the key. None of them is a swap.
    function test_onlySwapsAreCounted() public {
        assertEq(hook.getSwapCount(hookedId), 0, "initializing and seeding counted something");

        modifyLiquidityRouter.modifyLiquidity(hookedKey, LIQUIDITY_PARAMS, ZERO_BYTES);
        assertEq(hook.getSwapCount(hookedId), 0, "adding liquidity was counted");

        donateRouter.donate(hookedKey, 100, 100, ZERO_BYTES);
        assertEq(hook.getSwapCount(hookedId), 0, "a donation was counted");

        modifyLiquidityRouter.modifyLiquidity(hookedKey, REMOVE_LIQUIDITY_PARAMS, ZERO_BYTES);
        assertEq(hook.getSwapCount(hookedId), 0, "removing liquidity was counted");

        takeRouter.take(hookedKey, 0, 0);
        assertEq(hook.getSwapCount(hookedId), 0, "a take was counted");

        swap(hookedKey, true, -SWAP_IN, ZERO_BYTES);
        assertEq(hook.getSwapCount(hookedId), 1, "and a swap still counts");
    }

    /*//////////////////////////////////////////////////////////////
                            THE INVARIANT
    //////////////////////////////////////////////////////////////*/

    /// @notice The counter only ever goes up, and only by one at a time.
    /// @dev Mixed traffic — swaps both ways, liquidity in and out, donations, a refused direct
    /// call, blocks passing — with the counter read after every step.
    function test_theCounterIsMonotonicAndMovesOnlyByOne() public {
        uint256 previous = hook.getSwapCount(hookedId);

        for (uint256 i = 0; i < 8; i++) {
            if (i % 3 == 0) {
                modifyLiquidityRouter.modifyLiquidity(hookedKey, LIQUIDITY_PARAMS, ZERO_BYTES);
            }
            if (i % 4 == 0) {
                donateRouter.donate(hookedKey, 10, 10, ZERO_BYTES);
            }

            swap(hookedKey, i % 2 == 0, -SWAP_IN, ZERO_BYTES);

            uint256 current = hook.getSwapCount(hookedId);
            assertEq(current, previous + 1, "a step moved the counter by something other than one");
            previous = current;

            vm.roll(block.number + 1);
            vm.warp(block.timestamp + 12);
            assertEq(hook.getSwapCount(hookedId), previous, "time passing changed the count");
        }

        assertEq(hook.getSwapCount(hookedId), 8);
    }

    /// @notice A saturated counter reverts the swap rather than wrapping to zero.
    /// @dev Unreachable in practice — one swap per increment means `type(uint256).max` is not a
    /// number a pool can reach — so this is here for what it rules out rather than what it
    /// predicts: the `+= 1` is checked, so the failure mode at the top is a revert, not a count
    /// that silently starts again at zero and breaks the monotonicity the contract claims. The
    /// storage is written directly because there is no other way to get there.
    function test_aSaturatedCounterRevertsRatherThanWrapping() public {
        bytes32 slot = keccak256(abi.encode(PoolId.unwrap(hookedId), uint256(0)));
        vm.store(address(hook), slot, bytes32(type(uint256).max));
        assertEq(hook.getSwapCount(hookedId), type(uint256).max, "the slot under test is the counter");

        vm.expectRevert();
        swapRouter.swap(
            hookedKey,
            SwapParams({zeroForOne: true, amountSpecified: -SWAP_IN, sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            settings,
            ZERO_BYTES
        );

        assertEq(hook.getSwapCount(hookedId), type(uint256).max, "the counter wrapped instead of reverting");
    }

    /*//////////////////////////////////////////////////////////////
                       PERMISSIONS AND DEPLOYMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice The hook declares `afterSwap` and nothing else, and its address says the same.
    function test_declaredPermissionsAreAfterSwapAlone() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();

        assertTrue(p.afterSwap, "afterSwap must be on");

        assertFalse(p.beforeInitialize, "beforeInitialize");
        assertFalse(p.afterInitialize, "afterInitialize");
        assertFalse(p.beforeAddLiquidity, "beforeAddLiquidity");
        assertFalse(p.afterAddLiquidity, "afterAddLiquidity");
        assertFalse(p.beforeRemoveLiquidity, "beforeRemoveLiquidity");
        assertFalse(p.afterRemoveLiquidity, "afterRemoveLiquidity");
        assertFalse(p.beforeSwap, "beforeSwap");
        assertFalse(p.beforeDonate, "beforeDonate");
        assertFalse(p.afterDonate, "afterDonate");
        assertFalse(p.beforeSwapReturnDelta, "beforeSwapReturnDelta");
        assertFalse(p.afterSwapReturnDelta, "afterSwapReturnDelta");
        assertFalse(p.afterAddLiquidityReturnDelta, "afterAddLiquidityReturnDelta");
        assertFalse(p.afterRemoveLiquidityReturnDelta, "afterRemoveLiquidityReturnDelta");

        assertEq(HookFlags.flagsOf(address(hook)), EXPECTED_FLAGS, "the address carries other bits");
        assertTrue(HookFlags.matches(address(hook), EXPECTED_FLAGS));
    }

    /// @notice The hook is bound to the manager it was constructed with.
    function test_theHookIsBoundToItsPoolManager() public view {
        assertEq(address(hook.poolManager()), address(manager));
    }

    /// @notice The constructor refuses an address that does not carry exactly the declared bits.
    /// @dev Both directions of "exactly": an address with no permission bits, and one with a bit
    /// the hook never declared. The second is the dangerous one — an address advertising
    /// `beforeSwap` would have the manager call a callback this hook reverts on, taking the pool's
    /// swaps down with it. `BaseHook`'s constructor is what stops that, and this is that check.
    function test_deploymentIsRefusedAtAnAddressWithTheWrongBits() public {
        (address noFlags, bytes32 noFlagsSalt) = findSaltForFlags(0);
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, noFlags));
        new SwapCounterHook{salt: noFlagsSalt}(manager);

        (address extraFlag, bytes32 extraFlagSalt) =
            findSaltForFlags(uint160(Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_FLAG));
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, extraFlag));
        new SwapCounterHook{salt: extraFlagSalt}(manager);

        (address deltaFlag, bytes32 deltaFlagSalt) =
            findSaltForFlags(uint160(Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG));
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, deltaFlag));
        new SwapCounterHook{salt: deltaFlagSalt}(manager);
    }

    /// @notice A pool cannot be opened against an address the hook was not mined for.
    /// @dev The manager validates the hooks field on `initialize`. An address with no permission
    /// bits at all is not a hook, and a pool naming one is rejected before it exists.
    function test_aPoolCannotNameAnAddressWithoutPermissionBits() public {
        PoolKey memory bad = PoolKey({
            currency0: currency0, currency1: currency1, fee: 3000, tickSpacing: 60, hooks: IHooks(address(0x10000))
        });

        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, address(0x10000)));
        manager.initialize(bad, SQRT_PRICE_1_1);
    }

    /// @notice A second hook counts its own pools, and knows nothing of the first hook's.
    /// @dev Two deployments share no storage — worth stating, because the counter is the whole
    /// contract and "the count" is only ever the count held by one deployment.
    function test_asecondDeploymentStartsFromZero() public {
        swap(hookedKey, true, -SWAP_IN, ZERO_BYTES);
        assertEq(hook.getSwapCount(hookedId), 1);

        SwapCounterHook second = deployHookAtMinedAddress(EXPECTED_FLAGS);

        assertEq(second.getSwapCount(hookedId), 0, "a fresh deployment inherited a count");
        assertEq(hook.getSwapCount(hookedId), 1, "and the first one lost nothing");
    }

    /// @notice `afterSwap` stays well inside the gas a swap can afford to give it.
    /// @dev The expensive case: the first swap on a pool, where the counter goes from zero and the
    /// slot is cold. The bound is loose on purpose — this is a guard against a rewrite that turns
    /// an increment into something a swap has to pay real gas for, not a benchmark.
    function test_afterSwapGasIsWithinBudget() public {
        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -SWAP_IN, sqrtPriceLimitX96: MIN_PRICE_LIMIT});

        vm.prank(address(manager));
        uint256 gasBefore = gasleft();
        IHooks(address(hook)).afterSwap(address(this), hookedKey, params, BalanceDeltaLibrary.ZERO_DELTA, ZERO_BYTES);
        uint256 coldCost = gasBefore - gasleft();

        vm.prank(address(manager));
        gasBefore = gasleft();
        IHooks(address(hook)).afterSwap(address(this), hookedKey, params, BalanceDeltaLibrary.ZERO_DELTA, ZERO_BYTES);
        uint256 warmCost = gasBefore - gasleft();

        assertLt(coldCost, 50_000, "a cold increment costs more than a swap should pay");
        assertLt(warmCost, coldCost, "the second write to a warm slot did not cost less");
        assertEq(hook.getSwapCount(hookedId), 2);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Deploys the hook the way it is meant to be deployed: CREATE2 to a mined address.
    function deployHookAtMinedAddress(uint160 flags) internal returns (SwapCounterHook deployed) {
        (address expected, bytes32 salt) = findSaltForFlags(flags);
        deployed = new SwapCounterHook{salt: salt}(manager);
        assertEq(address(deployed), expected, "the mined salt did not reproduce the address");
    }

    /// @dev A salt landing the hook's creation code on an address carrying exactly `flags`.
    /// `HookMiner.find` skips addresses that already hold code, so repeated calls return new ones.
    function findSaltForFlags(uint160 flags) internal view returns (address, bytes32) {
        return HookMiner.find(address(this), flags, type(SwapCounterHook).creationCode, abi.encode(manager));
    }
}
