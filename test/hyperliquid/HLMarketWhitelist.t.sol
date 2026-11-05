// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";

import { HLMarketWhitelist } from "../../src/hyperliquid/HLMarketWhitelist.sol";
import { CircleErrors } from "../../src/libraries/CircleErrors.sol";
import { Constants } from "../../src/libraries/Constants.sol";

/// The Drift lesson, encoded again — plus the part `VenueWhitelist` does not have.
///
/// On Polygon a venue is a contract and the question is binary. On HyperCore an asset is
/// an integer, and the assets differ enormously in how much size they can absorb: BTC
/// perps take a vault's full cap without noticing, while a HIP-3 equity perp or a HIP-4
/// outcome market may have a book so thin that 12% of a large vault *is* the book. So
/// each asset carries its own cap, and most of what is tested here is the asymmetry
/// around changing it.
contract HLMarketWhitelistTest is Test {
    HLMarketWhitelist wl;

    address governance = makeAddr("governance");
    address guardian = makeAddr("guardian");
    address attacker = makeAddr("attacker");

    uint32 constant BTC = 3;
    uint32 constant THIN = 77;

    uint64 constant DELAY = 2 days;

    function setUp() public {
        wl = new HLMarketWhitelist(governance, guardian, DELAY);
    }

    function _list(uint32 asset, uint16 cap) internal {
        vm.startPrank(governance);
        wl.queueAddition(asset, cap);
        vm.warp(block.timestamp + DELAY);
        wl.executeAddition(asset);
        vm.stopPrank();
    }

    // ───────────────────────────────────────── construction

    function test_constructorRejectsZeroAddresses() public {
        vm.expectRevert(CircleErrors.ZeroAddress.selector);
        new HLMarketWhitelist(address(0), guardian, DELAY);

        vm.expectRevert(CircleErrors.ZeroAddress.selector);
        new HLMarketWhitelist(governance, address(0), DELAY);
    }

    // ───────────────────────────────────────── the timelock

    function test_additionCannotSkipTheTimelock() public {
        vm.startPrank(governance);
        wl.queueAddition(BTC, 0);
        vm.expectRevert(CircleErrors.TimelockNotElapsed.selector);
        wl.executeAddition(BTC);
        vm.stopPrank();

        assertFalse(wl.isListed(BTC));
    }

    function test_additionSucceedsAfterTheDelay() public {
        _list(BTC, 0);
        assertTrue(wl.isListed(BTC));
    }

    function test_executeRequiresAQueuedProposal() public {
        vm.prank(governance);
        vm.expectRevert(CircleErrors.TimelockNotQueued.selector);
        wl.executeAddition(BTC);
    }

    /// A queue entry for asset 0 with a zero cap is still a real entry.
    ///
    /// Worth its own test because the struct's natural zero value is indistinguishable
    /// from "uncapped and queued", which is why `Queued` carries an explicit `exists`
    /// flag rather than inferring presence from `eta`.
    function test_assetZeroWithAZeroCapCanStillBeQueued() public {
        vm.startPrank(governance);
        wl.queueAddition(0, 0);
        vm.warp(block.timestamp + DELAY);
        wl.executeAddition(0);
        vm.stopPrank();

        assertTrue(wl.isListed(0));
    }

    function test_queuedCapIsBoundedByTheProtocolMaximum() public {
        vm.prank(governance);
        vm.expectRevert(CircleErrors.ParameterOutOfBounds.selector);
        wl.queueAddition(BTC, Constants.MAX_POSITION_CAP_BPS + 1);
    }

    /// A veto is permanent for that proposal. Governance cannot wait out the delay and
    /// execute anyway, or the guardian's objection would be a speed bump rather than a
    /// stop — and the whole asymmetry rests on it being a stop.
    function test_vetoedAdditionCannotExecuteEvenAfterTheDelay() public {
        vm.prank(governance);
        wl.queueAddition(BTC, 0);

        vm.prank(guardian);
        wl.vetoAddition(BTC);

        vm.warp(block.timestamp + DELAY + 1);
        vm.prank(governance);
        vm.expectRevert(CircleErrors.ProposalVetoed.selector);
        wl.executeAddition(BTC);

        assertFalse(wl.isListed(BTC));
    }

    function test_governanceMayVetoItsOwnProposal() public {
        vm.startPrank(governance);
        wl.queueAddition(BTC, 0);
        wl.vetoAddition(BTC);
        vm.warp(block.timestamp + DELAY + 1);
        vm.expectRevert(CircleErrors.ProposalVetoed.selector);
        wl.executeAddition(BTC);
        vm.stopPrank();
    }

    function test_cannotVetoSomethingNeverQueued() public {
        vm.prank(guardian);
        vm.expectRevert(CircleErrors.TimelockNotQueued.selector);
        wl.vetoAddition(BTC);
    }

    // ───────────────────────────────────────── authority

    function test_theGuardianCanNeverAdd() public {
        vm.startPrank(guardian);
        vm.expectRevert(CircleErrors.NotGovernance.selector);
        wl.queueAddition(BTC, 0);

        vm.expectRevert(CircleErrors.NotGovernance.selector);
        wl.executeAddition(BTC);
        vm.stopPrank();
    }

    function test_attackerCanDoNothing() public {
        vm.startPrank(attacker);
        vm.expectRevert(CircleErrors.NotGovernance.selector);
        wl.queueAddition(BTC, 0);

        vm.expectRevert(CircleErrors.NotGuardian.selector);
        wl.removeMarket(BTC);

        vm.expectRevert(CircleErrors.NotGuardian.selector);
        wl.vetoAddition(BTC);

        vm.expectRevert(CircleErrors.NotGuardian.selector);
        wl.tightenMarketCap(BTC, 100);

        vm.expectRevert(CircleErrors.NotGovernance.selector);
        wl.setGuardian(attacker);
        vm.stopPrank();
    }

    // ───────────────────────────────────────── removal

    /// No timelock on removal. Waiting out a delay to stop an active exploit is the wrong
    /// trade, and the guardian is the 3am path.
    function test_removalIsImmediateAndClearsAnyQueue() public {
        _list(BTC, 0);

        vm.prank(governance);
        wl.queueAddition(THIN, 300);

        vm.startPrank(guardian);
        wl.removeMarket(BTC);
        wl.removeMarket(THIN); // also wipes the pending queue entry
        vm.stopPrank();

        assertFalse(wl.isListed(BTC));

        // The queue entry is gone, so executing it now fails as never-queued rather than
        // silently listing a market the guardian just rejected.
        vm.warp(block.timestamp + DELAY + 1);
        vm.prank(governance);
        vm.expectRevert(CircleErrors.TimelockNotQueued.selector);
        wl.executeAddition(THIN);
    }

    function test_governanceMayAlsoRemove() public {
        _list(BTC, 0);
        vm.prank(governance);
        wl.removeMarket(BTC);
        assertFalse(wl.isListed(BTC));
    }

    /// Removing something never listed is a no-op rather than a revert. An emergency key
    /// that has to be right about current state before it can act is one that hesitates.
    function test_removingAnUnlistedMarketIsHarmless() public {
        vm.prank(guardian);
        wl.removeMarket(999);
    }

    // ───────────────────────────────────────── the per-asset cap

    function test_effectiveCapTakesTheStricterOfTheTwo() public {
        _list(BTC, 0); // uncapped asset
        _list(THIN, 300); // 3%

        // Uncapped asset: the vault's own cap governs.
        assertEq(wl.effectiveCapBps(BTC, 1_200), 1_200);

        // Capped asset: the asset's cap binds when it is tighter...
        assertEq(wl.effectiveCapBps(THIN, 1_200), 300);
        // ...and the vault's binds when *it* is tighter. A trader who tightened to 1%
        // must not be loosened to 3% by a market that happens to allow more.
        assertEq(wl.effectiveCapBps(THIN, 100), 100);
    }

    /// Zero for an unlisted asset, not a revert.
    ///
    /// The vault checks listing separately and with a named error. A cap read that
    /// reverted would make "not listed" and "cap exceeded" indistinguishable in a trace,
    /// which is the sort of thing that costs an hour during an incident.
    function test_effectiveCapIsZeroForAnUnlistedAsset() public view {
        assertEq(wl.effectiveCapBps(999, 1_200), 0);
    }

    function test_tighteningRequiresAListedMarket() public {
        vm.prank(governance);
        vm.expectRevert(CircleErrors.VenueNotWhitelisted.selector);
        wl.tightenMarketCap(BTC, 100);
    }

    /// Zero is rejected even though zero means "uncapped" in storage.
    ///
    /// Setting a listed market's cap to zero would *remove* its cap under the guise of
    /// tightening it — the one direction this function must not be able to go, and the
    /// bug a reader of the storage layout would most plausibly introduce.
    function test_tighteningToZeroIsRefused() public {
        _list(THIN, 300);
        vm.prank(guardian);
        vm.expectRevert(CircleErrors.ZeroAmount.selector);
        wl.tightenMarketCap(THIN, 0);
    }

    function test_tighteningOnlyGoesDown() public {
        _list(THIN, 300);

        vm.startPrank(guardian);
        wl.tightenMarketCap(THIN, 200);
        assertEq(wl.effectiveCapBps(THIN, 1_200), 200);

        // Equal is not tighter.
        vm.expectRevert(CircleErrors.RiskOverrideNotStricter.selector);
        wl.tightenMarketCap(THIN, 200);

        vm.expectRevert(CircleErrors.RiskOverrideNotStricter.selector);
        wl.tightenMarketCap(THIN, 300);
        vm.stopPrank();
    }

    /// An uncapped market may be given any valid cap in one step, because going from
    /// "no cap" to "some cap" is a reduction in what the vault may do however large the
    /// number is.
    function test_anUncappedMarketCanBeCappedInOneStep() public {
        _list(BTC, 0);

        vm.prank(guardian);
        wl.tightenMarketCap(BTC, Constants.MAX_POSITION_CAP_BPS);
        assertEq(wl.effectiveCapBps(BTC, 2_500), Constants.MAX_POSITION_CAP_BPS);
    }

    function test_tighteningIsStillBoundedByTheProtocolMaximum() public {
        _list(BTC, 0);
        vm.prank(guardian);
        vm.expectRevert(CircleErrors.ParameterOutOfBounds.selector);
        wl.tightenMarketCap(BTC, Constants.MAX_POSITION_CAP_BPS + 1);
    }

    /// Tightening has no delay while loosening has no function at all.
    ///
    /// The asymmetry is deliberate: a thin market discovered to be thinner than it looked
    /// must be fixable in one transaction, and a market discovered to be deeper than it
    /// looked can wait two days and go back through the timelock as a fresh addition.
    function test_loosingACapMeansGoingBackThroughTheTimelock() public {
        _list(THIN, 300);

        vm.prank(guardian);
        wl.tightenMarketCap(THIN, 100);

        // There is no `loosen`. The only route to a higher cap is re-queueing, which
        // takes the delay.
        vm.startPrank(governance);
        wl.queueAddition(THIN, 500);
        vm.expectRevert(CircleErrors.TimelockNotElapsed.selector);
        wl.executeAddition(THIN);

        vm.warp(block.timestamp + DELAY);
        wl.executeAddition(THIN);
        vm.stopPrank();

        assertEq(wl.effectiveCapBps(THIN, 1_200), 500);
    }

    // ───────────────────────────────────────── guardian rotation

    /// Deliberately immediate: a suspected-compromised guardian needs replacing faster
    /// than a timelock allows.
    function test_guardianRotationIsImmediate() public {
        address next = makeAddr("nextGuardian");
        vm.prank(governance);
        wl.setGuardian(next);

        assertEq(wl.guardian(), next);

        _list(BTC, 0);
        vm.prank(next);
        wl.removeMarket(BTC);
        assertFalse(wl.isListed(BTC));

        // And the old one is powerless at once.
        vm.prank(guardian);
        vm.expectRevert(CircleErrors.NotGuardian.selector);
        wl.removeMarket(BTC);
    }

    function test_guardianRotationRejectsZero() public {
        vm.prank(governance);
        vm.expectRevert(CircleErrors.ZeroAddress.selector);
        wl.setGuardian(address(0));
    }

    // ───────────────────────────────────────── property

    /// The effective cap is never looser than either input, whatever the pair.
    ///
    /// This is the invariant the vault relies on when it calls `effectiveCapBps` and
    /// trusts the answer without re-checking either side.
    function testFuzz_effectiveCapNeverExceedsEitherCap(uint16 assetCap, uint16 vaultCap) public {
        assetCap = uint16(bound(assetCap, 0, Constants.MAX_POSITION_CAP_BPS));
        vaultCap = uint16(bound(vaultCap, 1, Constants.MAX_POSITION_CAP_BPS));

        _list(BTC, assetCap);
        uint16 effective = wl.effectiveCapBps(BTC, vaultCap);

        assertLe(effective, vaultCap, "never looser than the trader's own limit");
        if (assetCap != 0) {
            assertLe(effective, assetCap, "never looser than the market's own limit");
        }
    }
}
