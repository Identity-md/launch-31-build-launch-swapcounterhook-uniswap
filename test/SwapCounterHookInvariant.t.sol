// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolDonateTest} from "v4-core/src/test/PoolDonateTest.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";

import {SwapCounterHook} from "../src/SwapCounterHook.sol";

/// @notice Drives two hooked pools with whatever the fuzzer picks, and keeps its own count.
/// @dev Every action goes through the same routers a trader would use, and only a swap that the
/// manager accepted increments the shadow count. Actions that revert — a swap that runs out of
/// room, a donation to an empty range, a hand-made `afterSwap` — are swallowed, because the
/// interesting question is what the counter reads afterwards, not whether the fuzzer guessed a
/// valid input. `SWAP_LIMIT` keeps the price inside the seeded range, so most swaps do land.
contract SwapCounterHandler is Test {
    IPoolManager public immutable manager;
    SwapCounterHook public immutable hook;
    PoolSwapTest public immutable swapRouter;
    PoolModifyLiquidityTest public immutable liquidityRouter;
    PoolDonateTest public immutable donateRouter;

    PoolKey[2] public keys;

    /// @notice The count this handler believes each pool is owed.
    uint256[2] public expected;

    /// @notice Calls made that must never be counted, for the log at the end of a run.
    uint256 public rejectedSwaps;
    uint256 public nonSwapActions;
    uint256 public refusedDirectCalls;

    /// @notice The last count read for each pool, and how often one of them went backwards.
    /// @dev Read after every action rather than only when the invariant runs, so a count that
    /// dipped and recovered inside one sequence still shows up here.
    uint256[2] public lastSeen;
    uint256 public backwardSteps;

    modifier tracksProgress() {
        _;
        for (uint256 i = 0; i < 2; i++) {
            uint256 current = hook.getSwapCount(keys[i].toId());
            if (current < lastSeen[i]) backwardSteps++;
            lastSeen[i] = current;
        }
    }

    constructor(
        IPoolManager _manager,
        SwapCounterHook _hook,
        PoolSwapTest _swapRouter,
        PoolModifyLiquidityTest _liquidityRouter,
        PoolDonateTest _donateRouter,
        PoolKey memory keyA,
        PoolKey memory keyB
    ) {
        manager = _manager;
        hook = _hook;
        swapRouter = _swapRouter;
        liquidityRouter = _liquidityRouter;
        donateRouter = _donateRouter;
        keys[0] = keyA;
        keys[1] = keyB;

        for (uint256 i = 0; i < 2; i++) {
            approveAll(keys[i].currency0);
            approveAll(keys[i].currency1);
        }
    }

    function approveAll(Currency currency) internal {
        IERC20Minimal token = IERC20Minimal(Currency.unwrap(currency));
        token.approve(address(swapRouter), type(uint256).max);
        token.approve(address(liquidityRouter), type(uint256).max);
        token.approve(address(donateRouter), type(uint256).max);
    }

    function key(uint256 seed) internal view returns (uint256 index, PoolKey memory) {
        index = seed % 2;
        return (index, keys[index]);
    }

    /// @notice One swap. Counted by the handler only if the manager accepted it.
    function swapExactIn(uint256 poolSeed, uint256 amountSeed, bool zeroForOne) public tracksProgress {
        (uint256 index, PoolKey memory k) = key(poolSeed);
        int256 amount = int256(_bound(amountSeed, 1, 1e14));

        try swapRouter.swap(
            k,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -amount,
                sqrtPriceLimitX96: zeroForOne ? SWAP_LIMIT_DOWN : SWAP_LIMIT_UP
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        ) {
            expected[index] += 1;
        } catch {
            rejectedSwaps++;
        }
    }

    /// @notice A swap the manager will refuse: zero size. Never counted.
    function swapZeroAmount(uint256 poolSeed, bool zeroForOne) public tracksProgress {
        (, PoolKey memory k) = key(poolSeed);

        try swapRouter.swap(
            k,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: 0,
                sqrtPriceLimitX96: zeroForOne ? SWAP_LIMIT_DOWN : SWAP_LIMIT_UP
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        ) {
            revert("a zero-amount swap was accepted");
        } catch {
            rejectedSwaps++;
        }
    }

    function addLiquidity(uint256 poolSeed, uint256 amountSeed) public tracksProgress {
        (, PoolKey memory k) = key(poolSeed);
        int256 delta = int256(_bound(amountSeed, 1e12, 1e18));

        try liquidityRouter.modifyLiquidity(k, ModifyLiquidityParams(-120, 120, delta, bytes32(0)), "") {
            nonSwapActions++;
        } catch {}
    }

    function removeLiquidity(uint256 poolSeed, uint256 amountSeed) public tracksProgress {
        (, PoolKey memory k) = key(poolSeed);
        int256 delta = int256(_bound(amountSeed, 1e12, 1e17));

        try liquidityRouter.modifyLiquidity(k, ModifyLiquidityParams(-120, 120, -delta, bytes32(0)), "") {
            nonSwapActions++;
        } catch {}
    }

    function donate(uint256 poolSeed, uint256 amountSeed) public tracksProgress {
        (, PoolKey memory k) = key(poolSeed);
        uint256 amount = _bound(amountSeed, 1, 1e12);

        try donateRouter.donate(k, amount, amount, "") {
            nonSwapActions++;
        } catch {}
    }

    /// @notice Somebody calls `afterSwap` on the hook directly. It must be refused.
    function forgeAnAfterSwap(uint256 poolSeed, address caller, int128 delta) public tracksProgress {
        (, PoolKey memory k) = key(poolSeed);

        vm.prank(caller);
        try IHooks(address(hook))
            .afterSwap(
                caller,
                k,
                SwapParams({zeroForOne: true, amountSpecified: -1e12, sqrtPriceLimitX96: SWAP_LIMIT_DOWN}),
                BalanceDelta.wrap(int256(delta)),
                ""
            ) {
            // Only the manager can get here, and the fuzzer is not it.
            require(caller == address(manager), "afterSwap accepted a caller that was not the manager");
            expected[poolSeed % 2] += 1;
        } catch {
            refusedDirectCalls++;
        }
    }

    /// @dev Well inside the ±120 tick range the pools are seeded over.
    uint160 constant SWAP_LIMIT_DOWN = 79_000_000_000_000_000_000_000_000_000;
    uint160 constant SWAP_LIMIT_UP = 79_500_000_000_000_000_000_000_000_000;
}

/// @notice The counter's invariant under arbitrary traffic.
/// @dev The unit tests say what one swap does. This says what any sequence of swaps, liquidity
/// changes, donations, refused calls and rejected swaps does: the count is the number of swaps the
/// manager accepted on that pool, it never goes down, and one pool's traffic never shows up in the
/// other's total.
contract SwapCounterHookInvariantTest is Deployers {
    SwapCounterHook internal hook;
    SwapCounterHandler internal handler;

    PoolId internal idA;
    PoolId internal idB;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        (address expectedAddress, bytes32 salt) = HookMiner.find(
            address(this), uint160(Hooks.AFTER_SWAP_FLAG), type(SwapCounterHook).creationCode, abi.encode(manager)
        );
        hook = new SwapCounterHook{salt: salt}(manager);
        require(address(hook) == expectedAddress, "mined salt did not reproduce the address");

        PoolKey memory keyA;
        PoolKey memory keyB;
        (keyA, idA) = initPoolAndAddLiquidity(currency0, currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);
        (keyB, idB) = initPoolAndAddLiquidity(currency0, currency1, IHooks(address(hook)), 500, SQRT_PRICE_1_1);

        handler = new SwapCounterHandler(manager, hook, swapRouter, modifyLiquidityRouter, donateRouter, keyA, keyB);

        IERC20Minimal(Currency.unwrap(currency0)).transfer(address(handler), 1e24);
        IERC20Minimal(Currency.unwrap(currency1)).transfer(address(handler), 1e24);

        targetContract(address(handler));
    }

    /// @notice The hook's count is the number of swaps the handler got through, pool by pool.
    /// forge-config: default.invariant.runs = 12
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail_on_revert = true
    function invariant_countMatchesTheSwapsThatHappened() public view {
        assertEq(hook.getSwapCount(idA), handler.expected(0), "pool A");
        assertEq(hook.getSwapCount(idB), handler.expected(1), "pool B");
    }

    /// @notice The count never goes down.
    /// forge-config: default.invariant.runs = 12
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail_on_revert = true
    function invariant_theCountNeverDecreases() public view {
        assertEq(handler.backwardSteps(), 0, "a count went backwards during the sequence");
        assertGe(hook.getSwapCount(idA), handler.lastSeen(0), "pool A");
        assertGe(hook.getSwapCount(idB), handler.lastSeen(1), "pool B");
    }

    /// @notice Whatever happened, the hook still holds nothing.
    /// forge-config: default.invariant.runs = 12
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail_on_revert = true
    function invariant_theHookHoldsNothing() public view {
        assertEq(IERC20Minimal(Currency.unwrap(currency0)).balanceOf(address(hook)), 0);
        assertEq(IERC20Minimal(Currency.unwrap(currency1)).balanceOf(address(hook)), 0);
        assertEq(address(hook).balance, 0);
    }
}
