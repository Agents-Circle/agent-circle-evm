#!/usr/bin/env bash
#
# Execute the queued market additions on HLMarketWhitelist once their timelock elapses.
#
# ## Why this exists
#
# `queueAddition` stores an `eta` of `block.timestamp + delay` and `executeAddition`
# reverts with `TimelockNotElapsed` until the chain passes it. Two things make that easy
# to get wrong by hand:
#
#   - The comparison is against **chain** time, not your clock, and this RPC will
#     sometimes hand you a head that is tens of seconds stale — or reject `latest`
#     outright with `invalid block height`, racing its own chain tip. So the chain time
#     here is read from an explicit block number, with a retry, and the script says how
#     much chain time is actually left rather than trusting either clock.
#   - `executeAddition` is `onlyGovernance`, and the governance key is not the deployer
#     key. Sending from the wrong one reverts with `NotGovernance`. The address the
#     contract requires is printed before anything is sent, to check against.
#
# Both of those have already cost a run. Neither spends anything — they revert at gas
# estimation — but a revert in the middle of a three-asset sequence leaves you unsure
# which ones landed, so the script re-reads `isListed` at the end rather than trusting
# the exit codes.
#
# ## Usage
#
#     script/hyperliquid/execute_queued_markets.sh                 # check only, no keys
#     script/hyperliquid/execute_queued_markets.sh --execute       # check, then send
#     ASSETS="3 4" script/hyperliquid/execute_queued_markets.sh --execute
#
# Defaults to assets 3, 4, 0 — BTC, ETH and SOL as HyperCore indexes them on **testnet**.
# Mainnet numbers them differently, so pass ASSETS explicitly there.
#
# Reads WHITELIST and HYPEREVM_TESTNET_RPC_URL from the environment, falling back to
# `.env`. ACCOUNT is the `cast wallet` keystore account holding the governance key; with
# `--execute` each send prompts for its password separately, which is the cost of not
# having the key on the command line or in shell history.

set -euo pipefail

cd "$(dirname "$0")/../.."

[[ -f .env ]] && set -a && source .env && set +a

ASSETS="${ASSETS:-3 4 0}"
ACCOUNT="${ACCOUNT:-governance}"
RPC="${RPC:-${HYPEREVM_TESTNET_RPC_URL:-https://rpc.hyperliquid-testnet.xyz/evm}}"
EXECUTE=0
[[ "${1:-}" == "--execute" ]] && EXECUTE=1

if [[ -z "${WHITELIST:-}" ]]; then
  echo "WHITELIST is not set, and .env does not define it." >&2
  exit 1
fi

name_for() {
  case "$1" in
    0) echo "SOL" ;;
    1) echo "APT" ;;
    2) echo "ATOM" ;;
    3) echo "BTC" ;;
    4) echo "ETH" ;;
    *) echo "asset $1" ;;
  esac
}

chain_id=$(cast chain-id --rpc-url "$RPC")

# Not `cast block latest`: this RPC intermittently answers that with
# `invalid block height: <n>`, having advanced its tip between resolving `latest` and
# serving it. An explicit height, retried and stepped back, is stable.
chain_now=""
for attempt in 1 2 3; do
  head=$(cast block-number --rpc-url "$RPC" 2>/dev/null) || continue
  for offset in 0 1 2; do
    if chain_now=$(cast block "$(( head - offset ))" --field timestamp --rpc-url "$RPC" 2>/dev/null); then
      break 2
    fi
  done
  chain_now=""
done
if [[ -z "$chain_now" ]]; then
  echo "Could not read a block timestamp from $RPC after three attempts." >&2
  echo "Without chain time there is no safe way to tell whether the timelock has passed." >&2
  exit 1
fi
governance=$(cast call "$WHITELIST" 'governance()(address)' --rpc-url "$RPC")
delay=$(cast call "$WHITELIST" 'delay()(uint64)' --rpc-url "$RPC" | awk '{print $1}')

echo "whitelist   $WHITELIST"
echo "chain       $chain_id"
echo "chain time  $chain_now  ($(date -u -r "$chain_now" '+%Y-%m-%d %H:%M:%S') UTC)"
echo "your clock  $(date -u '+%Y-%m-%d %H:%M:%S') UTC"
echo "delay       ${delay}s"
echo "governance  $governance   <- the send must come from this address"
echo

ready=()
for asset in $ASSETS; do
  coin=$(name_for "$asset")
  listed=$(cast call "$WHITELIST" 'isListed(uint32)(bool)' "$asset" --rpc-url "$RPC")
  read -r eta cap vetoed exists <<<"$(
    cast call "$WHITELIST" 'queued(uint32)(uint64,uint16,bool,bool)' "$asset" --rpc-url "$RPC" |
      awk '{print $1}' | tr '\n' ' '
  )"

  if [[ "$listed" == "true" ]]; then
    echo "$coin (asset $asset): already listed, nothing to do"
    continue
  fi
  if [[ "$exists" != "true" ]]; then
    echo "$coin (asset $asset): not queued — queueAddition first, then wait ${delay}s"
    continue
  fi
  if [[ "$vetoed" == "true" ]]; then
    echo "$coin (asset $asset): VETOED. executeAddition will revert; re-queue it instead"
    continue
  fi

  if (( chain_now < eta )); then
    left=$(( eta - chain_now ))
    printf '%s (asset %s): not yet — eta %s UTC, %dh %dm %ds of chain time left\n' \
      "$coin" "$asset" "$(date -u -r "$eta" '+%H:%M:%S')" \
      $(( left / 3600 )) $(( (left % 3600) / 60 )) $(( left % 60 ))
  else
    printf '%s (asset %s): READY — eta passed, cap %s bps\n' "$coin" "$asset" "$cap"
    ready+=("$asset")
  fi
done

echo
if (( ${#ready[@]} == 0 )); then
  echo "Nothing ready. Re-run when the etas above have passed."
  exit 0
fi

if (( EXECUTE == 0 )); then
  echo "Ready: ${ready[*]}. Re-run with --execute to send, or by hand:"
  for asset in "${ready[@]}"; do
    echo "  cast send $WHITELIST 'executeAddition(uint32)' $asset --rpc-url $RPC --account $ACCOUNT"
  done
  exit 0
fi

for asset in "${ready[@]}"; do
  echo "--- executeAddition($asset)  [$(name_for "$asset")]"
  # No --slow and no gas override: this is a single storage write, so a 3M-gas small
  # block is ample. A gas failure here means something other than block size.
  cast send "$WHITELIST" 'executeAddition(uint32)' "$asset" \
    --rpc-url "$RPC" --account "$ACCOUNT" || echo "  send failed for asset $asset, continuing"
done

echo
echo "=== final state, read back from the chain"
for asset in $ASSETS; do
  printf '  %-4s asset %-2s listed=%s cap=%s\n' \
    "$(name_for "$asset")" "$asset" \
    "$(cast call "$WHITELIST" 'isListed(uint32)(bool)' "$asset" --rpc-url "$RPC")" \
    "$(cast call "$WHITELIST" 'effectiveCapBps(uint32,uint16)(uint16)' "$asset" 1200 --rpc-url "$RPC" | awk '{print $1}')"
done
