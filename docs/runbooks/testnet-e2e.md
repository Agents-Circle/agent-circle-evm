# Testnet end-to-end run (HyperEVM testnet, chain 998)

The record that `script/probes/README.md` asks for: one transaction hash per step, and an
answer to each of the five questions. **A claim without a hash beside it is a claim nobody
has checked.** Fill the tables in as you go and commit the result.

Status: **not run.** Prepared 2026-11-04. The markets become executable on 2026-11-06
(below), and every step after that needs keys held by a person, not by an agent.

## Before you start

**Testnet only.** `TestnetProbe` refuses any chain other than 998, and the deploy script
refuses any chain other than 998 or 999. Keep it that way.

**Keys never touch this repository or a terminal paste.** Import each one once into a
Foundry keystore, then pass `--account <name>`:

```bash
cast wallet import governance --interactive
cast wallet import builder --interactive
cast wallet import trader --interactive
cast wallet import agent --interactive
cast wallet list
```

The README's `PRIVATE_KEY=...` export predates the handoff's rule. Use keystores.

```bash
export RPC=https://rpc.hyperliquid-testnet.xyz/evm
export REGISTRY=0x6757474DDC00CDa23F497faC09A2CD4B27117aCe
export WHITELIST=0x1445B9E5080a9fB5dfdB97537935f8D4c40F3f4A
export FACTORY=0x7c5F82a727ff7823E1EabC49119A6d6e823779b8
export USDC=0x2B3370eE501B4a559b57D449569354196457D8Ab
```

Testnet perp indices are not mainnet's: **BTC 3, ETH 4, SOL 0** (`TestnetProbe.BTC_PERP`
is 3).

## State read from the chain, 2026-11-04 06:43 UTC

Read-only `cast call`s, no key. Re-run them before step 0.

| Check | Value |
|---|---|
| `cast chain-id` | 998 |
| `REGISTRY.vaultFactory()` | `0x7c5F…79b8` = `FACTORY` |
| `FACTORY.implementation()` | `0x3861…bCcb` (the `HLAgentVault` implementation) |
| `WHITELIST.governance()` / `guardian()` | `0x3a78…3821` / `0x978e…1986` |
| `WHITELIST.delay()` | 172800 (2 days) |
| `WHITELIST.isListed(3 / 4 / 0)` | false / false / false |
| `WHITELIST.queued(3)` | eta 1793932534 = **2026-11-06 02:35:34 UTC**, cap 1200, not vetoed |
| `WHITELIST.queued(4)` | eta **02:35:44 UTC**, cap 1200 |
| `WHITELIST.queued(0)` | eta **02:35:53 UTC**, cap 1200 |

```bash
for a in 3 4 0; do cast call $WHITELIST "queued(uint32)(uint64,uint16,bool,bool)" $a --rpc-url $RPC; done
```

## A sizing problem in the README's step 3

The README deposits **15 USDC**. With the 1,200 bps cap, positions plus reservations may
not exceed 12% of equity, which is $1.80. **Hyperliquid's minimum order value is $10**, so
step 4's IOC either reverts with `PositionCapExceeded` or is too small to exist on Core.
A fillable minimum order needs equity of at least $10 / 0.12 ≈ $84. **Deposit 100 testnet
USDC** (the testnet faucet gives mock USDC). Step 6's bad-tick order is unaffected: it is
never meant to fill.

## Steps

### 0. Make the markets live (governance, after 2026-11-06 02:36 UTC)

```bash
for a in 3 4 0; do cast send $WHITELIST "executeAddition(uint32)" $a --rpc-url $RPC --account governance; done
cast call $WHITELIST "isListed(uint32)(bool)" 3 --rpc-url $RPC   # true
```

### 1. Deploy: done (4 November)

See the handoff for the addresses. `make verify-deploy RPC_URL=hyperevm_testnet` with
`ALLOW_EOA_GOVERNANCE=true` reported "OK".

### 2. Builder, bond, listing

```bash
BUILDER=$(cast wallet address --account builder); AGENT=$(cast wallet address --account agent)
BOND=$(cast call $REGISTRY "requiredBond(uint256)(uint256)" 1 --rpc-url $RPC | awk '{print $1}')
cast send $REGISTRY "registerBuilder()" --rpc-url $RPC --account builder
cast send $USDC "approve(address,uint256)" $REGISTRY $BOND --rpc-url $RPC --account builder
cast send $REGISTRY "stakeBond(uint256)" $BOND --rpc-url $RPC --account builder
cast send $REGISTRY "submitListing(address,bytes32)" $AGENT $(cast keccak "probe agent v1") --rpc-url $RPC --account builder
LISTING=$(cast call $REGISTRY "listingId(address,uint16)(bytes32)" $BUILDER 0 --rpc-url $RPC)
cast send $REGISTRY "approveListingAtLaunchTerms(bytes32)" $LISTING --rpc-url $RPC --account governance
```

### 3. Vault and deposit: question 2

```bash
TRADER=$(cast wallet address --account trader)
cast send $FACTORY "deployVault(bytes32,uint16,uint16)" $LISTING 1200 1500 --rpc-url $RPC --account trader
export VAULT=$(cast call $FACTORY "predictVault(address,bytes32)(address)" $TRADER $LISTING --rpc-url $RPC)
cast send $USDC "approve(address,uint256)" $VAULT 100000000 --rpc-url $RPC --account trader
cast send $VAULT "deposit(uint64)" 100000000 --rpc-url $RPC --account trader
forge script script/probes/TestnetProbe.s.sol --sig "probeReads()" --rpc-url $RPC
```

Then question 2, on a vault holding **zero** HYPE on Core:

```bash
AMOUNT=1000000 forge script script/probes/TestnetProbe.s.sol --sig "probeWithdrawWithoutHype()" --rpc-url $RPC --account trader --broadcast
```

### 4. One IOC on BTC, then reconcile

`LIMIT_PX` and `SZ` are at 1e8. Take a price a little through the best ask from
`l2Book` for BTC on testnet. Make it a whole dollar (always a valid tick), with notional
just over $10.

```bash
LIMIT_PX=<price*1e8> SZ=<size*1e8> forge script script/probes/TestnetProbe.s.sol --sig "probePlaceAndReconcile()" --rpc-url $RPC --account agent --broadcast
forge script script/probes/TestnetProbe.s.sol --sig "probeReconcile()" --rpc-url $RPC --account agent --broadcast
```

Confirm the order appears twice in the L1 explorer (enqueued, then executed). Confirm the
accrued execution fee equals filled notional × 2 bps, not requested notional.

### 5. Cancel and confirm the reservation clears

```bash
cast send $VAULT "cancelOrder(uint128)" <cloid> --rpc-url $RPC --account agent
cast call $VAULT "reserved()(uint64)" --rpc-url $RPC
```

### 6. Bad tick is silently dropped

```bash
forge script script/probes/TestnetProbe.s.sol --sig "probeBadTickIsSilentlyDropped()" --rpc-url $RPC --account agent --broadcast
```

### 7–9. Fast mode, API-wallet replacement, kill switch: questions 1 and 3

**Blocked on a decision:** whether fast mode exists at launch is open for Udoka
(handbook#2). Run these only if the answer isn't "no". They need two throwaway API-wallet
keys and an off-chain signed order (Python or TS SDK).

```bash
API_WALLET=<addr> forge script script/probes/TestnetProbe.s.sol --sig "probeEnableFastMode()" --rpc-url $RPC --account trader --broadcast
API_WALLET_2=<addr> forge script script/probes/TestnetProbe.s.sol --sig "probeReplaceApiWallet()" --rpc-url $RPC --account trader --broadcast
cast send $VAULT "disableFastMode()" --rpc-url $RPC --account trader
```

### 10. Withdraw everything

```bash
cast send $VAULT "requestWithdraw(uint64)" $(cast call $VAULT "availableToWithdraw()(uint64)" --rpc-url $RPC | awk '{print $1}') --rpc-url $RPC --account trader
cast send $VAULT "finalizeWithdraw()" --rpc-url $RPC --account trader
```

## Record

| Step | What | Tx hash | Observed |
|---|---|---|---|
| 0 | `executeAddition` 3, 4, 0 | | |
| 2 | register, bond, submit, approve | | |
| 3 | deploy vault, deposit 100 USDC | | |
| 3 | withdraw with zero HYPE | | |
| 4 | IOC placed; reconcile | | |
| 5 | cancel | | |
| 6 | bad tick | | |
| 7 | enable fast mode, builder-field order | | |
| 8 | replace API wallet, retry old key | | |
| 9 | kill switch | | |
| 10 | withdraw all | | |

## The five questions

| # | Question | Answer | Evidence |
|---|---|---|---|
| 1 | Which `setAbstraction` value is standard mode (builder fees accrue)? | | |
| 2 | How much HYPE does a vault need on Core to bridge USDC out? | | |
| 3 | Does re-adding an API wallet under the same name revoke the old key? | | |
| 4 | Do CoreWriter orders work on HIP-3 and HIP-4 assets? | | |
| 5 | Is CoreWriter enabled for all asset classes on mainnet? (a human, on mainnet) | | |
