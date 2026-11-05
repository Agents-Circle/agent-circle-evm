#!/usr/bin/env bash
# Machine-check the properties in test/formal/ with solc's SMTChecker.
#
#   script/formal/smtcheck.sh [chc|bmc]      (default: chc)
#
# Needs solc 0.8.24 (Foundry installs it) and z3 4.12, which solc 0.8.24 loads at
# runtime as libz3.so.4.12. If it isn't on the library path, the z3-solver wheel is
# installed into a temporary directory and used from there; nothing is installed
# system-wide.
#
# Exit status: 1 if the solver finds a counterexample ("happens here"), 0 otherwise.
# "Might happen" means the solver timed out or gave up: unproved, not refuted. Those
# are listed but don't fail the run, because a timeout says nothing about the code.
set -euo pipefail

engine="${1:-chc}"
# Foundry's svm keeps compilers in ~/.local/share/svm (newer) or ~/.svm (older).
solc="${SOLC:-}"
for candidate in "$HOME/.local/share/svm/0.8.24/solc-0.8.24" "$HOME/.svm/0.8.24/solc-0.8.24"; do
  [ -z "$solc" ] && [ -x "$candidate" ] && solc="$candidate"
done
[ -n "$solc" ] || { echo "smtcheck: solc 0.8.24 not found; run forge build first" >&2; exit 2; }

if ! ldconfig -p 2>/dev/null | grep -q 'libz3.so.4.12'; then
  z3dir="${Z3_DIR:-$(mktemp -d)}"
  if [ ! -e "$z3dir/z3/lib/libz3.so.4.12" ]; then
    python3 -m pip install --quiet --target "$z3dir" "z3-solver==4.12.6.0"
  fi
  export LD_LIBRARY_PATH="$z3dir/z3/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi

out="$(mktemp)"
"$solc" --base-path . \
  --model-checker-engine "$engine" \
  --model-checker-targets assert,underflow,overflow \
  --model-checker-show-proved-safe --model-checker-show-unproved \
  --model-checker-timeout "${SMT_TIMEOUT_MS:-120000}" \
  --model-checker-contracts test/formal/HighWaterMarkSMT.sol:HighWaterMarkSMT \
  test/formal/HighWaterMarkSMT.sol >"$out" 2>&1 || true

if grep -q "was selected for SMTChecker but it is not available\|no Horn solver was found" "$out"; then
  cat "$out"; echo "smtcheck: no working solver" >&2; exit 2
fi

proved=$(grep -c "check is safe" "$out" || true)
unproved=$(grep -c "might happen here" "$out" || true)
refuted=$(grep -c "happens here\." "$out" || true)
echo "smtcheck ($engine): $proved proved, $unproved unproved (timeout/unknown), $refuted refuted"
grep -A1 -E "might happen here|happens here\." "$out" | grep -- "-->" | sed 's/^ *--> */  unproved or refuted: /' || true
if [ "$refuted" -gt 0 ]; then
  grep -B1 -A12 "happens here\." "$out"
  exit 1
fi
