// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import { Script, console2 } from "forge-std/Script.sol";
import { AgentRegistry } from "../src/AgentRegistry.sol";
import { AgentVault } from "../src/AgentVault.sol";
import { VenueWhitelist } from "../src/VenueWhitelist.sol";
import { Constants } from "../src/libraries/Constants.sol";

/// Deploys the three contracts and wires them together.
///
/// `GOVERNANCE` must be a Safe multisig on mainnet. This script does not enforce that —
/// it cannot tell a Safe from an EOA — so it is on the operator. See README §6.
contract Deploy is Script {
    /// USDC.e on Polygon PoS.
    address constant POLYGON_USDC = 0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174;

    uint256 constant UNIT = 1e6;

    function run() external returns (AgentRegistry registry, AgentVault vault, VenueWhitelist wl) {
        address quote = vm.envOr("QUOTE_TOKEN", POLYGON_USDC);
        // Bonds are posted in USDC, not in a token the platform issues: a bond
        // denominated in $AGENT is a bond whose value the platform controls, and the
        // deterrent is only as real as the collateral. Still configurable, because the
        // quote and bond tokens differ per chain.
        address bondToken = vm.envOr("BOND_TOKEN", quote);
        address governance = vm.envAddress("GOVERNANCE");
        address guardian = vm.envAddress("GUARDIAN");
        address treasury = vm.envAddress("TREASURY");

        // USDC. Roughly 10% of the ceiling each tier unlocks — below that the bond is
        // theatre, and a builder who can defraud $25k for a $2.5k stake will.
        uint256[3] memory tierBonds = [uint256(2_500 * UNIT), 10_000 * UNIT, 40_000 * UNIT];
        uint256[3] memory tierCeilings = [uint256(25_000 * UNIT), 150_000 * UNIT, 1_000_000 * UNIT];

        vm.startBroadcast();

        registry = new AgentRegistry(
            governance,
            guardian,
            bondToken,
            tierBonds,
            tierCeilings,
            Constants.DEFAULT_UNBOND_PERIOD
        );
        wl = new VenueWhitelist(governance, guardian, Constants.VENUE_TIMELOCK_DELAY);
        vault = new AgentVault(quote, address(registry), address(wl), treasury);

        vm.stopBroadcast();

        console2.log("AgentRegistry: ", address(registry));
        console2.log("VenueWhitelist:", address(wl));
        console2.log("AgentVault:    ", address(vault));
        console2.log("");
        console2.log("NOT YET USABLE. Two governance actions remain, both from GOVERNANCE:");
        console2.log("  1. registry.setVault(%s)  -- one-shot, cannot be changed", address(vault));
        console2.log("  2. queue + execute a venue on the whitelist (%s delay)", wl.delay());
        console2.log("");
        console2.log("Deposits will succeed before step 2. Trades will not.");
    }
}
