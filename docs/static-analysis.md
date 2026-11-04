# Static analysis: Slither baseline triage

The first Slither run in CI (`crytic/slither-action@v0.4.1`, Slither 0.11.4,
`main` @ `703b716`, 4 November 2026) raised **71 alerts**. Each is triaged below as
**artifact**, **accepted** (with the reason), or **fix**. Nothing in `src/` changed as a
result. The one fix is a deploy-time recommendation, and the real problem this turned up
is with the analyser, not the contracts.

## The baseline is not trustworthy yet

Slither's model of `AgentRegistry`, `AgentVault`, `HLAgentVault` and
`HLAgentVaultFactory` is **missing parts of their function bodies**: state writes and
internal calls in particular.

- It reports `immutable` variables as "never initialized". Examples:
  `HLAgentVault.platformTreasury` (assigned at `HLAgentVault.sol:219`),
  `HLAgentVaultFactory.implementation`, and `AgentVault.registry`. An immutable that is
  never assigned does not compile, so Slither lost those constructors' assignments.
- It reports `SZ_PX_TO_USDC` as never used, yet `placeOrder` uses it at
  `HLAgentVault.sol:363`. It reports `_requireWithinPositionCap` and
  `_requireWithinDrawdown` as dead code, yet `placeOrder` calls both (`:361`, `:383`).
  So **its model of `placeOrder`, the function the security plan cares about most,
  lacks the limit checks.**
- The loss is partial, not whole functions. It lists `withdrawBond` and `slashBond` as
  readers of `_builders`, yet calls `_tierFor` dead, which both of them call. It does
  model `cancelAll` → `_release`, and the whitelists' constructor writes (it proposes
  making their `governance` immutable).

**Cause (found by this PR's diagnostic step):** Slither logs
`ERROR:ContractSolcParsing:Impossible to generate IR for …: 'NoneType' object has no
attribute 'parameters'` for **56 functions**. They include every constructor of the four
contracts, `placeOrder`, `reconcile`, `requestWithdraw`, `finalizeWithdraw`,
`initialize` and the access modifiers.

- It's a name collision. Our `library Errors` (`src/libraries/Errors.sol`) and
  OpenZeppelin 5.1's `library Errors` (`utils/Errors.sol`, reached through
  `SafeERC20` → `Address`) share a name.
- Slither resolves `Errors.ZeroAddress()` and the rest against OpenZeppelin's library,
  doesn't find the error, and drops the function's IR.
- The split is exact. The four contracts that import OpenZeppelin lose 18, 17, 19 and 2
  functions. `HLMarketWhitelist` and `VenueWhitelist` use the same `Errors` and import no
  OpenZeppelin, and they lose none.
- Aderyn flags the same thing independently: H-2, "Contract Name Reused in Different
  Files", on `src/libraries/Errors.sol`.

**Fix (needs Udoka's OK, as a `src/` change):** rename our library, for example to
`CircleErrors`, in `src/libraries/Errors.sol` and its six importers.
- A custom error's selector is `keccak256("ZeroAddress()")` and doesn't include the
  library name, so the ABI, revert data and tests are unaffected.
- The bytecode differs only in the metadata hash. That still means the testnet
  deployment's verified source no longer matches, so do it with the next deploy or
  accept the mismatch.

Until it is fixed, **a clean Slither result says nothing about the order path**. That's
why the job stays report-only.
`script/slither-coverage.py` detects the contradictions above in the SARIF and warns in
CI. When it reports none, set `fail-on: medium`. The diagnostic step in `ci.yml` prints
Slither's `function-summary` for the two main contracts, which shows what each function
reads, writes and calls in Slither's model.

**Before any audit freeze:** get a Slither run with zero coverage contradictions, then
triage that run's findings again. The verdicts below cover only what Slither could see.

## Triage

| Rule | Count | Where | Verdict |
|---|---|---|---|
| `uninitialized-state` (high) | 24 | `AgentRegistry` 9, `HLAgentVault` 9, `AgentVault` 4, `HLAgentVaultFactory` 2 | **Artifact.** Every one is assigned in a constructor or a setter Slither didn't model (`AgentRegistry.sol:87-92`, `:334`, `:352`, `:375`, `:399`; `HLAgentVault.sol:203-235` and `initialize`). The mappings (`_builders`, `_listings`) are written through storage pointers, a known Slither false positive. |
| `constable-states` | 17 | `AgentRegistry` 5, `HLAgentVault` 12 | **Artifact**, from the same missing writes. None of these variables can be constant: they're per-deploy or per-clone values. |
| `dead-code` | 14 | internal helpers in all three vaults and the registry | **Artifact.** Each one is called from a function Slither dropped. For example, `_requireWithinPositionCap` and `_requireWithinDrawdown` are called from `placeOrder`, and `_tierFor` from `stakeBond`. |
| `unused-state` | 2 | `HLAgentVault.SZ_PX_TO_USDC`, `BRIDGE_GRACE` | **Artifact.** Used at `HLAgentVault.sol:363` and `:307`. |
| `immutable-states` | 2 | `VenueWhitelist.governance`, `HLMarketWhitelist.governance` | **Fix at the next deploy (recommendation).** Correct: governance is assigned only in the constructor and no setter exists. Making it `immutable` changes no behaviour and saves a cold SLOAD on every `onlyGovernance` call. Left unchanged here because `HLMarketWhitelist` is deployed on testnet and the change belongs with the next deploy, not in a triage PR. |
| `reentrancy-no-eth` (medium), `reentrancy-events` | 1 + 1 | `HLAgentVault.cancelAll` (`:416-425`) | **Accepted.** The external call is `CoreWriterLib.cancelOrderByCloid`, which calls the CoreWriter system contract at `0x3333…3333`. That contract enqueues an action and has no callback into the vault, so there is no re-entry path. Within each iteration the vault already releases before it calls. The state Slither flags is the next iteration's release, which runs after the previous iteration's call. `cancelAll` is also `onlyTraderOrAgent`. |
| `timestamp` | 3 | `HLMarketWhitelist.executeAddition`, `VenueWhitelist.executeAddition`, `AgentVault.isOrderAuthorised` | **Accepted.** The timelock (2 days) and the order expiry are deliberately time-based. Validator timestamp drift is seconds, against windows of hours to days. |
| `calls-loop` | 2 | `AgentVault._totalValue` (`:650-656`) | **Accepted for now, revisit with Polygon clones (Phase 6).** It calls each whitelisted adapter's `positionValue`, and a reverting adapter would block `totalValue` and order authorisation. Adapters are added only through the timelocked whitelist. This is the deferred Polygon `AgentVault`, not the Hyperliquid launch path. |
| `costly-loop` | 3 | `HLAgentVault._release` via `cancelAll` | **Accepted.** The loop is bounded by `MAX_OPEN_ORDERS` (8), and `cancelAll` stays one transaction by design. |
| `low-level-calls` | 1 | `AgentRegistry._isAuthorisedVault` (`:363-370`) | **Accepted.** A deliberate `staticcall` with a decoded bool, so a `vaultFactory` that isn't a factory fails closed rather than reverting a trader's deposit. It checks `ok`, the return length and the decoded value. |
| `cyclomatic-complexity` | 1 | `AgentVault.authoriseOrder` (13) | **Accepted.** It's a flat sequence of independent limit checks, each a single `if … revert`. Splitting it would scatter the order-time checks the audit needs to read in one place. Deferred Polygon path. |

**Total: 71.** 57 artifacts, 12 accepted, and 2 recommended for the next deploy.

## Aderyn

Aderyn 0.6.8, in the `aderyn` job, ran 88 detectors over the 11 files in `src/` (1,495
nSLOC). It found 2 high and 12 low. The report is kept as the `aderyn-report` build
artifact.

| Finding | Count | Verdict |
|---|---|---|
| H-1 Reentrancy: state change after external call | 23 (15 `AgentVault`, 8 `HLAgentVault`) | **Accepted.** The external calls go to the protocol's own `registry` and `whitelist` (immutables set at construction), to USDC, to HyperCore read precompiles (`staticcall`) and to CoreWriter, which enqueues and never calls back. The flagged entry points are `nonReentrant` (`placeOrder`, `deposit`, `finalizeWithdraw`, `assessFees`) or `initializer`, except `enableFastMode`. That one is only `onlyTrader`, but its external calls are a `view` read of the registry and three CoreWriter actions, none of which can call back. The 15 `AgentVault` hits are the deferred Polygon vault; its adapters are timelocked, and its `execute` path checks balances before and after. Re-check both when Polygon clones return. |
| H-2 Contract name reused in different files | 1 (`Errors`) | **Fix: the Slither root cause above.** Rename the library. |
| L-8 State variable could be immutable | 5 | **Fix at the next deploy, as recommended above.** `governance` in both whitelists and in `AgentRegistry` is assigned only in the constructor (the registry has no governance setter, by design). `tierBonds` and `tierCeilings` can't be immutable because Solidity doesn't allow immutable arrays. |
| L-7 State change without event | 1 (`AgentRegistry.notifyAumDelta`) | **Fix, low.** An `AumChanged(listingId, builder, totalAum)` event would let the indexer follow AUM against the ceiling without re-reading storage. |
| L-10 Unchecked return | 1 (`AgentVault.sol:559`, `IVenueAdapter.exit`) | **Accepted for now.** It's the deferred Polygon path. The vault values positions through `positionValue`, not through `exit`'s return. Revisit with Polygon clones. |
| L-9 TODO comment | 1 (`AgentVault.sol:620`, Streamflow streaming) | **Accepted.** It's a recorded design note on the deferred Polygon vault. The handbook dropped streaming for lump-sum payouts. |
| L-1 Costly operations in loop | 5 | **Accepted.** Same as Slither's: bounded by `MAX_OPEN_ORDERS` (8) or by the 3 tiers. |
| L-6 Loop contains `require`/`revert` | 5 | **Accepted.** These are bounded loops over caller-supplied cloids or adapters, and a revert is the intended response to a bad entry. |
| L-11 Uninitialized local variable | 9 | **Accepted.** These are all `for (uint256 i; …)` loop counters, which start at zero. |
| L-2, L-3 Large literal, literal instead of constant | 1 + 4 | **Accepted.** Unit and scale literals with their meaning in a comment beside them. No behavioural effect. |
| L-4 Modifier invoked only once | 2 | **Accepted.** These are access modifiers kept as modifiers so the access rule reads at the function signature. |
| L-5 `nonReentrant` not the first modifier | 1 (`AgentRegistry.slashBond`) | **Accepted.** The modifiers before it are access checks with no external calls. |
| L-12 Public function not used internally | 1 (`AgentVault.isOrderAuthorised`) | **Accepted.** It's a view that venue adapters call. `external` would be marginally cheaper; change it with Polygon clones. |
