# SIMDTEST launch

`SIMDTEST` is an immutable, 18-decimal ERC-20. Its constructor takes no arguments
and mints **1,000,000,000 tokens (1e27 units)** to its deployer. The launch factory
seeds liquidity, distributes the swarm's 10% through its Merkle distributor, and
sends the remainder to `remainderTo`. Neither delivered contract distributes a
swarm allocation. There is no subsequent mint, token tax, owner, pause, proxy,
upgrade, rescue function, or configurable recipient.

`SIMDTESTHook` charges 1% of each swap's **actual unspecified-currency delta**,
in addition to the pool's static 1.25% LP fee. It holds fees for permissionless
token sweeps and hourly bounded IMD buybacks. `launch.json` names the hook itself.

## Deployment parameters

| Parameter | Value |
| --- | --- |
| Network | Ethereum mainnet, chain ID 1 |
| PoolManager constructor argument | `0x000000000004444c5dc75cB358380D2e3dE08A90` |
| Launch token constructor argument | Factory-resolved `$token`, deployed before the hook |
| IMD paired currency, fixed in hook | `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7` (18 decimals) |
| Burn destination, fixed in hook | `0x000000000000000000000000000000000000dEaD` |
| Static LP fee / tick spacing | `12500` / `60` |
| Hook fee | `100` bps, rounded down to whole minor units |
| Batch interval / maximum budget | `3600` seconds / floor(accrued IMD / 4) |
| Batch price tolerance | `300` bps in pool price |
| Required address mask | `address(hook) & 0x3fff == 0x20c4` |

Constructor: `SIMDTESTHook(IPoolManager manager, address token)`. The manifest
passes `["$poolManager", "$token"]`. Both contracts must already have code;
the token must differ from IMD. No setting remains for an owner after launch.

The hook accepts exactly its immutable sorted token/IMD pool with the specified
static fee and tick spacing. Initialization is permissionless through the
PoolManager and allowed only once. The factory must deploy and initialize
atomically at its economically chosen opening price. The manifest's
`79228162514264337593543950336` is provenance, not a price enforced by the hook.

Mine CREATE2 using the **actual factory that performs CREATE2**, its salt
convention, final bytecode, actual manager, and the factory's predicted token
address. `script/MineHook.s.sol:MineHook.run(factory, manager, token, start)` is a
read-only, bounded salt finder returning `(predicted, salt)`. Its implementation
is tested directly by every integration fixture. If its 200,000-candidate range
is exhausted, continue with the next range. No deployment, wallet, RPC secret,
environment variable, or broadcast is embedded in the script. Changing the
constructor arguments or build changes the address and requires mining again.

Deploy the hook directly with the mined salt; verify its address and
`getHookPermissions()` before initializing. The constructor also checks all 14
permission bits. Enabled callbacks are `beforeInitialize`, `beforeSwap`,
`afterSwap`, and `afterSwapReturnDelta`. No specified-side return permission is
enabled. This follows the address model in the
[Uniswap hook documentation](https://developers.uniswap.org/docs/protocols/v4/concepts/hooks).

## Fee accounting

| Trade | Specified currency | Currency charged by this hook |
| --- | --- | --- |
| Buy, exact input | IMD input | SIMDTEST output |
| Sell, exact input | SIMDTEST input | IMD output |
| Buy, exact output | SIMDTEST output | IMD input |
| Sell, exact output | IMD output | SIMDTEST input |

`beforeSwap` reserves nothing and returns zero for the LP override. It only
rejects specified magnitudes for which adding 1% would exceed `int256.max`,
using `UnrepresentableFee`. Otherwise the actual PoolManager delta in
`afterSwap` determines the fee: `floor(abs(unspecifiedDelta) / 100)`. Positive
after-swap return deltas deduct the fee from output for exact input trades,
or add it to input owed for exact output trades. Partial and zero fills are
charged on what filled; there is no specified-side reservation to refund.
Normal PoolManager input, liquidity, settlement and price-limit validations
still apply. User routers must understand these additional return deltas.

Fees accrue as **ERC-6909 claims owned by the hook** at the PoolManager. This
means the hook holds the right to the underlying currency; the underlying
ERC-20 reserves remain in the manager until redemption. This choice avoids
any ERC-20 transfer or balance dependency inside a swap callback, including
the first exact-output buy from a fresh manager with only launched tokens.
The manager credits the hook's returned delta and the mint debits it by the
same amount. A successful outer unlock must settle every delta.

`pending()` returns hook-owned IMD claims plus direct IMD donations.
`pendingBurn()` returns hook-owned SIMDTEST claims plus direct SIMDTEST donations.
No external account has authority to spend the hook's claims. Donations of
these currencies follow the same rules as accrued fees; unrelated tokens
cannot be rescued. No fee is converted or spent inside a swap callback.

`sweep()` is callable by anyone, outside an active PoolManager unlock. It
redeems all token claims, immediately takes the underlying to the dead address,
and sends any directly held SIMDTEST there too. It is safe to call with nothing
pending. Dead-address burns leave ERC-20 `totalSupply()` unchanged and increase
the dead address's inaccessible balance.

## Batches and reference price

Anyone can call `executeBatch()` in a separate PoolManager unlock. The first
call must wait one hour from pool initialization; subsequent calls must wait
one hour from the previous eligible attempt. Nested calls from a swap or another
manager unlock are refused. A keeper should submit these as separate transactions.
No rewards or automation service are built in.

The reference definition, where the brief leaves its window unspecified, is an
**epoch geometric TWAP**: time-weighted mean pool tick since initialization or
the previous eligible batch attempt. All epochs used for a batch last at least
3600 seconds. Every external swap adds `previousTick * elapsedSeconds` before
recording its new tick. `referencePrice()` also includes idle time at the last
tick and returns `TickMath.getSqrtPriceAtTick(floor(meanTick))` in Q64.96. At the
start of an epoch it returns that epoch's opening tick price. A swap at the same
timestamp has zero historical weight. If keepers are absent, the epoch is longer
than one hour; this is not a rolling one-hour oracle.

For an IMD-to-SIMDTEST batch:

1. Snapshot the reference and a budget of at most one quarter of pending IMD.
   Very large donations are additionally capped at `int128.max` per batch to
   respect the manager's delta representation.
2. Set the square-root price limit to reference times `sqrt(0.97)` when IMD is
   currency0, or reference times `sqrt(1.03)` when IMD is currency1. Integer
   rounding tightens the limit; global TickMath boundaries are respected. The
   tolerance is in `currency1/currency0` price, not a 3% change in sqrt price or
   an all-in execution quote including LP fees.
3. If spot is already at or beyond that limit, spend zero. Otherwise unlock and
   perform an exact-input swap with the hook itself as sender. Core suppresses
   self-swap callbacks, so the batch pays the static LP fee but no hook fee.
4. Settle only actual IMD spent, burning the hook's IMD claims first and paying
   from direct IMD donations only when needed. Send bought tokens directly from
   PoolManager to the dead address. Unfilled budget stays pending.
5. Record the post-batch tick and start a new epoch. Zero-budget, zero-liquidity
   and out-of-limit attempts also start a new epoch and consume the hourly slot.
   This lets the reference adapt instead of repeatedly reverting at an obsolete
   price. There is no minimum-output condition or hardcoded LP-fee output estimate.

`lastBatch()` starts at the initialization timestamp. `BatchExecuted` records
budget, actual spend, amount burned, the reference used, and its price limit;
`FeeAccrued` and `Swept` record fees and sweeps. After a batch, `referencePrice()`
is the new epoch reference; use the event to inspect the reference just used.

## Build and checks

All Solidity dependencies needed for compilation and tests are ordinary vendored
files in `lib/`, with exact revisions in `dependencies.json` and upstream licenses
beside them. Unused upstream contracts were omitted. There are no submodules or
package-install steps. Foundry and the pinned Solidity 0.8.26 compiler are the
only external build prerequisites. Cancun, optimization at 200 runs, and
`bytecode_hash = "none"` are pinned in `foundry.toml`.

```sh
forge build
forge test
forge fmt --check
```

Local tests use the **actual vendored Uniswap v4 PoolManager**, deployed locally,
with a standard IMD ERC-20 fixture at the specified address. They exercise actual
unlock, liquidity, swap, claims, and settlement paths; the manager is not mocked.
Tests deploy both currency orderings through real CREATE2, check all four trade
forms against pre-hook manager swap events, and fuzz partial fills. Other cases
cover token supply and transfers, callback authorization, unsupported pools,
overflow-domain rejection, cooldown boundaries, idle and manipulated prices,
partial/zero batch fills, fee-free self-swaps, burn accounting, fresh token-only
liquidity, code limits and forbidden opcodes. The stateful conservation invariant
interleaves trades, time advances, batches and sweeps with failure on reverts.

The mainnet suite uses the same scenarios against the **deployed mainnet manager
and actual IMD code**. Test balances are funded with a Foundry balance cheatcode;
no fork contract code is substituted. Supply an archival mainnet RPC and a block
at or after IMD deployment:

```sh
forge test --match-contract MainnetForkTest --fork-url <archive-mainnet-RPC> --fork-block-number <block>
```

Without a fork, the suite reports a skip through `vm.activeFork()`; it reads no
environment variables and makes no implicit network request. Public RPC attempts
in this assignment returned HTTP 403, so **a successful mainnet fork rehearsal
remains outstanding**. The default offline suite passes independently of it.

## Operational assumptions and review

Mainnet addresses are taken from the assignment. Confirm mainnet manager and IMD
code, IMD transfer behavior and 18 decimals on the intended fork before release.
IMD is assumed to be a standard, non-rebasing ERC-20 without transfer taxes or
restrictions that block required transfers. Claims isolate fee collection from
hook transfers; they do not remove the pool's dependency on IMD settlement or
make a failing underlying token redeemable. A failing sweep or batch rolls back
atomically and can be retried; it is outside the swap callback.

Keepers monitor `pending`, `pendingBurn`, `lastBatch`, and the events, call sweep,
and submit hourly batch attempts. There is no privileged keeper, adjustable
slippage, owner payout, post-launch setup, or way to withdraw accrued IMD for
another purpose. The factory supplies the pool's initial economics, deployment,
liquidity and supply distribution.

The epoch TWAP removes same-timestamp spot manipulation from the reference but
does not prevent sustained manipulation of a thin pool. The fixed price band
and 25% budget bound execution, not economic loss relative to an external market.
Tick rounding introduces less than one tick of reference precision loss. Delayed
keepers mean a longer and potentially stale first reference; an out-of-limit
attempt advances the epoch without spending. Review liquidity and keeper behavior
as part of launch economics.

Local review covered callback and unlock authorization, self-swap exemption,
claim/delta conservation, partial-fill settlement, immutability, oracle sampling,
price-limit rounding, and deployment bits. The launch token and hook runtime
contain no SELFDESTRUCT, DELEGATECALL or CALLCODE. Hook creation code with its two
constructor arguments is below EIP-3860, and runtime is below EIP-170. No
independent security audit, Slither/Mythril run, deployment or live transaction
was performed. Independent adversarial review and the fork rehearsal remain
release responsibilities.
