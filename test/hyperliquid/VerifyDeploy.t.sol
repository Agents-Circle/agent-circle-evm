// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";

import { AgentRegistry } from "../../src/AgentRegistry.sol";
import { HLAgentVault } from "../../src/hyperliquid/HLAgentVault.sol";
import { HLAgentVaultFactory } from "../../src/hyperliquid/HLAgentVaultFactory.sol";
import { HLMarketWhitelist } from "../../src/hyperliquid/HLMarketWhitelist.sol";
import { Constants } from "../../src/libraries/Constants.sol";
import { VerifyHyperliquidDeploy } from "../../script/hyperliquid/VerifyDeploy.s.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";

/// Answers the one Safe call the verifier makes.
contract MockSafe {
    uint256 public getThreshold;

    constructor(uint256 threshold) {
        getThreshold = threshold;
    }
}

/// The verifier is only worth running if it actually refuses the deployments it claims
/// to refuse. Each test here builds one specific wrong deployment and checks the
/// verifier names it.
contract VerifyDeployTest is Test {
    uint256 constant HYPEREVM_MAINNET = 999;
    address constant USDC_EVM = 0xb88339CB7199b77E23DB6E890353E22632Ba630f;
    uint256 constant UNIT = 1e6;

    VerifyHyperliquidDeploy verifier;
    address governance;
    address guardian = makeAddr("guardian");
    address treasury = makeAddr("treasury");
    address platformBuilder = makeAddr("platformBuilder");

    function setUp() public {
        vm.chainId(HYPEREVM_MAINNET);
        vm.etch(USDC_EVM, address(new MockERC20("USD Coin", "USDC", 6)).code);
        governance = address(new MockSafe(3));
        verifier = new VerifyHyperliquidDeploy();
    }

    function _deploy(address gov, address guard, address treasury_, bool wireFactory)
        internal
        returns (VerifyHyperliquidDeploy.Deployment memory d)
    {
        AgentRegistry registry = new AgentRegistry(
            gov,
            guard,
            USDC_EVM,
            [uint256(2_500 * UNIT), 10_000 * UNIT, 40_000 * UNIT],
            [uint256(25_000 * UNIT), 150_000 * UNIT, 1_000_000 * UNIT],
            Constants.DEFAULT_UNBOND_PERIOD
        );
        HLMarketWhitelist whitelist =
            new HLMarketWhitelist(gov, guard, Constants.VENUE_TIMELOCK_DELAY);
        HLAgentVault impl = new HLAgentVault(
            USDC_EVM, address(registry), address(whitelist), treasury_, platformBuilder, 0
        );
        HLAgentVaultFactory factory = new HLAgentVaultFactory(address(impl));
        if (wireFactory) {
            vm.prank(gov);
            registry.setVaultFactory(address(factory));
        }
        d = VerifyHyperliquidDeploy.Deployment(registry, whitelist, factory);
    }

    function _expected() internal view returns (VerifyHyperliquidDeploy.Expected memory) {
        return
            VerifyHyperliquidDeploy.Expected(governance, guardian, treasury, platformBuilder, false);
    }

    function _assertNames(string[] memory failures, string memory want) internal pure {
        for (uint256 i; i < failures.length; ++i) {
            if (keccak256(bytes(failures[i])) == keccak256(bytes(want))) return;
        }
        revert(string.concat("verifier did not report: ", want));
    }

    function test_correctDeploymentPasses() public {
        string[] memory failures =
            verifier.check(_deploy(governance, guardian, treasury, true), _expected());
        assertEq(failures.length, 0);
    }

    function test_refusesGuardianEqualToGovernance() public {
        VerifyHyperliquidDeploy.Deployment memory d =
            _deploy(governance, governance, treasury, true);
        VerifyHyperliquidDeploy.Expected memory e = _expected();
        e.guardian = governance;
        string[] memory failures = verifier.check(d, e);
        _assertNames(failures, "registry guardian is governance");
        _assertNames(failures, "whitelist guardian is governance");
    }

    function test_refusesEoaGovernanceOnMainnet() public {
        address eoa = makeAddr("eoaGovernance");
        VerifyHyperliquidDeploy.Expected memory e = _expected();
        e.governance = eoa;
        e.allowEoaGovernance = false;
        _assertNames(
            verifier.check(_deploy(eoa, guardian, treasury, true), e),
            "governance has no code: not a Safe"
        );
    }

    function test_refusesSingleSignerSafe() public {
        address weak = address(new MockSafe(1));
        VerifyHyperliquidDeploy.Expected memory e = _expected();
        e.governance = weak;
        _assertNames(
            verifier.check(_deploy(weak, guardian, treasury, true), e),
            "governance Safe threshold below 2"
        );
    }

    function test_refusesUnwiredFactory() public {
        _assertNames(
            verifier.check(_deploy(governance, guardian, treasury, false), _expected()),
            "registry.vaultFactory is not FACTORY (one-shot: check before setting)"
        );
    }

    function test_refusesWrongImmutableTreasury() public {
        _assertNames(
            verifier.check(_deploy(governance, guardian, makeAddr("typo"), true), _expected()),
            "implementation treasury mismatch (immutable)"
        );
    }
}
