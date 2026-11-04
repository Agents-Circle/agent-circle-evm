#!/usr/bin/env python3
"""Switch an address to HyperEVM big blocks, and prove it took.

Not a tuning step — a prerequisite. The vault implementation alone costs 6.1M gas to
deploy and small blocks cap at 3M, so `make deploy-hl-testnet` cannot land without this.

`evmUserModify` is a HyperCore action rather than an EVM transaction, which has two
consequences, hit in this order:

  1. `cast` cannot send it. It is signed and posted to the exchange API.
  2. HyperCore refuses it from an address it has never seen. A fresh key holding HYPE on
     the EVM side is *not* a Core user. Send a little HYPE from that address to
     0x2222222222222222222222222222222222222222 first — that is the EVM to Core direction
     for HYPE — which creates the Core account. Only HYPE may be sent to that address.

The key is read from the environment and is never written anywhere.

    pip install hyperliquid-python-sdk
    DEPLOYER_PRIVATE_KEY=0x... python3 script/hyperliquid/enable_big_blocks.py
    DEPLOYER_PRIVATE_KEY=0x... python3 script/hyperliquid/enable_big_blocks.py --off
"""

import json
import os
import sys
import urllib.request

TESTNET_RPC = os.environ.get("HYPEREVM_TESTNET_RPC_URL", "https://rpc.hyperliquid-testnet.xyz/evm")


def using_big_blocks(address: str) -> object:
    """Ask the chain, rather than trusting the exchange API's reply."""
    payload = json.dumps(
        {"jsonrpc": "2.0", "id": 1, "method": "eth_usingBigBlocks", "params": [address]}
    ).encode()
    request = urllib.request.Request(
        TESTNET_RPC, data=payload, headers={"content-type": "application/json"}
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response).get("result")


def main() -> int:
    key = os.environ.get("DEPLOYER_PRIVATE_KEY")
    if not key:
        print("DEPLOYER_PRIVATE_KEY is not set.", file=sys.stderr)
        return 2

    try:
        from eth_account import Account
        from hyperliquid.exchange import Exchange
        from hyperliquid.utils import constants
    except ImportError:
        print("pip install hyperliquid-python-sdk", file=sys.stderr)
        return 2

    enable = "--off" not in sys.argv
    account = Account.from_key(key)
    address = account.address

    print(f"address: {address}")
    print(f"before:  usingBigBlocks = {using_big_blocks(address)}")

    exchange = Exchange(account, constants.TESTNET_API_URL)
    print(f"action:  {exchange.use_big_blocks(enable)}")

    after = using_big_blocks(address)
    print(f"after:   usingBigBlocks = {after}")

    # The exchange API can answer "ok" while the flag has not changed — most often because
    # the address is not a Core user yet. The chain is the authority, so fail on the chain.
    if after is not enable:
        print(
            "\nThe flag did not change. The usual cause is that this address is not a "
            "HyperCore user yet: send it some HYPE on Core first (see the docstring).",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
