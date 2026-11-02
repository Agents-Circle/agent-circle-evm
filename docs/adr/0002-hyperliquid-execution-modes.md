# ADR-0002: Hyperliquid execution modes — vault mode and fast mode

**Status:** Accepted
**Date:** 2 November 2026
**Deciders:** Protocol lead; anyone signing off on what the product publicly claims

## Context

Agent Circle's guarantee has always been phrased in terms of enforcement: *limits are
enforced by the contract rather than monitored after the fact.* On Polygon that held
because the vault was in the transaction. On Hyperliquid it holds in one mode and not the
other, and the difference is not a detail — it is the difference between a claim we can
defend in a technical conversation and one we cannot.

Three facts about HyperCore set the shape of this decision. All three were verified
against the live docs and the `hyper-evm-lib` source rather than inferred.

### 1. CoreWriter is fire-and-forget

`CoreWriter.sendRawAction` succeeds whether or not HyperCore accepts the action. An order
the vault "placed" may never have existed — rejected for tick size, for `szDecimals`, for
insufficient perp margin, or because the asset is not live. **Nothing on the EVM side can
tell the difference at call time.**

This is the single most consequential fact in the design and it is not in the original
brief. It means the vault's idea of its own open orders is a hypothesis, not a fact.

### 2. CoreWriter's order action cannot carry a builder code

Action 1 is
`(uint32 asset, bool isBuy, uint64 limitPx, uint64 sz, bool reduceOnly, uint8 tif, uint128 cloid)`.
There is no `builder` field. Builder codes are a property of an order **signed off-chain**
and submitted with `{"b": address, "f": tenths of a bp}`.

So a vault that places every order through CoreWriter cannot earn builder-code revenue,
at all. Not inefficiently — not at all.

### 3. Order actions are delayed

Orders and vault transfers sent through CoreWriter are delayed a few seconds and appear
twice in the L1 explorer, first enqueued and then executed. For a market-making or
latency-sensitive strategy that delay is the difference between a viable strategy and an
unviable one.

## Decision

Ship **two modes**, with different and separately-stated guarantees.

### Vault mode (default)

The agent calls `HLAgentVault.placeOrder`. Six checks hold **before the action is sent**:
vault active, listing live, caller is the listing's agent authority, asset whitelisted,
worst-case notional plus every outstanding reservation within the position cap at the
current mark, and equity within the drawdown limit from the high-water mark.

Reduce-only orders skip the cap check: they can only ever lower exposure, and a vault
already over its cap must not be blocked from getting back under it.

**Public claim:** *"limits are checked before every order and reconciled continuously."*

Note what that sentence does **not** say. It does not say "enforced in the same
transaction as the trade", because the trade is not in our transaction — the check is
before it, and settlement happens on Core seconds later. It also does not say the vault
knows its open orders, because fact 1 says it cannot.

### Fast mode (trader opt-in)

The vault registers the agent's key as a HyperCore API wallet (action 9) and approves the
Agent Circle builder address (action 12). The agent then signs orders off-chain with a
`builder` field. Real builder revenue accrues and the CoreWriter delay disappears.

The vault never sees those orders. Limits are watched by a keeper against the precompiles
and enforced by a kill switch after the fact.

**Public claim:** *"limits are monitored, with an automatic kill switch."* The UI must say
**"limits monitored, not enforced"** at the point of opt-in, not in a footnote.

What survives: an API wallet can trade but **cannot withdraw**. Custody holds in both
modes. That is the floor, and in fast mode it is the only guarantee left standing.

## Why the execution fee is charged at reconcile

The brief books the 2 bps execution fee inside `placeOrder`, against `sz × limitPx`. This
implementation charges it at `reconcile`, against size that demonstrably changed. The
reason is fact 1: **billing a trader for an order HyperCore rejected would be
indefensible, and an agent could farm it** by spamming orders it knew would be refused.

The measurement is `|szi_now - szi_last| × markPx` per tracked asset, and it is wrong in
one direction which is worth stating plainly rather than discovering later:

> A position opened and closed entirely between two reconciles shows no net change and is
> not billed.

A high-frequency agent against an idle keeper therefore underpays. That is a revenue
loss, not a trader harm, and it is the correct direction to be wrong in. The keeper calls
`reconcile` on fill events specifically to close the gap.

Deviation from the brief, recorded for REPORT.md.

## Reconciliation is not a convenience

Because an action may be silently dropped, `reconcile` is the **only** path by which a
reservation is ever truthfully released. It must release reservations for orders Core
never received as readily as for orders that filled, and it cannot distinguish the two.

Two things make that safe rather than merely tolerable:

- `MAX_ORDER_LIFETIME` (1 hour) bounds how long a dropped order can hold capital, with no
  keeper involvement at all.
- `cancelAll` lets the trader clear every reservation in one transaction, without the
  agent, at any time.

`reconcile` is permissionless for the same reason: every party has a reason to want it run
and none of them can be relied upon.

## Consequences

**Easier**
- Builder-code revenue becomes possible, in fast mode.
- Per-vault attribution is structural: the clone's address *is* its HyperCore account.
- The allowance-mirror machinery the Polygon design needed has no analogue here and is
  simply absent — HyperCore pulls from the account, and the account is the vault.

**Harder**
- Two modes, two claims, and a UI that has to be honest about which one is active.
- A keeper becomes load-bearing in fast mode rather than merely useful.
- The position cap in fast mode is only as good as the keeper's polling interval.

**New risk introduced by fast mode**
- An agent with an API wallet can churn the account at will. It cannot withdraw, but it
  can lose money faster than a keeper notices. The drawdown kill switch is the bound, and
  it is a bound measured in keeper latency, not in blocks.

## Open questions

These are live and some of them gate revenue. None should be treated as settled.

1. **Does re-adding an API wallet under the same name revoke the previous key?** The fast
   mode kill switch would depend on it. `disableFastMode` is deliberately written *not*
   to depend on it: it clears the vault's record, pauses, and sends reduce-only closes, so
   a surviving key is left with nothing to trade and no way to withdraw. Confirm on
   testnet anyway.
2. **Which `setAbstraction` value is "standard" mode?** Builder fees require standard
   account mode. Action 16 offers `1 = disabled, 2 = unifiedAccount, 3 = portfolioMargin`
   — **nothing named standard**. `enableFastMode` sends `1`, on the reading that standard
   *is* the absence of abstraction. If that is wrong, fast-mode builder revenue silently
   never accrues. **First thing the probe must settle.**
3. **Can a contract account approve a builder fee at all?** The docs say
   `ApproveBuilderFee` "must be signed by the user's main wallet, not an agent/API
   wallet". CoreWriter action 12 is the documented route for a contract, so presumably
   yes — but that is an inference, not a quoted guarantee.
4. **How much HYPE does a vault need on Core to bridge USDC back to the EVM?**
   `hyper-evm-lib` notes that `sendAsset` for a non-HYPE token requires the sender to
   hold HYPE for gas. A vault that has never held HYPE therefore cannot complete a
   withdrawal bridge. **This qualifies the headline guarantee** and is unresolved: the
   options are factory-funded dust at deploy, provisioning out of the deposit, or keeper
   top-ups with the shortfall surfaced to the trader. Until it is settled the honest claim
   is *"withdrawal is never blocked by the protocol"* — no vault state, listing state or
   whitelist change can stop it — rather than *"withdrawal always succeeds"*.
5. **CoreWriter behaviour against HIP-3 and HIP-4 assets** — asset ID ranges, and whether
   outcome operations (action 17) work from a contract account. Note that `hyper-evm-lib`
   has **no helper for action 17**, so HIP-4 needs raw encoding.
6. **Is CoreWriter enabled for all asset classes on mainnet?** Probe on testnet; mainnet
   is the human's.

## What the tests prove, and what they do not

The suite etches mocks at the real precompile and CoreWriter addresses, so the contract
under test is the production one calling production library code. It proves the vault's
own logic: reservations accumulate against the cap, a thin market's cap binds before the
trader's, reduce-only skips the cap, a silently dropped order cannot strand capital past
expiry, withdrawal is reachable in every vault and listing state, the execution fee
charges fills rather than requests, and an idle vault accrues nothing.

It does **not** prove anything about Hyperliquid. Matching, fees, margin, tick sizes and
whether any of these actions are accepted at all are outside it. That is what
`script/probes/` is for, and the gap between the two is the reason the probe exists rather
than being optional.
