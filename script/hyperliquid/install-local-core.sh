#!/usr/bin/env bash
#
# Install the HyperCore mocks onto a local anvil node.
#
# ## Why this exists
#
# `DeployLocal.s.sol` on Polygon can drive the whole product end to end because every
# dependency is a contract it deploys. On HyperEVM three of them are not contracts at all
# — the read precompiles, the CoreWriter and the Core deposit wallet are chain features,
# and on a bare anvil node they are empty addresses. A local deploy without them gets as
# far as opening a vault and then reverts on the first `deposit`, because the bridge reads
# the token-info precompile.
#
# Foundry's `vm.etch` solves this inside a test but is not available to a script. Anvil's
# `anvil_setCode` RPC is the equivalent from outside, so this installs the same mock
# bytecode the test suite uses at the same addresses.
#
# What you get is a local chain the full journey runs against, which is worth having:
# it exercises the deployed bytecode rather than the test EVM. What you do **not** get is
# anything about Hyperliquid — no matching, no fees, no margin, no tick sizes. That is
# what `script/probes/` is for, and the distinction matters when reading a green run here.
set -euo pipefail

RPC="${RPC_URL:-http://127.0.0.1:8546}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

# Matches test/hyperliquid/HLAgentVault.t.sol and src/hyperliquid/HLAgentVault.sol.
CORE_WRITER=0x3333333333333333333333333333333333333333
POSITION=0x0000000000000000000000000000000000000800
MARK_PX=0x0000000000000000000000000000000000000806
TOKEN_INFO=0x000000000000000000000000000000000000080C
MARGIN_SUMMARY=0x000000000000000000000000000000000000080F
POSITION2=0x0000000000000000000000000000000000000813

# Mainnet HyperEVM addresses, because HLConstants resolves them from block.chainid and
# anvil must therefore be started with --chain-id 999. See the Makefile target.
USDC=0xb88339CB7199b77E23DB6E890353E22632Ba630f
DEPOSIT_WALLET=0x6B9E773128f453f5c2C60935Ee2DE2CBc5390A24

echo "▸ Building so the mock bytecode is current"
forge build >/dev/null

install() {
  local name="$1" addr="$2"
  local code
  code="$(forge inspect "$name" deployedBytecode)"
  if [[ -z "$code" || "$code" == "0x" ]]; then
    echo "!! no deployed bytecode for $name" >&2
    exit 1
  fi
  cast rpc --rpc-url "$RPC" anvil_setCode "$addr" "$code" >/dev/null
  echo "   $name -> $addr"
}

echo "▸ Installing HyperCore mocks on $RPC"
install MockCoreWriter        "$CORE_WRITER"
install MockPosition          "$POSITION"
install MockPosition          "$POSITION2"
install MockMarkPx            "$MARK_PX"
install MockTokenInfo         "$TOKEN_INFO"
install MockMarginSummary     "$MARGIN_SUMMARY"
install MockCoreDepositWallet "$DEPOSIT_WALLET"
install MockERC20             "$USDC"

echo "▸ Wiring the mocks together"
# The deposit wallet has to know which token to pull, and the token-info precompile has
# to describe it, or the bridge path reverts exactly as it did the first time this was
# tried in the test suite.
cast send --rpc-url "$RPC" --unlocked --from 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 \
  "$DEPOSIT_WALLET" "setToken(address)" "$USDC" >/dev/null
cast send --rpc-url "$RPC" --unlocked --from 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 \
  "$TOKEN_INFO" "set(address,uint8)" "$USDC" 6 >/dev/null

# szDecimals = 2, so a $1 mark is 1e4 and `szi * markPx` lands in USDC at 1e6. The same
# convention the test suite documents.
for perp in 3 77; do
  cast send --rpc-url "$RPC" --unlocked --from 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 \
    "$MARK_PX" "set(uint32,uint64)" "$perp" 10000 >/dev/null
done

echo "▸ Done. HyperCore is simulated; Hyperliquid is not."
