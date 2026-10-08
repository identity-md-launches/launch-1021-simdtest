# SIMD-LAUNCH test coverage

The existing launch tests remain in place. The additional coverage exercises:

- Rejected deployment addresses and permission bits, invalid pool keys before the first initialization, and recovery after a premature batch call.
- The exact positive and negative `UnrepresentableFee` boundary, huge price-limited swap requests, and dust rounding in all four buy/sell and exact-input/output combinations.
- Atomic rollback when router settlement, direct token sweeping, or mixed claim/direct IMD batch settlement fails. Each failure is followed by a successful retry.
- Permissionless burning of donated ERC-6909 claims, refusal of unauthorized claim transfers, and refusal of both keeper functions inside another manager unlock.
- Batch settlement using both claims and direct IMD, partial fills funded entirely by claims, and reuse of unspent claims after the cooldown. Squared pool prices independently check the 300 bps limit.
- Empty and dust batch attempts preserve the hourly slot, TWAP epoch, and reference. The handler distinguishes these attempts from batches that spend IMD. A deterministic replay builds nonzero price history, retries after funding in the same timestamp, and checks conservation and the filled batch's cooldown in both currency orderings.

`SwapEvidence` reads the real PoolManager's pre-hook `Swap` event. The handler computes expected fees from that receipt rather than from the hook's fee event or balance changes. It mixes ordinary trades, price-limited trades, direct and fully backed claim donations, time advances, batches, and sweeps. For each currency ordering it runs 256 sequences of 64 calls with unexpected reverts treated as failures. Assertions cover fee conservation, claim backing, the entire fixed token supply, IMD conservation, batch budget/cooldown, dead-address receipts, and settled manager deltas.

The offline fixture deploys the vendored PoolManager and the actual SIMDTEST token, mines a real CREATE2 hook address, and places a test ERC-20 at IMD's specified address. The fork fixture instead uses the deployed mainnet PoolManager and IMD implementation, funding only the test actor. Both currency orderings run the shared scenarios.

## Run locally

No new dependencies or configuration changes are required. To keep generated files under the disposable test directory:

```sh
FOUNDRY_OUT=test/scratch/out FOUNDRY_CACHE_PATH=test/scratch/cache forge build
FOUNDRY_OUT=test/scratch/out FOUNDRY_CACHE_PATH=test/scratch/cache forge test --summary
```

Without an active fork, the two fork suites explicitly skip in `setUp`. The rest of the suite needs no network. Fork execution is opt-in through the CLI and never uses `vm.setEnv`.

The mainnet rehearsal was run at block **26,146,258**:

```sh
FOUNDRY_OUT=test/scratch/out FOUNDRY_CACHE_PATH=test/scratch/cache \
  forge test --match-contract 'MainnetFork.*Test' \
  --fork-url https://ethereum-rpc.publicnode.com \
  --fork-block-number 26146258 --no-storage-caching --summary
```

Revision validation: `forge build` succeeded; the offline suite passed 102 tests with two explicit fork setup skips; the fork run passed 56 tests without skips at the block above. Each fuzz property ran 1,000 cases. Both invariant suites completed 16,384 calls without unexpected reverts. The baseline's four failures came from stale assertions that empty attempts advance the cooldown; the assertions now preserve the revised hook's empty-attempt behavior and still enforce the cooldown after spending. No new implementation defect was identified during this revision.
