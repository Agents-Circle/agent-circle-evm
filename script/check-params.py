#!/usr/bin/env python3
"""Fail the build when the locked launch parameters have drifted.

`params/parameters.json` is the single source of truth. The same numbers are written out
three more times — in Solidity, in Anchor, and in the public docs — and three copies of a
number is three chances for one of them to be wrong. They have drifted before: when this
script was written, `FeeConfig::validate()` on the Anchor side bounded the position cap
and drawdown limit only against 10,000 bps, while Solidity bounded them at 2,500 and
5,000. Solana governance could approve a listing with a 100% position cap that Solidity
would have rejected. Nothing caught it for two months.

So this is not a tidiness check. A guardrail that exists in one implementation and not
another is not a guardrail, and the failure mode is silent.

Three targets:

  1. `src/libraries/Constants.sol`
  2. `agent-circle-programs/.../constants.rs` — a sibling checkout when there is one,
     otherwise fetched from raw GitHub, because CI for this repo has no sibling clone
  3. `mintlify-docs/concepts/parameters.mdx` — regenerated from the JSON and diffed, so
     the docs table cannot be edited into disagreement with the code

Run `--write` to regenerate the docs table in place. Run with no arguments to check.
No third-party dependencies: this has to work in a Foundry-only repo and in CI.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
PARAMS = REPO / "params" / "parameters.json"

RUST_LOCAL = REPO.parent / "agent-circle-programs" / "programs" / "agent-registry" / "src" / "constants.rs"
RUST_RAW = (
    "https://raw.githubusercontent.com/Agents-Circle/agent-circle-programs/"
    "main/programs/agent-registry/src/constants.rs"
)
DOCS_LOCAL = REPO.parent / "mintlify-docs" / "concepts" / "parameters.mdx"

SECONDS_PER = {"seconds": 1, "minutes": 60, "hours": 3600, "days": 86400, "weeks": 604800}

# Markers around the generated table, so the rest of the page stays hand-written.
BEGIN = "{/* BEGIN GENERATED — edit params/parameters.json, then run script/check-params.py --write */}"
END = "{/* END GENERATED */}"


class Drift(Exception):
    pass


# ───────────────────────────────────────────────────────────── source parsing


def parse_solidity(text: str) -> dict[str, int]:
    """`uint16 internal constant FOO = 1_000;` and `uint64 ... = 14 days;`"""
    out: dict[str, int] = {}
    pattern = re.compile(
        r"\b(?:u?int\d*)\s+internal\s+constant\s+(\w+)\s*=\s*([^;]+);",
        re.MULTILINE,
    )
    for name, raw in pattern.findall(text):
        raw = raw.strip()
        unit = re.fullmatch(r"([\d_]+)\s+(\w+)", raw)
        if unit and unit.group(2) in SECONDS_PER:
            out[name] = int(unit.group(1).replace("_", "")) * SECONDS_PER[unit.group(2)]
            continue
        try:
            out[name] = _arith(raw)
        except ValueError:
            pass  # non-numeric constant (a string seed, an address); not our business
    return out


def parse_rust(text: str) -> dict[str, int]:
    """`pub const FOO: u16 = 1_000;` and `pub const BAR: i64 = 14 * 24 * 60 * 60;`

    `#[cfg(...)]`-gated constants appear more than once. The first wins, which is the
    production value, because the localnet override is always the later of the pair.
    """
    out: dict[str, int] = {}
    pattern = re.compile(r"pub\s+const\s+(\w+)\s*:\s*[\w:<>\[\];\s]+?=\s*([^;]+);", re.MULTILINE)
    for name, raw in pattern.findall(text):
        if name in out:
            continue
        try:
            out[name] = _arith(raw.strip())
        except ValueError:
            pass
    return out


def _arith(expr: str) -> int:
    """Evaluate a literal integer arithmetic expression. Digits, * + - ( ) only.

    Deliberately not `eval` on arbitrary text: this reads files fetched over the network.
    """
    expr = expr.replace("_", "").strip()
    if not re.fullmatch(r"[\d\s*+\-()]+", expr):
        raise ValueError(expr)
    try:
        value = eval(expr, {"__builtins__": {}}, {})  # noqa: S307 — guarded by the regex above
    except Exception as exc:  # pragma: no cover
        raise ValueError(expr) from exc
    if not isinstance(value, int):
        raise ValueError(expr)
    return value


def read_rust_source() -> tuple[dict[str, int], str]:
    if RUST_LOCAL.exists():
        return parse_rust(RUST_LOCAL.read_text()), f"sibling checkout ({RUST_LOCAL})"
    try:
        with urllib.request.urlopen(RUST_RAW, timeout=30) as resp:
            return parse_rust(resp.read().decode()), f"raw GitHub ({RUST_RAW})"
    except (urllib.error.URLError, TimeoutError) as exc:
        raise Drift(
            f"could not read the Anchor constants: no sibling checkout at {RUST_LOCAL} "
            f"and fetching {RUST_RAW} failed ({exc}). The parity check cannot pass "
            f"without seeing both implementations."
        ) from exc


# ───────────────────────────────────────────────────────────── expectations


def expectations(params: dict) -> list[tuple[str, int, list[str], list[str]]]:
    """(label, expected value, solidity names, rust names) — one row per bound."""
    rows: list[tuple[str, int, list[str], list[str]]] = []

    for group in ("economics", "risk"):
        for key, spec in params[group].items():
            sol, rust = spec["solidity"], spec["rust"]
            rows.append((f"{key} default", spec["value"], sol[:1], rust[:1]))
            if len(sol) > 1:
                rows.append((f"{key} guardrail", spec["guardrail"], sol[1:2], rust[1:2]))

    unbond = params["timing"]["unbond_period_days"]
    rows.append(
        (
            "unbond period default",
            unbond["value"] * SECONDS_PER["days"],
            unbond["solidity"][:1],
            unbond["rust"][:1],
        )
    )
    rows.append(
        (
            "unbond period guardrail",
            unbond["guardrail"] * SECONDS_PER["days"],
            unbond["solidity"][1:2],
            unbond["rust"][1:2],
        )
    )
    rows.append(
        (
            "fee assessment interval",
            params["timing"]["fee_assessment_interval_days"] * SECONDS_PER["days"],
            ["FEE_ASSESSMENT_INTERVAL"],
            [],
        )
    )
    rows.append(
        (
            "venue timelock (EVM)",
            params["timing"]["venue_timelock_hours"]["evm"] * SECONDS_PER["hours"],
            ["VENUE_TIMELOCK_DELAY"],
            [],
        )
    )
    rows.append(
        (
            "venue timelock (Solana)",
            params["timing"]["venue_timelock_hours"]["solana"] * SECONDS_PER["hours"],
            [],
            ["DEFAULT_TIMELOCK_DELAY"],
        )
    )
    rows.append(
        (
            "max order lifetime",
            params["timing"]["max_order_lifetime_hours"] * SECONDS_PER["hours"],
            ["MAX_ORDER_LIFETIME"],
            [],
        )
    )
    rows.append(("max open orders", params["timing"]["max_open_orders"], ["MAX_OPEN_ORDERS"], []))
    rows.append(
        (
            "slash trader share",
            params["slashing"]["trader_share_bps"],
            params["slashing"]["solidity"],
            params["slashing"]["rust"],
        )
    )
    rows.append(("bps denominator", params["bps_denominator"], ["BPS"], ["BPS_DENOMINATOR"]))

    discount = params["bonding"]["agent_bond_discount"]
    rows.append(
        (
            "agent bond discount cap",
            discount["max_discount_bps"],
            discount.get("solidity", []),
            discount.get("rust", []),
        )
    )
    return rows


def check_constants(params: dict) -> list[str]:
    sol = parse_solidity((REPO / "src" / "libraries" / "Constants.sol").read_text())
    rust, origin = read_rust_source()
    print(f"  Anchor constants read from {origin}")

    problems: list[str] = []
    for label, expected, sol_names, rust_names in expectations(params):
        for name in sol_names:
            if name not in sol:
                problems.append(f"Constants.sol is missing {name} ({label}, expected {expected})")
            elif sol[name] != expected:
                problems.append(
                    f"Constants.sol {name} = {sol[name]}, expected {expected} ({label})"
                )
        for name in rust_names:
            if name not in rust:
                problems.append(f"constants.rs is missing {name} ({label}, expected {expected})")
            elif rust[name] != expected:
                problems.append(f"constants.rs {name} = {rust[name]}, expected {expected} ({label})")
    return problems


# ───────────────────────────────────────────────────────────── docs table


def render_docs_table(params: dict) -> str:
    bond = params["bonding"]
    lines = [
        BEGIN,
        "",
        "## Economics",
        "",
        "| Parameter | Launch value | Hard guardrail |",
        "|---|---|---|",
    ]

    def bps(n: int) -> str:
        return f"{n:,} bps ({n / 100:g}%)"

    labels = {
        "listing_fee_bps": "Listing fee",
        "performance_fee_bps": "Performance fee (above the high-water mark)",
        "builder_split_bps": "Builder share of the performance fee",
        "execution_fee_bps": "Execution fee (per trade, on notional)",
        "execution_builder_split_bps": "Builder share of the execution fee",
        "position_cap_bps": "Position cap",
        "max_drawdown_bps": "Max drawdown from the high-water mark",
    }
    for group in ("economics", "risk"):
        if group == "risk":
            lines += ["", "## Risk limits", "", "| Parameter | Launch value | Hard guardrail |", "|---|---|---|"]
        for key, spec in params[group].items():
            direction = "≤" if spec["guardrail_kind"] == "max" else "≥"
            lines.append(
                f"| {labels[key]} | {bps(spec['value'])} | {direction} {bps(spec['guardrail'])} |"
            )

    lines += [
        "",
        "## Bonding",
        "",
        f"Bonds are posted in **{bond['bond_token']}**. Ceilings are per *builder* across every",
        "listing they own, not per listing — a builder able to defraud across three agents is",
        "exposed for the total, not for each one separately. Tier 0 is unbonded and may hold no",
        "capital at all.",
        "",
        "| Tier | Bond | AUM ceiling |",
        "|---|---|---|",
    ]
    for i, (b, c) in enumerate(zip(bond["tier_bonds"], bond["tier_ceilings"]), start=1):
        lines.append(f"| {i} | ${b:,} | ${c:,} |")

    timing = params["timing"]
    slashing = params["slashing"]
    lines += [
        "",
        "## Timing and limits",
        "",
        "| Parameter | Value |",
        "|---|---|",
        f"| Unbonding period | {timing['unbond_period_days']['value']} days "
        f"(≤ {timing['unbond_period_days']['guardrail']} days) |",
        f"| Fee assessment interval | {timing['fee_assessment_interval_days']} days |",
        f"| Venue addition timelock | {timing['venue_timelock_hours']['evm']} h (EVM) · "
        f"{timing['venue_timelock_hours']['solana']} h (Solana governance) |",
        f"| Max order lifetime | {timing['max_order_lifetime_hours']} hour |",
        f"| Max open orders per vault | {timing['max_open_orders']} |",
        f"| Slash split | {slashing['trader_share_bps'] / 100:g}% harmed traders / "
        f"{slashing['buyback_share_bps'] / 100:g}% buyback pool |",
        "",
        END,
    ]
    return "\n".join(lines)


def check_docs(params: dict, write: bool) -> list[str]:
    if not DOCS_LOCAL.exists():
        return [
            f"{DOCS_LOCAL} does not exist. The docs are one of the three places these "
            f"numbers live; create the page (run with --write) rather than skipping it."
        ]

    text = DOCS_LOCAL.read_text()
    expected = render_docs_table(params)

    if BEGIN not in text or END not in text:
        return [f"{DOCS_LOCAL.name} has no generated block; run --write to insert one"]

    start, end = text.index(BEGIN), text.index(END) + len(END)
    current = text[start:end]
    if current == expected:
        return []
    if write:
        DOCS_LOCAL.write_text(text[:start] + expected + text[end:])
        print(f"  rewrote the generated table in {DOCS_LOCAL}")
        return []
    return [
        f"{DOCS_LOCAL.name}'s parameter table disagrees with parameters.json. "
        f"Run `python3 script/check-params.py --write` and commit the result."
    ]


# ───────────────────────────────────────────────────────────── entry point


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--write", action="store_true", help="regenerate the docs table in place")
    ap.add_argument(
        "--skip-docs",
        action="store_true",
        help="check only the two code implementations (for a checkout without mintlify-docs beside it)",
    )
    args = ap.parse_args()

    params = json.loads(PARAMS.read_text())
    print(f"Checking locked parameters against {PARAMS.relative_to(REPO)}")

    problems: list[str] = []
    try:
        problems += check_constants(params)
    except Drift as exc:
        problems.append(str(exc))

    if args.skip_docs or (not DOCS_LOCAL.exists() and not args.write):
        if not DOCS_LOCAL.exists():
            print(f"  skipping docs: no checkout at {DOCS_LOCAL}")
    else:
        problems += check_docs(params, args.write)

    for note in params.get("parity_exceptions", []):
        print(f"  known parity exception: {note['item']} — {note['reason'][:60]}…")

    if problems:
        print("\nParameter drift:\n")
        for p in problems:
            print(f"  ✗ {p}")
        print(
            "\nThese numbers must be identical in Solidity, Anchor and the docs. "
            "Fix the source, or change parameters.json if the parameter itself changed."
        )
        return 1

    print("\n✓ no drift")
    return 0


if __name__ == "__main__":
    sys.exit(main())
