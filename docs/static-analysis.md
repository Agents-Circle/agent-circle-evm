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

The cause isn't identified yet. Slither couldn't be run locally for this triage, and
the CI log shows no parse error. Until it is fixed, **a clean Slither result says nothing
about the order path**. That's why the job stays report-only.
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

The `aderyn` job in `ci.yml` runs Aderyn over `src/` and keeps `aderyn-report.md` as a
build artifact and in the job summary. Its baseline is not triaged yet. When it is, add
it here in the same form.
