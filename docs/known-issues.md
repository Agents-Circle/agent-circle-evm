# Known issues and stated limits

For auditors and for anyone writing copy about the product. Each entry is either a
limit we state publicly or an open design question, and none is a hidden bug. A
static-analysis finding that is accepted rather than fixed gets recorded here with its
reason.

Status as of 6 November 2026. Nothing is deployed, and nothing has been audited.

## Stated limits (the product says these out loud)

- **CoreWriter is fire-and-forget.** `placeOrder` knows only that it enqueued an
  action. Reservations are released by `reconcile`, by `cancelAll`, or by expiry after
  `MAX_ORDER_LIFETIME`. See ADR-0002.
- **Fast mode monitors limits rather than enforcing them.** The agent signs off-chain,
  and the vault never sees the order. Custody (no withdrawal by an API wallet) is the
  only guarantee left in that mode.
- **Withdrawal is never blocked by the protocol, but it can fail without HYPE on Core.**
  The Core → EVM bridge leg needs HYPE for gas. Three candidate fixes are in the
  `HLAgentVault` source, and none is chosen.
- **Slashing is a human multisig decision**, with published rationale. Wash trading
  isn't provable on-chain.
- **The execution fee underpays a high-frequency agent between reconciles.** A position
  opened and closed between two reconciles shows no net change. That's a revenue loss
  for us, not a harm to the trader. See `HLAgentVault._accrueExecutionFees`.
- **The Polygon singleton goes short once an order-book fill settles.** Settlement pulls
  from the pooled balance without calling the vault, so the paying vault's `idle` stays
  high. `_release` then returns `reserved` to zero on cancel or expiry and
  `_availableIdle` offers the whole stale figure to `withdraw`, so the sum of every
  vault's `idle` exceeds the contract's token balance and the shortfall lands on whoever
  withdraws last. This is ADR-0001 point 3 followed through to its consequence, and it
  is a solvency gap rather than the bookkeeping inconvenience README §4 previously
  called it. Unreachable today — no EIP-1271 entry point, no `src/adapters/`, nothing
  deployed — but the allowance is granted at `authoriseOrder`, so whitelisting an
  order-book adapter would reach it. The per-vault clones of ADR-0001 fix it
  structurally and must land first. Raised in external correspondence, 5 November 2026.

## Open design questions (decide before the audit freeze)

1. **Position cap semantics.**
   - `params/parameters.json` describes the cap as "per position, against total vault
     value".
   - `HLAgentVault._requireWithinPositionCap` checks the *sum* of every tracked
     position plus every reservation against `equity × cap`.
   - The invariant suite (`test/hyperliquid/HLAgentVault.invariant.t.sol`) pins today's
     aggregate reading, and has to change with any decision.
   - A consequence of the aggregate reading: a long can't lose more than 12% of equity.
     So the 15% drawdown auto-pause can never trigger from longs alone.
2. **Nothing but the trader or the agent can stop a fast-mode agent.**
   - `disableFastMode` is `onlyTraderOrAgent`.
   - `suspendListing` blocks vault-mode `placeOrder` only.
   - The drawdown auto-pause in `reconcile` closes tracked positions but leaves the API
     wallet registered.
   - Decide between shipping fast mode at launch and adding a governance or guardian
     lever first.
3. **Everything is fixed at deploy.**
   - `AgentRegistry` has no governance setter.
   - The vault implementation's treasury, platform builder and token are immutables.
   - `setVaultFactory` is one-shot.
   - A fix to the vault therefore means a new registry. This is why
     `script/hyperliquid/VerifyDeploy.s.sol` exists and must pass before any address is
     announced.
4. **Guardian ≠ governance isn't enforced in the EVM constructors.**
   - The Solana program enforces it.
   - On EVM it's enforced by the deploy scripts and checked again by `VerifyDeploy`,
     not by the contracts.

## Dependencies

- `hyper-evm-lib` @ `4eb7ab0` is pinned in `foundry.lock` and as a submodule. We found
  no published audit of it. The paths the vault calls (`CoreWriterLib`,
  `PrecompileLib`, `HLConstants`) belong in audit scope.
- OpenZeppelin v5.1.0: `Clones`, `Initializable`, `ReentrancyGuard`, `SafeERC20`.

## Static analysis

- Slither's first baseline is triaged in `docs/static-analysis.md`: 71 alerts, none
  requiring a source change. **Its model of the vaults lost writes and internal calls**
  (it calls immutables "never initialized" and `placeOrder`'s limit checks dead code), so
  it stays report-only until `script/slither-coverage.py` passes in CI. The cause is a
  name collision between our `library Errors` and OpenZeppelin 5.1's, which makes Slither
  drop 56 functions. Renaming ours fixes it without changing any error selector.
