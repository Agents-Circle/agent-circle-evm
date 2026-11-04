# Probes

Scripts that answer questions the test suite cannot.

The test suite etches mocks at the precompile and CoreWriter addresses. That proves the
vault's logic and nothing whatsoever about Hyperliquid — whether an action is accepted,
what a tick size must be, whether builder fees accrue, how much HYPE a bridge costs. Each
of those is a fact about somebody else's system, and the only way to learn it is to do it.

**Nothing here has been run.** These were written from the docs and the library source.
Expect the first run to surface something, and treat a surprise as information rather than
as the script being broken.

## Ground rules

- **Testnet only** for anything automated. Mainnet steps are listed below for a human to
  run deliberately, with their own key, reading the output as they go.
- Keys come from environment variables, never from a file in this repository.
- Run them in order. Later probes depend on state earlier ones create.

```bash
export HYPEREVM_TESTNET_RPC_URL=https://rpc.hyperliquid-testnet.xyz/evm
export PRIVATE_KEY=...        # a throwaway key with testnet USDC and a little HYPE
export TESTNET_USDC=0x2B3370eE501B4a559b57D449569354196457D8Ab
```

## The questions, in priority order

Priority is by how much depends on the answer, not by how hard it is.

### 1. Which `setAbstraction` value is "standard" mode? — gates fast-mode revenue

Builder fees accrue only in standard account mode. Action 16 accepts
`1 = disabled, 2 = unifiedAccount, 3 = portfolioMargin` and **nothing is named
"standard"**. `enableFastMode` sends `1`, on the reading that standard is the absence of
abstraction.

If that reading is wrong, fast mode looks like it works and earns nothing — silently, with
no error anywhere. That is the worst failure shape available to us, which is why this is
first.

**How to tell:** enable fast mode, place one API-wallet order carrying a builder field,
then query the `referral` info endpoint for the builder address. A fee that appears is the
answer. A fee that does not appear, with a filled order, means the mode is wrong.

### 2. How much HYPE does a vault need on Core to bridge USDC out? — qualifies the guarantee

`hyper-evm-lib` notes that `sendAsset` for a non-HYPE token requires the sender to hold
HYPE for gas. A vault that has never held HYPE cannot complete a withdrawal bridge, which
makes "withdrawal always succeeds" false in precisely the case nobody tests.

**How to tell:** deposit, then attempt `requestWithdraw` → `finalizeWithdraw` from a vault
holding **zero** HYPE on Core. Record whether the bridge completes. If it does not, bisect
the minimum amount that makes it work, and record both numbers — the figure is not
documented anywhere we could find.

The answer decides between three designs: factory-funded dust at deploy, provisioning out
of the deposit, or keeper top-ups with the shortfall shown to the trader.

### 3. Does re-adding an API wallet under the same name revoke the previous key?

The obvious implementation of a kill switch. `disableFastMode` is deliberately written not
to rely on it — it clears the vault's record, pauses, and sends reduce-only closes, so a
surviving key has nothing to trade and no way to withdraw.

**How to tell:** register key A, sign an order with it and confirm it lands. Register key B
under the same name. Sign another order with key A. If it is rejected, re-adding revokes.

### 4. Do CoreWriter orders work against HIP-3 and HIP-4 assets?

Asset ID ranges, and whether outcome operations work from a contract account. Note that
`hyper-evm-lib` ships **no helper for action 17**, so HIP-4 needs raw encoding:
`abi.encodePacked(uint8(1), uint24(17), abi.encode(op, question, outcome, wei))` with
`op`: `0 = SplitOutcome, 1 = MergeOutcome, 2 = MergeQuestion, 3 = NegateOutcome`, unused
fields zero, and `wei` a multiple of size.

### 5. Is CoreWriter enabled for all asset classes on mainnet?

Testnet tells you about testnet. **Leave the mainnet half to a human.**

## Testnet sequence

The end-to-end path, in the order the deliverable asks for it:

1. Deploy the registry, whitelist, vault implementation and factory
   (`script/hyperliquid/Deploy.s.sol`).
2. Register a builder, bond, submit and approve a listing.
3. Open a vault; deposit 15 USDC. **Check whether the bridge needs HYPE (question 2).**
4. Place one minimum-size IOC order on BTC perps through `placeOrder`. Then `reconcile`.
   - Confirm the order appears **twice** in the L1 explorer: enqueued, then executed.
     That is the CoreWriter delay, visible.
   - Confirm the execution fee accrued matches the fill, not the request.
5. Cancel an order and confirm the reservation clears.
6. **Place an order with a deliberately wrong tick size.** Confirm the EVM transaction
   succeeds and the order never exists. This is the fire-and-forget behaviour the whole
   reservation design rests on, and it should be seen at least once.
7. Enable fast mode. Submit one API-wallet order with a builder field via the Python or TS
   SDK. Verify with `maxBuilderFee` and the `referral` info request (question 1).
8. Replace the API wallet; retry the old key (question 3).
9. Trigger the kill switch and confirm positions close.
10. Withdraw everything. Confirm the trader receives it and the high-water mark falls.

## Mainnet, for a human

About $20 is enough. Do **not** automate this.

Run steps 3, 4, 7 and 10 with minimum sizes. The output that proves each claim:

| Claim | What proves it |
|---|---|
| Vault holds its own HyperCore account | The vault address appears as the account on the fill |
| Limits checked before every order | A deliberately oversized order reverts on the EVM, with `PositionCapExceeded` |
| Fire-and-forget is real | Step 6's transaction succeeds with no order on Core |
| Execution fee tracks fills | Accrued fee matches filled notional × 2 bps, not requested |
| Builder fees accrue in fast mode | A non-zero balance for the builder address in `referral` |
| Withdrawal is not blocked by the protocol | Step 10 completes with the listing suspended |

Record transaction hashes in `docs/runbooks/testnet-e2e.md`. A claim without a hash
beside it is a claim nobody has checked.
