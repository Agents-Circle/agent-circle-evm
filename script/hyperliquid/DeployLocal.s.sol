// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import { Script, console2 } from "forge-std/Script.sol";

import { AgentRegistry } from "../../src/AgentRegistry.sol";
import { IAgentRegistry } from "../../src/interfaces/IAgentRegistry.sol";
import { HLAgentVault } from "../../src/hyperliquid/HLAgentVault.sol";
import { HLAgentVaultFactory } from "../../src/hyperliquid/HLAgentVaultFactory.sol";
import { HLMarketWhitelist } from "../../src/hyperliquid/HLMarketWhitelist.sol";
import { Constants } from "../../src/libraries/Constants.sol";

interface IMockERC20 {
    function mint(address to, uint256 amount) external;
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

interface IMockMarginSummary {
    function set(address user, int64 accountValue) external;
}

interface IMockCoreWriter {
    function actionCount() external view returns (uint256);
}

/// Deploys the HyperEVM stack to a local chain and drives the journey against it.
///
/// A development harness, not a deployment path — `Deploy.s.sol` is the real one. The
/// value is proving the contracts work as **deployed bytecode against a live node**
/// rather than only inside the test EVM.
///
/// Requires `script/hyperliquid/install-local-core.sh` to have run first, because the
/// precompiles, the CoreWriter and the Core deposit wallet are chain features rather than
/// contracts this script can deploy. Run `make hl-deploy-local`, which does both in order.
contract DeployLocalHyperliquid is Script {
    address constant USDC = 0xb88339CB7199b77E23DB6E890353E22632Ba630f;
    address constant MARGIN_SUMMARY = 0x000000000000000000000000000000000000080F;
    address constant CORE_WRITER = 0x3333333333333333333333333333333333333333;

    uint64 constant USDC_CORE_INDEX = 0;
    uint256 constant UNIT = 1e6;
    uint32 constant BTC_PERP = 3;

    function run() external {
        uint256 pk = vm.envOr(
            "DEPLOYER_PRIVATE_KEY",
            uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80)
        );
        address deployer = vm.addr(pk);

        require(
            USDC.code.length > 0,
            "run script/hyperliquid/install-local-core.sh first: HyperCore is not installed"
        );

        vm.startBroadcast(pk);

        AgentRegistry registry = new AgentRegistry(
            deployer, // governance
            deployer, // guardian
            USDC, // bonds in USDC
            [uint256(2_500 * UNIT), 10_000 * UNIT, 40_000 * UNIT],
            [uint256(25_000 * UNIT), 150_000 * UNIT, 1_000_000 * UNIT],
            Constants.DEFAULT_UNBOND_PERIOD
        );
        HLMarketWhitelist whitelist =
            new HLMarketWhitelist(deployer, deployer, Constants.VENUE_TIMELOCK_DELAY);
        HLAgentVault implementation = new HLAgentVault(
            USDC, address(registry), address(whitelist), deployer, deployer, USDC_CORE_INDEX
        );
        HLAgentVaultFactory factory = new HLAgentVaultFactory(address(implementation));

        registry.setVaultFactory(address(factory));

        // Builder journey, all as the deployer for simplicity on a throwaway chain.
        IMockERC20(USDC).mint(deployer, 100_000 * UNIT);
        IMockERC20(USDC).approve(address(registry), type(uint256).max);
        registry.registerBuilder();
        registry.stakeBond(2_500 * UNIT);
        bytes32 listingId = registry.submitListing(deployer, keccak256("hl-strategy-v1"));
        registry.approveListingAtLaunchTerms(listingId);

        // The market needs the timelock. `vm.warp` does not move a live node's clock, so
        // this queues it and reports that it is pending rather than pretending otherwise.
        whitelist.queueAddition(BTC_PERP, 0);

        // Trader journey.
        address vault = factory.deployVault(listingId, 0, 0);
        IMockERC20(USDC).approve(vault, type(uint256).max);
        HLAgentVault(vault).deposit(uint64(10_000 * UNIT));

        // Core now reports the balance, which is what a settled bridge looks like.
        IMockMarginSummary(MARGIN_SUMMARY).set(vault, int64(uint64(10_000 * UNIT)));

        uint128[] memory none = new uint128[](0);
        HLAgentVault(vault).reconcile(none);

        vm.stopBroadcast();

        console2.log("AgentRegistry:      ", address(registry));
        console2.log("HLMarketWhitelist:  ", address(whitelist));
        console2.log("HLAgentVault impl:  ", address(implementation));
        console2.log("HLAgentVaultFactory:", address(factory));
        console2.log("vault (and its HyperCore account):", vault);
        console2.log("");
        console2.log("listing:        %s", vm.toString(listingId));
        console2.log("vault equity:   %s USDC", HLAgentVault(vault).equity() / UNIT);
        console2.log("high-water mark:%s USDC", HLAgentVault(vault).highWaterMark() / UNIT);
        console2.log("pending bridge: %s", HLAgentVault(vault).pendingBridge());
        console2.log("CoreWriter actions sent: %s", IMockCoreWriter(CORE_WRITER).actionCount());
        console2.log("");
        console2.log("BTC perps is QUEUED, not listed: the 2-day timelock has not run on a");
        console2.log("fresh chain. Orders will revert with VenueNotWhitelisted until it has.");
        console2.log("  cast rpc anvil_increaseTime 172800 && cast rpc anvil_mine");
        console2.log("  then: whitelist.executeAddition(3)");
        console2.log("");
        console2.log("HyperCore here is a mock. Nothing above says anything about whether");
        console2.log("Hyperliquid would accept these actions - see script/probes/README.md.");
    }
}
