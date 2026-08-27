# Uniswap v4 hook — Foundry project

The build for a Uniswap v4 hook. The hook itself is not written yet: `src/` currently holds a
placeholder, and this repository exists so that whoever writes the hook opens a project that
already compiles, tests, and resolves every import.

## Running it

```sh
forge build
forge test
```

Nothing else is needed, and nothing is downloaded. Every dependency is committed under `lib/` as
ordinary files, so both commands work on a clean checkout with no network.

## Layout

```
foundry.toml     compiler settings and import remappings
src/             the hook (today: Placeholder.sol, which does nothing but hold a pool manager)
test/            Foundry tests (today: Placeholder.t.sol, a smoke test of the toolchain)
lib/             vendored dependencies
```

`test/Placeholder.t.sol` deploys a real `PoolManager` and mines a hook address with `HookMiner`.
That exercises v4-core and v4-periphery respectively, so a failure there is a failure of this
setup rather than of any hook logic layered on top.

## Toolchain

| Setting        | Value    | Why                                                                                                                     |
| -------------- | -------- | ----------------------------------------------------------------------------------------------------------------------- |
| `solc`         | `0.8.26` | The pinned version the vendored Uniswap v4 sources are written for.                                                     |
| `evm_version`  | `cancun` | v4-core uses transient storage (`TSTORE`/`TLOAD`).                                                                      |
| `bytecode_hash`| `none`   | Drops the metadata hash so creation code is reproducible — a hook's address is CREATE2-mined from it, so it must not move. |

A v4 hook advertises its permissions in the low 14 bits of its own address, so it is deployed to a
mined address. Keeping the compiler and its output byte-identical across machines is what makes a
mined salt still valid on someone else's checkout.

## Dependencies

Vendored, not fetched — there are no submodules and no lockfile pointing at anything remote.
Each was copied from upstream at the commit below and trimmed to the Solidity it is used for;
audit PDFs, upstream test suites, JS tooling and CI config were dropped, and licences kept.

| Path                         | Upstream                              | Commit    |
| ---------------------------- | ------------------------------------- | --------- |
| `lib/forge-std`              | `foundry-rs/forge-std`                | `1de6eec` |
| `lib/v4-core`                | `Uniswap/v4-core` (v1.0.2)            | `59d3ecf` |
| `lib/v4-periphery`           | `Uniswap/v4-periphery`                | `3779387` |
| `lib/solmate`                | `transmissions11/solmate`             | `4b47a19` |
| `lib/openzeppelin-contracts` | `OpenZeppelin/openzeppelin-contracts` | `dbb6104` |
| `lib/permit2`                | `Uniswap/permit2`                     | `cc56ad0` |

v4-core is the commit v4-periphery pins, so the two agree. v4-periphery is pinned at the last
commit that still ships `src/utils/BaseHook.sol` and `src/utils/HookMiner.sol`; upstream removed
both shortly afterwards, and a hook is written against them. solmate, OpenZeppelin and permit2 are
transitive dependencies of those two — hoisted to the top level so there is exactly one copy of
each.

`lib/v4-core/test/utils/` is kept alongside `lib/v4-core/src/`: it holds `Deployers.sol`, the
harness hook tests use to stand a pool up.

## Imports

Both spellings of the Uniswap prefixes resolve to the same directory, because the v4 libraries
import each other one way and hooks are conventionally written the other:

```solidity
import {Hooks} from "v4-core/src/libraries/Hooks.sol";            // == @uniswap/v4-core/...
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";     // == @uniswap/v4-periphery/...
import {Test} from "forge-std/Test.sol";
```

The full set of remappings is in `foundry.toml`.
