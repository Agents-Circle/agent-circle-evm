// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import { Script, console2 } from "forge-std/Script.sol";

import { AgentRegistry } from "../../src/AgentRegistry.sol";
import { HLAgentVault } from "../../src/hyperliquid/HLAgentVault.sol";
import { HLAgentVaultFactory } from "../../src/hyperliquid/HLAgentVaultFactory.sol";
import { HLMarketWhitelist } from "../../src/hyperliquid/HLMarketWhitelist.sol";
import { Constants } from "../../src/libraries/Constants.sol";

/// Reads a deployed HyperEVM stack back from the chain and checks it against what we
/// meant to deploy. Run it after every deploy and before announcing any address.
///
/// It exists because most of what it checks **cannot be fixed afterwards**. Governance
/// is set in the registry's constructor with no setter, the treasury and builder-fee
/// addresses are immutables of the vault implementation, and `setVaultFactory` is
/// one-shot. A wrong value in any of them means redeploying the registry, which means
/// every builder re-bonds and every trader migrates. Reading them back costs nothing.
///
///     REGISTRY=0x… WHITELIST=0x… FACTORY=0x… \
///     GOVERNANCE=0x… GUARDIAN=0x… TREASURY=0x… PLATFORM_BUILDER=0x… \
///     forge script script/hyperliquid/VerifyDeploy.s.sol --rpc-url $RPC
///
/// It sends nothing. Every check is a read.
contract VerifyHyperliquidDeploy is Script {
    address constant MAINNET_USDC = 0xb88339CB7199b77E23DB6E890353E22632Ba630f;
    address constant TESTNET_USDC = 0x2B3370eE501B4a559b57D449569354196457D8Ab;
    uint256 constant HYPEREVM_MAINNET = 999;
    uint256 constant HYPEREVM_TESTNET = 998;
    uint256 constant UNIT = 1e6;

    /// Below this, a governance Safe is a single key with extra steps.
    uint256 constant MIN_SAFE_THRESHOLD = 2;

    struct Deployment {
        AgentRegistry registry;
        HLMarketWhitelist whitelist;
        HLAgentVaultFactory factory;
    }

    struct Expected {
        address governance;
        address guardian;
        address treasury;
        address platformBuilder;
        /// Testnet only: lets governance be an EOA. Never honoured on mainnet.
        bool allowEoaGovernance;
    }

    function run() external view {
        Deployment memory d = Deployment({
            registry: AgentRegistry(vm.envAddress("REGISTRY")),
            whitelist: HLMarketWhitelist(vm.envAddress("WHITELIST")),
            factory: HLAgentVaultFactory(vm.envAddress("FACTORY"))
        });
        Expected memory e = Expected({
            governance: vm.envAddress("GOVERNANCE"),
            guardian: vm.envAddress("GUARDIAN"),
            treasury: vm.envAddress("TREASURY"),
            platformBuilder: vm.envAddress("PLATFORM_BUILDER"),
            allowEoaGovernance: block.chainid != HYPEREVM_MAINNET
                && vm.envOr("ALLOW_EOA_GOVERNANCE", false)
        });

        string[] memory failures = check(d, e);
        if (failures.length == 0) {
            console2.log("OK: deployment matches every expectation.");
            return;
        }
        for (uint256 i; i < failures.length; ++i) {
            console2.log("FAIL:", failures[i]);
        }
        revert("deployment verification failed; see FAIL lines above");
    }

    /// Every failed expectation, in plain words. Empty means the deployment is right.
    function check(Deployment memory d, Expected memory e) public view returns (string[] memory) {
        string[] memory f = new string[](32);
        uint256 n;

        // ── who controls it
        if (e.governance == e.guardian) {
            f[n++] = "expected governance and guardian are the same address";
        }
        if (d.registry.governance() != e.governance) f[n++] = "registry governance mismatch";
        if (d.whitelist.governance() != e.governance) f[n++] = "whitelist governance mismatch";
        if (d.registry.guardian() != e.guardian) f[n++] = "registry guardian mismatch";
        if (d.whitelist.guardian() != e.guardian) f[n++] = "whitelist guardian mismatch";
        // Read from the chain too, not only compared with expectations: the guardian can
        // only shrink the attack surface, and that property is gone if it is governance.
        if (d.registry.governance() == d.registry.guardian()) {
            f[n++] = "registry guardian is governance";
        }
        if (d.whitelist.governance() == d.whitelist.guardian()) {
            f[n++] = "whitelist guardian is governance";
        }

        if (e.governance.code.length == 0) {
            if (!e.allowEoaGovernance) f[n++] = "governance has no code: not a Safe";
        } else {
            (bool ok, bytes memory ret) =
                e.governance.staticcall(abi.encodeWithSignature("getThreshold()"));
            if (!ok || ret.length < 32) {
                f[n++] = "governance does not answer getThreshold(): not a Safe";
            } else if (abi.decode(ret, (uint256)) < MIN_SAFE_THRESHOLD) {
                f[n++] = "governance Safe threshold below 2";
            }
        }

        // ── wiring
        if (d.registry.vaultFactory() != address(d.factory)) {
            f[n++] = "registry.vaultFactory is not FACTORY (one-shot: check before setting)";
        }
        HLAgentVault impl = HLAgentVault(d.factory.implementation());
        if (address(impl).code.length == 0) {
            f[n++] = "factory implementation has no code";
            return _trim(f, n);
        }
        if (address(impl.registry()) != address(d.registry)) {
            f[n++] = "implementation registry mismatch";
        }
        if (address(impl.whitelist()) != address(d.whitelist)) {
            f[n++] = "implementation whitelist mismatch";
        }
        if (impl.platformTreasury() != e.treasury) {
            f[n++] = "implementation treasury mismatch (immutable)";
        }
        if (impl.platformBuilder() != e.platformBuilder) {
            f[n++] = "implementation platformBuilder mismatch (immutable)";
        }
        if (e.treasury == address(0) || e.platformBuilder == address(0)) {
            f[n++] = "treasury or platformBuilder is the zero address";
        }

        // ── the token: bonds and vaults must both be the USDC the bridge path resolves
        if (block.chainid == HYPEREVM_MAINNET || block.chainid == HYPEREVM_TESTNET) {
            address usdc = block.chainid == HYPEREVM_TESTNET ? TESTNET_USDC : MAINNET_USDC;
            if (address(impl.usdc()) != usdc) f[n++] = "vault USDC is not this chain's USDC";
        }
        if (address(d.registry.bondToken()) != address(impl.usdc())) {
            f[n++] = "registry bonds and vaults use different tokens";
        }

        // ── locked parameters, read back against params/parameters.json
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/params/parameters.json"));
        uint256[] memory bonds = vm.parseJsonUintArray(json, ".bonding.tier_bonds");
        uint256[] memory ceilings = vm.parseJsonUintArray(json, ".bonding.tier_ceilings");
        for (uint256 i; i < 3; ++i) {
            if (d.registry.tierBonds(i) != bonds[i] * UNIT) {
                f[n++] = "tier bond differs from parameters.json";
            }
            if (d.registry.tierCeilings(i) != ceilings[i] * UNIT) {
                f[n++] = "tier ceiling differs from parameters.json";
            }
        }
        if (d.registry.unbondPeriod() != Constants.DEFAULT_UNBOND_PERIOD) {
            f[n++] = "unbond period is not the default";
        }
        if (d.whitelist.delay() != Constants.VENUE_TIMELOCK_DELAY) {
            f[n++] = "whitelist timelock is not the default";
        }
        if (d.registry.agentBondDiscountBps() != 0) f[n++] = "$AGENT bond discount is enabled";

        return _trim(f, n);
    }

    function _trim(string[] memory f, uint256 n) private pure returns (string[] memory out) {
        out = new string[](n);
        for (uint256 i; i < n; ++i) {
            out[i] = f[i];
        }
    }
}
