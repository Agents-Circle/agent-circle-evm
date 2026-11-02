// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";
import { AgentRegistry } from "../src/AgentRegistry.sol";
import { IAgentRegistry } from "../src/interfaces/IAgentRegistry.sol";
import { Errors } from "../src/libraries/Errors.sol";
import { Constants } from "../src/libraries/Constants.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";

contract AgentRegistryTest is Test {
    AgentRegistry registry;
    MockERC20 bond;

    address governance = makeAddr("governance");
    address guardian = makeAddr("guardian");
    address builder = makeAddr("builder");
    address agent = makeAddr("agent");
    address attacker = makeAddr("attacker");
    address vaultAddr = makeAddr("vault");
    address harmedTraders = makeAddr("harmedTraders");

    uint256 constant UNIT = 1e6;
    uint64 constant UNBOND = 14 days;

    function setUp() public {
        bond = new MockERC20("Agent", "AGENT", 6);

        registry = new AgentRegistry(
            governance,
            guardian,
            address(bond),
            [uint256(25_000 * UNIT), 100_000 * UNIT, 400_000 * UNIT],
            [uint256(25_000 * UNIT), 150_000 * UNIT, 1_000_000 * UNIT],
            UNBOND
        );

        vm.prank(governance);
        registry.setVault(vaultAddr);

        bond.mint(builder, 1_000_000 * UNIT);
        vm.prank(builder);
        bond.approve(address(registry), type(uint256).max);
    }

    function _registeredBuilder() internal returns (bytes32 id) {
        vm.startPrank(builder);
        registry.registerBuilder();
        registry.stakeBond(25_000 * UNIT);
        id = registry.submitListing(agent, keccak256("metadata"));
        vm.stopPrank();

        vm.prank(governance);
        registry.approveListingAtLaunchTerms(id);
    }

    // ─────────────────────────────────────── bonding

    function test_tierLaddersWithBond() public {
        vm.startPrank(builder);
        registry.registerBuilder();
        assertEq(registry.getBuilder(builder).tier, 0, "unbonded builder takes no capital");

        registry.stakeBond(25_000 * UNIT);
        assertEq(registry.getBuilder(builder).tier, 1);
        assertEq(registry.aumCeiling(builder), 25_000 * UNIT);

        registry.stakeBond(75_000 * UNIT);
        assertEq(registry.getBuilder(builder).tier, 2);
        assertEq(registry.aumCeiling(builder), 150_000 * UNIT);

        registry.stakeBond(300_000 * UNIT);
        assertEq(registry.getBuilder(builder).tier, 3);
        assertEq(registry.aumCeiling(builder), 1_000_000 * UNIT);
        vm.stopPrank();
    }

    function test_unbondRequiresWaitingPeriod() public {
        vm.startPrank(builder);
        registry.registerBuilder();
        registry.stakeBond(25_000 * UNIT);
        registry.requestUnbond(25_000 * UNIT);

        vm.expectRevert(Errors.UnbondPeriodNotElapsed.selector);
        registry.withdrawBond();

        vm.warp(block.timestamp + UNBOND);
        registry.withdrawBond();
        vm.stopPrank();

        assertEq(registry.getBuilder(builder).bondAmount, 0);
        assertEq(registry.getBuilder(builder).tier, 0);
    }

    /// The bond must keep covering capital under management. Traders exit first, then
    /// the builder unwinds — not the other way round.
    function test_cannotUnbondBelowAumCoverage() public {
        bytes32 id = _registeredBuilder();

        vm.prank(vaultAddr);
        registry.notifyAumDelta(id, int256(20_000 * UNIT));

        vm.startPrank(builder);
        registry.requestUnbond(25_000 * UNIT);
        vm.warp(block.timestamp + UNBOND);
        vm.expectRevert(Errors.BondBelowAumCoverage.selector);
        registry.withdrawBond();
        vm.stopPrank();

        // Traders leave, and now the same withdrawal is fine.
        vm.prank(vaultAddr);
        registry.notifyAumDelta(id, -int256(20_000 * UNIT));

        vm.prank(builder);
        registry.withdrawBond();
        assertEq(registry.getBuilder(builder).bondAmount, 0);
    }

    function test_slashRoutesMajorityToTraders() public {
        vm.startPrank(builder);
        registry.registerBuilder();
        registry.stakeBond(25_000 * UNIT);
        vm.stopPrank();

        vm.prank(governance);
        registry.slashBond(builder, 10_000 * UNIT, harmedTraders);

        assertEq(bond.balanceOf(harmedTraders), 7_000 * UNIT, "70% to harmed traders");
        assertEq(bond.balanceOf(governance), 3_000 * UNIT);
        assertEq(registry.getBuilder(builder).bondAmount, 15_000 * UNIT);
        assertEq(registry.getBuilder(builder).slashCount, 1);
    }

    function test_onlyGovernanceCanSlash() public {
        vm.prank(attacker);
        vm.expectRevert(Errors.NotGovernance.selector);
        registry.slashBond(builder, 1, harmedTraders);
    }

    // ─────────────────────────────────────── listings

    function test_listingCarriesNoEconomicsUntilApproved() public {
        vm.startPrank(builder);
        registry.registerBuilder();
        registry.stakeBond(25_000 * UNIT);
        bytes32 id = registry.submitListing(agent, keccak256("m"));
        vm.stopPrank();

        IAgentRegistry.Listing memory l = registry.getListing(id);
        assertEq(uint256(l.status), uint256(IAgentRegistry.ListingStatus.Vetting));
        assertEq(l.performanceFeeBps, 0, "a listing that never passes must never earn");
        assertEq(l.executionFeeBps, 0, "nor on turnover");

        vm.prank(governance);
        registry.approveListingAtLaunchTerms(id);

        l = registry.getListing(id);
        assertEq(uint256(l.status), uint256(IAgentRegistry.ListingStatus.Live));
        assertEq(l.performanceFeeBps, Constants.DEFAULT_PERFORMANCE_FEE_BPS);
        assertEq(l.builderSplitBps, Constants.DEFAULT_BUILDER_SPLIT_BPS);
        assertEq(l.executionFeeBps, Constants.DEFAULT_EXECUTION_FEE_BPS);
        assertEq(l.executionBuilderSplitBps, Constants.DEFAULT_EXECUTION_BUILDER_SPLIT_BPS);
        assertEq(l.positionCapBps, Constants.DEFAULT_POSITION_CAP_BPS);
        assertEq(l.maxDrawdownBps, Constants.DEFAULT_MAX_DRAWDOWN_BPS);
    }

    /// Launch terms, as a base for the guardrail tests to deviate from one field at a time.
    function _launchTerms() internal pure returns (IAgentRegistry.Terms memory) {
        return IAgentRegistry.Terms({
            performanceFeeBps: Constants.DEFAULT_PERFORMANCE_FEE_BPS,
            builderSplitBps: Constants.DEFAULT_BUILDER_SPLIT_BPS,
            executionFeeBps: Constants.DEFAULT_EXECUTION_FEE_BPS,
            executionBuilderSplitBps: Constants.DEFAULT_EXECUTION_BUILDER_SPLIT_BPS,
            positionCapBps: Constants.DEFAULT_POSITION_CAP_BPS,
            maxDrawdownBps: Constants.DEFAULT_MAX_DRAWDOWN_BPS
        });
    }

    /// A compromised multisig still cannot set a 100% performance fee.
    ///
    /// One field moved per case, from otherwise-valid launch terms, so a passing
    /// assertion names exactly which bound held rather than only that *something* did.
    function test_governanceCannotExceedGuardrails() public {
        vm.startPrank(builder);
        registry.registerBuilder();
        registry.stakeBond(25_000 * UNIT);
        bytes32 id = registry.submitListing(agent, keccak256("m"));
        vm.stopPrank();

        IAgentRegistry.Terms memory t;
        vm.startPrank(governance);

        t = _launchTerms();
        t.performanceFeeBps = 10_000; // 100% of profit
        vm.expectRevert(Errors.ParameterOutOfBounds.selector);
        registry.approveListing(id, t);

        t = _launchTerms();
        t.builderSplitBps = 1_000; // builder cut to 10%
        vm.expectRevert(Errors.ParameterOutOfBounds.selector);
        registry.approveListing(id, t);

        t = _launchTerms();
        t.executionFeeBps = Constants.MAX_EXECUTION_FEE_BPS + 1;
        vm.expectRevert(Errors.ParameterOutOfBounds.selector);
        registry.approveListing(id, t);

        t = _launchTerms();
        t.executionBuilderSplitBps = Constants.MIN_EXECUTION_BUILDER_SPLIT_BPS - 1;
        vm.expectRevert(Errors.ParameterOutOfBounds.selector);
        registry.approveListing(id, t);

        t = _launchTerms();
        t.executionBuilderSplitBps = 10_001; // over 100%
        vm.expectRevert(Errors.ParameterOutOfBounds.selector);
        registry.approveListing(id, t);

        t = _launchTerms();
        t.positionCapBps = 0;
        vm.expectRevert(Errors.ParameterOutOfBounds.selector);
        registry.approveListing(id, t);

        t = _launchTerms();
        t.positionCapBps = Constants.MAX_POSITION_CAP_BPS + 1;
        vm.expectRevert(Errors.ParameterOutOfBounds.selector);
        registry.approveListing(id, t);

        t = _launchTerms();
        t.maxDrawdownBps = 0;
        vm.expectRevert(Errors.ParameterOutOfBounds.selector);
        registry.approveListing(id, t);

        t = _launchTerms();
        t.maxDrawdownBps = Constants.MAX_DRAWDOWN_BPS_CEILING + 1;
        vm.expectRevert(Errors.ParameterOutOfBounds.selector);
        registry.approveListing(id, t);

        // The listing is still in Vetting after nine rejections, and launch terms work.
        registry.approveListing(id, _launchTerms());
        vm.stopPrank();

        assertEq(
            uint256(registry.getListing(id).status), uint256(IAgentRegistry.ListingStatus.Live)
        );
    }

    /// Zero execution fee is a coherent listing to approve, unlike a zero position cap.
    function test_zeroExecutionFeeIsAllowed() public {
        vm.startPrank(builder);
        registry.registerBuilder();
        registry.stakeBond(25_000 * UNIT);
        bytes32 id = registry.submitListing(agent, keccak256("m"));
        vm.stopPrank();

        IAgentRegistry.Terms memory t = _launchTerms();
        t.executionFeeBps = 0;

        vm.prank(governance);
        registry.approveListing(id, t);

        assertEq(registry.getListing(id).executionFeeBps, 0);
    }

    /// The $AGENT discount ships off, and off must mean "changes nothing".
    function test_bondDiscountIsDisabledAndInert() public {
        assertEq(registry.agentBondDiscountBps(), 0);
        assertEq(registry.requiredBond(1), registry.tierBonds(0));
        assertEq(registry.requiredBond(2), registry.tierBonds(1));
        assertEq(registry.requiredBond(3), registry.tierBonds(2));
        assertEq(registry.requiredBond(0), 0, "tier 0 requires nothing and unlocks nothing");
        assertEq(registry.requiredBond(4), 0, "no fourth tier");
    }

    /// Governance cannot discount the bond away. Half is the most the deterrent may give
    /// up, because the rest of it has to stay in an asset the platform cannot print.
    function test_bondDiscountIsCappedAtHalf() public {
        vm.prank(governance);
        vm.expectRevert(Errors.ParameterOutOfBounds.selector);
        registry.setAgentBondDiscount(Constants.MAX_AGENT_BOND_DISCOUNT_BPS + 1);

        vm.prank(governance);
        registry.setAgentBondDiscount(Constants.MAX_AGENT_BOND_DISCOUNT_BPS);
        assertEq(registry.requiredBond(1), registry.tierBonds(0) / 2);
    }

    function test_onlyGovernanceCanSetBondDiscount() public {
        vm.prank(builder);
        vm.expectRevert(Errors.NotGovernance.selector);
        registry.setAgentBondDiscount(1_000);
    }

    /// Enabling the discount hands back collateral that is backing live capital — but it
    /// must not let a builder drop below the tier covering their AUM. The discount
    /// changes what a tier costs, never what it covers.
    function test_discountDoesNotLetBuilderUnderCoverLiveAum() public {
        bytes32 id = _registeredBuilder();

        vm.prank(vaultAddr);
        registry.notifyAumDelta(id, int256(20_000 * UNIT));

        vm.prank(governance);
        registry.setAgentBondDiscount(Constants.MAX_AGENT_BOND_DISCOUNT_BPS);

        // Tier still covers the AUM, so the builder keeps it...
        assertEq(registry.getBuilder(builder).tier, 1);
        assertEq(registry.aumCeiling(builder), 25_000 * UNIT);

        // ...and still cannot withdraw to a tier that would not.
        vm.startPrank(builder);
        registry.requestUnbond(registry.getBuilder(builder).bondAmount);
        vm.warp(block.timestamp + 15 days);
        vm.expectRevert(Errors.BondBelowAumCoverage.selector);
        registry.withdrawBond();
        vm.stopPrank();
    }

    function test_attackerCannotApproveOwnListing() public {
        vm.startPrank(builder);
        registry.registerBuilder();
        registry.stakeBond(25_000 * UNIT);
        bytes32 id = registry.submitListing(agent, keccak256("m"));

        vm.expectRevert(Errors.NotGovernance.selector);
        registry.approveListingAtLaunchTerms(id);
        vm.stopPrank();
    }

    function test_guardianCanSuspendButNotApprove() public {
        bytes32 id = _registeredBuilder();

        vm.prank(guardian);
        registry.suspendListing(id);
        assertEq(
            uint256(registry.getListing(id).status), uint256(IAgentRegistry.ListingStatus.Suspended)
        );
    }

    function test_builderCanRotateCompromisedAgentKey() public {
        bytes32 id = _registeredBuilder();
        address newAgent = makeAddr("newAgent");

        vm.prank(attacker);
        vm.expectRevert(Errors.NotBuilder.selector);
        registry.setAgentAuthority(id, attacker);

        vm.prank(builder);
        registry.setAgentAuthority(id, newAgent);
        assertEq(registry.getListing(id).agentAuthority, newAgent);
    }

    // ─────────────────────────────────────── AUM

    function test_aumCeilingIsPerBuilderNotPerListing() public {
        vm.startPrank(builder);
        registry.registerBuilder();
        registry.stakeBond(25_000 * UNIT); // tier 1 → 25k ceiling
        bytes32 a = registry.submitListing(agent, keccak256("a"));
        bytes32 b = registry.submitListing(agent, keccak256("b"));
        vm.stopPrank();

        vm.startPrank(governance);
        registry.approveListingAtLaunchTerms(a);
        registry.approveListingAtLaunchTerms(b);
        vm.stopPrank();

        vm.startPrank(vaultAddr);
        registry.notifyAumDelta(a, int256(20_000 * UNIT));

        // Second listing shares the same ceiling — only 5k of headroom is left.
        assertEq(registry.availableAumHeadroom(b), 5_000 * UNIT);
        vm.expectRevert(Errors.AumCeilingExceeded.selector);
        registry.notifyAumDelta(b, int256(10_000 * UNIT));
        vm.stopPrank();
    }

    function test_onlyVaultCanMoveAum() public {
        bytes32 id = _registeredBuilder();
        vm.prank(attacker);
        vm.expectRevert(Errors.NotVault.selector);
        registry.notifyAumDelta(id, int256(1_000 * UNIT));
    }

    /// A compromised governance key must not be able to point the registry at a
    /// contract that mints headroom out of nothing.
    function test_vaultIsSetOnce() public {
        vm.prank(governance);
        vm.expectRevert(Errors.AlreadySet.selector);
        registry.setVault(attacker);
    }
}
