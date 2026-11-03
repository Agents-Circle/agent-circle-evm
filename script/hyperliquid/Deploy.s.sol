// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import { Script, console2 } from "forge-std/Script.sol";

import { AgentRegistry } from "../../src/AgentRegistry.sol";
import { HLAgentVault } from "../../src/hyperliquid/HLAgentVault.sol";
import { HLAgentVaultFactory } from "../../src/hyperliquid/HLAgentVaultFactory.sol";
import { HLMarketWhitelist } from "../../src/hyperliquid/HLMarketWhitelist.sol";
import { Constants } from "../../src/libraries/Constants.sol";

/// Deploys the HyperEVM stack and wires it together.
///
/// `GOVERNANCE` must be a Safe multisig on mainnet. This script cannot tell a Safe from
/// an EOA, so that is on the operator — see README §6.
contract DeployHyperliquid is Script {
    /// USDC on HyperEVM. Chain-dependent, and the library resolves its own copy from
    /// `block.chainid`, so these must agree or deposits reach the wrong token.
    address constant MAINNET_USDC = 0xb88339CB7199b77E23DB6E890353E22632Ba630f;
    address constant TESTNET_USDC = 0x2B3370eE501B4a559b57D449569354196457D8Ab;

    uint64 constant USDC_CORE_INDEX = 0;
    uint256 constant UNIT = 1e6;

    uint256 constant HYPEREVM_MAINNET = 999;
    uint256 constant HYPEREVM_TESTNET = 998;

    function run()
        external
        returns (
            AgentRegistry registry,
            HLMarketWhitelist whitelist,
            HLAgentVault implementation,
            HLAgentVaultFactory factory
        )
    {
        address governance = vm.envAddress("GOVERNANCE");
        address guardian = vm.envAddress("GUARDIAN");
        address treasury = vm.envAddress("TREASURY");
        address platformBuilder = vm.envAddress("PLATFORM_BUILDER");

        // Resolved from the chain rather than taken from the environment, because the
        // library resolves its own USDC address the same way. A mismatch between the two
        // would send deposits to a token the bridge path does not use, and it would look
        // like the bridge silently failing.
        address usdc = block.chainid == HYPEREVM_TESTNET ? TESTNET_USDC : MAINNET_USDC;
        require(
            block.chainid == HYPEREVM_MAINNET || block.chainid == HYPEREVM_TESTNET,
            "not a HyperEVM chain: USDC and the deposit wallet would resolve to nothing"
        );

        // USDC bonds, at roughly 10% of the ceiling each tier unlocks.
        uint256[3] memory tierBonds = [uint256(2_500 * UNIT), 10_000 * UNIT, 40_000 * UNIT];
        uint256[3] memory tierCeilings = [uint256(25_000 * UNIT), 150_000 * UNIT, 1_000_000 * UNIT];

        vm.startBroadcast();

        registry = new AgentRegistry(
            governance,
            guardian,
            usdc, // bonds in USDC, not in a token the platform issues
            tierBonds,
            tierCeilings,
            Constants.DEFAULT_UNBOND_PERIOD
        );
        whitelist = new HLMarketWhitelist(governance, guardian, Constants.VENUE_TIMELOCK_DELAY);

        implementation = new HLAgentVault(
            usdc, address(registry), address(whitelist), treasury, platformBuilder, USDC_CORE_INDEX
        );
        factory = new HLAgentVaultFactory(address(implementation));

        vm.stopBroadcast();

        console2.log("chain id:        ", block.chainid);
        console2.log("USDC:            ", usdc);
        console2.log("AgentRegistry:   ", address(registry));
        console2.log("HLMarketWhitelist", address(whitelist));
        console2.log("HLAgentVault impl", address(implementation));
        console2.log("HLAgentVaultFactory", address(factory));
        console2.log("");
        console2.log("NOT YET USABLE. Two governance actions remain, both from GOVERNANCE:");
        console2.log("  1. registry.setVaultFactory(%s)  -- one-shot", address(factory));
        console2.log("  2. queue + execute a market on the whitelist (%s delay)", whitelist.delay());
        console2.log("");
        console2.log("Deposits will succeed before step 2. Orders will not.");
        console2.log("");
        console2.log("Large deploys need HyperEVM big blocks (1 min, 30M gas) rather than");
        console2.log("small blocks (1 s, 3M gas). If this reverted on gas, that is why.");
        console2.log("");
        console2.log("Unresolved: a vault needs HYPE on Core to bridge USDC back to the EVM.");
        console2.log("See ADR-0002 open question 4 and script/probes/README.md.");
    }
}
