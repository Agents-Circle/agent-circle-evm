// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import { Script, console2 } from "forge-std/Script.sol";

import { AgentRegistry } from "../../src/AgentRegistry.sol";
import { HLAgentVault } from "../../src/hyperliquid/HLAgentVault.sol";
import { HLAgentVaultFactory } from "../../src/hyperliquid/HLAgentVaultFactory.sol";
import { HLMarketWhitelist } from "../../src/hyperliquid/HLMarketWhitelist.sol";
import { PrecompileLib } from "@hyper-evm-lib/src/PrecompileLib.sol";

/// Testnet probes. **Testnet only** — see `script/probes/README.md` before running.
///
/// Each function answers one question the test suite cannot, because the answer is a
/// fact about HyperCore rather than about this code. They are separate entry points on
/// purpose: a probe that does six things and reverts tells you almost nothing, and these
/// are being run precisely because nobody knows what they will do.
///
/// Every one of them prints what it observed rather than asserting. An assertion encodes
/// an expectation, and having an expectation is the thing we are trying to fix.
contract TestnetProbe is Script {
    uint256 constant HYPEREVM_TESTNET = 998;
    uint32 constant BTC_PERP = 3;
    uint256 constant UNIT = 1e6;

    modifier testnetOnly() {
        require(block.chainid == HYPEREVM_TESTNET, "probes run on HyperEVM testnet only");
        _;
    }

    function _vault() internal view returns (HLAgentVault) {
        return HLAgentVault(vm.envAddress("VAULT"));
    }

    // ───────────────────────────────── 1. does equity read at all?

    /// The cheapest possible probe, and the right first one.
    ///
    /// If the margin-summary precompile does not answer for a freshly created contract
    /// account, nothing else in this file can work and the vault's drawdown check is
    /// reading zeros. Worth five seconds before spending real USDC.
    function probeReads() external view testnetOnly {
        address v = address(_vault());
        console2.log("vault:            ", v);
        console2.log("core user exists: ", PrecompileLib.coreUserExists(v));
        console2.log("equity (1e6):     ", _vault().equity());
        console2.log("BTC mark:         ", PrecompileLib.markPx(BTC_PERP));
        console2.log("BTC szi:          ", PrecompileLib.position(v, BTC_PERP).szi);
        console2.log("L1 block:         ", PrecompileLib.l1BlockNumber());
        console2.log("");
        console2.log("An equity of 0 after a settled deposit means the margin summary is");
        console2.log("not answering for this account - stop here and find out why.");
    }

    // ───────────────────────────────── 2. the HYPE question

    /// Question 2 in the README, and the one that qualifies the headline guarantee.
    ///
    /// `sendAsset` for a non-HYPE token is documented as needing HYPE on Core for gas. If
    /// that is true, a vault that has never held HYPE cannot complete a withdrawal
    /// bridge — and "withdrawal always succeeds" is false in exactly the case nobody
    /// tests.
    ///
    /// Run this on a vault holding **zero** HYPE. Record whether the USDC arrives.
    function probeWithdrawWithoutHype() external testnetOnly {
        HLAgentVault v = _vault();
        uint64 amount = uint64(vm.envOr("AMOUNT", uint256(1 * UNIT)));

        console2.log("HYPE on core (spot, token 1105):");
        console2.log("  ", PrecompileLib.spotBalance(address(v), 1105).total);
        console2.log("equity before:", v.equity());

        vm.startBroadcast();
        v.requestWithdraw(amount);
        vm.stopBroadcast();

        console2.log("");
        console2.log("requestWithdraw accepted on the EVM. That proves nothing: the");
        console2.log("Core->EVM leg is fire-and-forget like everything else.");
        console2.log("");
        console2.log("Wait, then check the vault's EVM USDC balance and call");
        console2.log("finalizeWithdraw. If the balance never moves, the bridge needs HYPE");
        console2.log("and ADR-0002 open question 4 is answered 'yes'. Then bisect the");
        console2.log("minimum that works - the figure is not documented anywhere.");
    }

    // ───────────────────────────────── 3. fire-and-forget, seen once

    /// Place an order with a deliberately wrong tick size.
    ///
    /// The EVM transaction should succeed and the order should never exist on Core. The
    /// entire reservation and reconcile design rests on this being true, and it is worth
    /// seeing once rather than trusting a sentence in the docs.
    function probeBadTickIsSilentlyDropped() external testnetOnly {
        HLAgentVault v = _vault();

        // A price with more precision than BTC's tick allows.
        uint64 absurdPx = 100_000_123_456;
        uint64 tinySz = 1_000; // 0.00001 at 1e8

        console2.log("reserved before:", v.reserved());
        console2.log("open orders:    ", v.openOrders());

        vm.startBroadcast();
        v.placeOrder(BTC_PERP, true, absurdPx, tinySz, false, 2, uint128(block.timestamp));
        vm.stopBroadcast();

        console2.log("reserved after: ", v.reserved());
        console2.log("open orders:    ", v.openOrders());
        console2.log("");
        console2.log("If this transaction succeeded, check the L1 explorer for the order.");
        console2.log("No order, with a successful transaction and a live reservation, is");
        console2.log("fire-and-forget demonstrated. The reservation should then clear by");
        console2.log("itself an hour later via reconcile, with no keeper involved.");
    }

    // ───────────────────────────────── 4. the CoreWriter delay

    /// Place a real minimum-size IOC order and report what the vault believes.
    ///
    /// The order should appear **twice** in the L1 explorer — enqueued, then executed.
    /// That is the delay, visible, and it is why vault mode cannot carry a builder code
    /// and fast mode exists.
    function probePlaceAndReconcile() external testnetOnly {
        HLAgentVault v = _vault();
        uint64 limitPx = uint64(vm.envUint("LIMIT_PX"));
        uint64 sz = uint64(vm.envUint("SZ"));
        uint128 cloid = uint128(block.timestamp);

        vm.startBroadcast();
        v.placeOrder(BTC_PERP, true, limitPx, sz, false, 3, cloid);
        vm.stopBroadcast();

        console2.log("cloid:          ", cloid);
        console2.log("reserved:       ", v.reserved());
        console2.log("szi now:        ", PrecompileLib.position(address(v), BTC_PERP).szi);
        console2.log("");
        console2.log("Wait for the fill, then run probeReconcile. The execution fee");
        console2.log("accrued should match the FILLED notional at 2 bps, not the");
        console2.log("requested one. If they differ, the fee is being charged on the");
        console2.log("wrong quantity and that is a trader-facing bug.");
    }

    function probeReconcile() external testnetOnly {
        HLAgentVault v = _vault();
        uint128[] memory stale = new uint128[](0);

        uint64 builderBefore = v.accruedBuilderFee();

        vm.startBroadcast();
        v.reconcile(stale);
        vm.stopBroadcast();

        console2.log("equity:            ", v.equity());
        console2.log("high-water mark:   ", v.highWaterMark());
        console2.log("szi:               ", PrecompileLib.position(address(v), BTC_PERP).szi);
        console2.log("builder fee before:", builderBefore);
        console2.log("builder fee after: ", v.accruedBuilderFee());
    }

    // ───────────────────────────────── 5. fast mode and the builder code

    /// Question 1 in the README, and the one that gates fast-mode revenue.
    ///
    /// `enableFastMode` sends `setAbstraction(1)` on the reading that "standard" mode is
    /// the absence of abstraction — action 16 offers `1 = disabled, 2 = unifiedAccount,
    /// 3 = portfolioMargin` and nothing named standard. If that reading is wrong, fast
    /// mode looks like it works and earns nothing, silently.
    function probeEnableFastMode() external testnetOnly {
        HLAgentVault v = _vault();
        address apiWallet = vm.envAddress("API_WALLET");

        vm.startBroadcast();
        v.enableFastMode(apiWallet);
        vm.stopBroadcast();

        console2.log("api wallet:", v.apiWallet());
        console2.log("");
        console2.log("Now, off-chain and outside this script:");
        console2.log("  1. Sign an order with the API wallet, carrying a builder field.");
        console2.log("  2. Check `maxBuilderFee` for the vault and the platform builder.");
        console2.log("  3. Check the `referral` info request for the builder address.");
        console2.log("");
        console2.log("A fill with no builder fee accrued means setAbstraction(1) is NOT");
        console2.log("standard mode. That is the answer to ADR-0002 question 2, and it");
        console2.log("means fast mode earns nothing until it is fixed.");
    }

    /// Question 3: does re-adding an API wallet under the same name revoke the old key?
    function probeReplaceApiWallet() external testnetOnly {
        HLAgentVault v = _vault();
        address replacement = vm.envAddress("API_WALLET_2");

        vm.startBroadcast();
        v.enableFastMode(replacement);
        vm.stopBroadcast();

        console2.log("api wallet now:", v.apiWallet());
        console2.log("");
        console2.log("Sign an order with the OLD key. If it is rejected, re-adding under");
        console2.log("the same name revokes. If it is accepted, the kill switch cannot");
        console2.log("rely on revocation - which is why disableFastMode pauses and closes");
        console2.log("instead of relying on it.");
    }
}
