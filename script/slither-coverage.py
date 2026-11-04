#!/usr/bin/env python3
"""Fail when Slither's findings show it did not analyse the code it reports on.

Slither's first CI baseline (3 November 2026) reported every constructor-set variable of
AgentRegistry and HLAgentVault as "never initialized", including `immutable` ones, and
constants used inside `placeOrder` as "never used". Both are impossible if Slither saw
those function bodies: an immutable that is never assigned does not compile, and a
constant the compiler kept is referenced. So those findings are evidence that Slither's
model of the contract has lost writes and internal calls, and a baseline with them in it
says nothing about the code it lost — which included `placeOrder`'s limit checks.

This script reads the SARIF and fails if any such contradiction is present. It runs
before Slither is allowed to fail the build: a clean result from an analyser that cannot
see `placeOrder` is not a clean result.

    python3 script/slither-coverage.py results.sarif
"""

import json
import re
import sys
from pathlib import Path

UNINITIALIZED = "uninitialized-state"
UNUSED = "unused-state"
CONSTABLE = "constable-states"

# "HLAgentVault.platformTreasury (src/hyperliquid/HLAgentVault.sol#89) is never initialized."
VARIABLE = re.compile(r"^(\w+)\.(\w+) \(([^#)]+)#(\d+)\)")


def declaration(path: str, line: int) -> str:
    try:
        return Path(path).read_text().splitlines()[line - 1]
    except (OSError, IndexError):
        return ""


def references(path: str, name: str) -> int:
    try:
        return len(re.findall(rf"\b{re.escape(name)}\b", Path(path).read_text()))
    except OSError:
        return 0


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    sarif = json.loads(Path(sys.argv[1]).read_text())

    contradictions = []
    for run in sarif.get("runs", []):
        for result in run.get("results", []):
            rule = result.get("ruleId", "")
            text = result.get("message", {}).get("text", "")
            match = VARIABLE.match(text)
            if not match:
                continue
            contract, name, path, line = match.group(1), match.group(2), match.group(3), int(match.group(4))
            decl = declaration(path, line)

            if rule.endswith(UNINITIALIZED) or rule.endswith(CONSTABLE):
                if re.search(r"\bimmutable\b", decl):
                    contradictions.append(f"{contract}.{name} is immutable, so it is assigned in the constructor, "
                                          f"but Slither says {rule.split('-', 2)[-1]}: it lost the assignments in {contract}'s constructor")
            if rule.endswith(UNUSED) and references(path, name) > 1:
                contradictions.append(f"{contract}.{name} is referenced {references(path, name) - 1} time(s) in {path}, "
                                      "but Slither says it is never used: it lost the code that uses it")

    if contradictions:
        print("Slither's model of these contracts is incomplete, so its findings are not a baseline:")
        for c in sorted(set(contradictions)):
            print(f"  - {c}")
        return 1
    print("No coverage contradictions in the Slither findings.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
