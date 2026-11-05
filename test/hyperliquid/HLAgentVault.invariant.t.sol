// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import { Test, console2 } from "forge-std/Test.sol";

import { AgentRegistry } from "../../src/AgentRegistry.sol";
import { HLAgentVault } from "../../src/hyperliquid/HLAgentVault.sol";
import { HLAgentVaultFactory } from "../../src/hyperliquid/HLAgentVaultFactory.sol";
import { HLMarketWhitelist } from "../../src/hyperliquid/HLMarketWhitelist.sol";
import { Constants } from "../../src/libraries/Constants.sol";
import { HighWaterMark } from "../../src/libraries/HighWaterMark.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import {
    MockCoreWriter,
    MockMarginSummary,
    MockPosition,
    MockMarkPx,
    MockTokenInfo,
    MockCoreDepositWallet
} from "./mocks/MockHyperCore.sol";

/// Drives one vault through arbitrary sequences of what its four kinds of caller can do:
/// the agent trading, the trader managing their money, the guardian pulling levers, and
/// HyperCore moving underneath all of them.
///
/// Every call is wrapped in try/catch. A revert is a legitimate answer for most of these
/// — an order over the cap *should* revert — so the handler records what succeeded and
/// the invariants check that what succeeded was allowed.
contract HLVaultHandler is Test {
    address constant POSITION_PRECOMPILE = 0x0000000000000000000000000000000000000800;
    address constant POSITION2_PRECOMPILE = 0x0000000000000000000000000000000000000813;
    address constant MARK_PX_PRECOMPILE = 0x0000000000000000000000000000000000000806;
    address constant MARGIN_SUMMARY_PRECOMPILE = 0x000000000000000000000000000000000000080F;

    uint256 constant UNIT = 1e6;
    uint64 constant DEPOSIT = 10_000 * 1e6;

    HLAgentVault public vault;
    AgentRegistry public registry;
    HLMarketWhitelist public whitelist;
    bytes32 public listingId;
    address public trader;
    address public agent;
    address public guardian;
    uint32[3] public assets;

    // ── ghosts
    uint128 public nextCloid = 1;
    uint128[] public cloids;

    /// A non-reduce-only order that was accepted although exposure plus reservations
    /// exceeded the asset's effective cap afterwards.
    uint256 public capBreaches;
    /// An order accepted while the vault was already at or past its drawdown limit.
    uint256 public drawdownBreaches;
    /// A cloid the vault had already seen that it booked a second time.
    uint256 public duplicatesAccepted;
    /// A performance fee accrued by an assessment that did not see equity above the mark.
    uint256 public feesWithoutGain;

    uint256 public placed;
    uint256 public assessed;

    constructor(
        HLAgentVault vault_,
        AgentRegistry registry_,
        HLMarketWhitelist whitelist_,
        bytes32 listingId_,
        address trader_,
        address agent_,
        address guardian_,
        uint32[3] memory assets_
    ) {
        vault = vault_;
        registry = registry_;
        whitelist = whitelist_;
        listingId = listingId_;
        trader = trader_;
        agent = agent_;
        guardian = guardian_;
        assets = assets_;
    }

    function cloidCount() external view returns (uint256) {
        return cloids.length;
    }

    function allCloids() external view returns (uint128[] memory) {
        return cloids;
    }

    // ───────────────────────────────────────── agent

    function placeOrder(
        uint8 assetSeed,
        bool isBuy,
        uint64 wholeSeed,
        uint8 pxSeed,
        bool reduceOnly
    ) external {
        uint32 asset = assets[assetSeed % 3];
        // $1 to $600 of worst-case cost at a $0.50–$2.00 limit, against a cap of about
        // $1,200 ($300 on the thin market) shared with positions and every reservation:
        // many orders pass, and the cap still regularly refuses. Both sides get exercised.
        uint64 limitPx = uint64(bound(pxSeed, 50, 200)) * 1e6; // CoreWriter 1e8 scale
        uint64 whole = uint64(bound(wholeSeed, 1, 600));
        uint64 sz = uint64((uint256(whole) * 1e10) / limitPx);
        if (sz == 0) return;

        uint64 equityBefore = vault.equity();
        uint64 hwm = vault.highWaterMark();
        uint128 cloid = nextCloid++;

        vm.prank(agent);
        try vault.placeOrder(asset, isBuy, limitPx, sz, reduceOnly, 1, cloid) {
            cloids.push(cloid);
            ++placed;

            uint256 dd = HighWaterMark.drawdownBps(
                HighWaterMark.State({ balance: equityBefore, highWaterMark: hwm })
            );
            if (dd >= vault.maxDrawdownBps()) ++drawdownBreaches;

            if (!reduceOnly) {
                uint16 cap = whitelist.effectiveCapBps(asset, vault.positionCapBps());
                uint256 exposure = uint256(vault.positionValue()) + vault.reserved();
                if (exposure * Constants.BPS > uint256(equityBefore) * cap) ++capBreaches;
            }
        } catch { }
    }

    /// Re-offer a cloid the vault has already seen. Every one of these must be refused.
    /// `placeOrder` above always mints a fresh cloid, so the fuzzer would never try a
    /// duplicate on its own - which is why one that slipped through on asset 0 reached
    /// `main`. A cloid stays here after it is cancelled, so released ones are re-offered
    /// too.
    function placeDuplicate(uint256 idx, bool reduceOnly) external {
        if (cloids.length == 0) return;
        uint128 cloid = cloids[idx % cloids.length];
        vm.prank(agent);
        try vault.placeOrder(assets[idx % 3], true, 1e8, 1e8, reduceOnly, 1, cloid) {
            ++duplicatesAccepted;
        } catch { }
    }

    function cancelOne(uint256 idx, bool asTrader) external {
        if (cloids.length == 0) return;
        uint128 cloid = cloids[idx % cloids.length];
        vm.prank(asTrader ? trader : agent);
        try vault.cancelOrder(cloid) { } catch { }
    }

    function exitPosition(uint8 assetSeed) external {
        vm.prank(agent);
        try vault.exitPosition(assets[assetSeed % 3]) { } catch { }
    }

    // ───────────────────────────────────────── trader

    function pause(uint8 seed) external {
        if (seed % 4 != 0) return;
        vm.prank(trader);
        vault.pause();
    }

    function resume() external {
        vm.prank(trader);
        vault.resume();
    }

    function requestWithdraw(uint64 seed) external {
        uint64 available = vault.availableToWithdraw();
        if (available == 0) return;
        uint64 amount = uint64(bound(seed, 1, available));
        vm.prank(trader);
        vault.requestWithdraw(amount); // must never revert when within available
    }

    // ───────────────────────────────────────── keeper and governance

    function reconcile() external {
        vault.reconcile(cloids);
    }

    function assessFees(uint32 extra) external {
        vm.warp(block.timestamp + Constants.FEE_ASSESSMENT_INTERVAL + bound(extra, 0, 1 days));

        uint64 equityBefore = vault.equity();
        uint64 hwm = vault.highWaterMark();
        uint64 builderBefore = vault.accruedBuilderFee();
        uint64 platformBefore = vault.accruedPlatformFee();

        try vault.assessFees() {
            ++assessed;
            bool accrued = vault.accruedBuilderFee() > builderBefore
                || vault.accruedPlatformFee() > platformBefore;
            if (accrued && equityBefore <= hwm) ++feesWithoutGain;
        } catch { }
    }

    /// Guardian levers that cannot be undone within a run (a suspended listing stays
    /// suspended) are not fuzzed here: one early call would leave the rest of the run
    /// with no trading to check. The escape-hatch invariant pulls them instead, from
    /// every reachable state, which is the stronger claim.

    // ───────────────────────────────────────── HyperCore moving underneath

    function warp(uint32 secs) external {
        vm.warp(block.timestamp + bound(secs, 1, 2 hours));
    }

    /// A random walk of up to 4% a step, so drawdown breaches happen the way they do in
    /// a market — accumulated — rather than in one jump that ends every run's trading.
    function moveEquity(int16 stepBps) external {
        int256 step = int256(bound(stepBps, -400, 400));
        int256 current = int256(uint256(vault.equity()));
        int256 next = current + (current * step) / 10_000;
        if (next < int256(1_000 * UNIT)) next = int256(1_000 * UNIT);
        MockMarginSummary(MARGIN_SUMMARY_PRECOMPILE).set(address(vault), int64(next));
    }

    /// A position of up to $400 either side at the $1 mark, in szDecimals = 2.
    function movePosition(uint8 assetSeed, int64 seed) external {
        uint32 asset = assets[assetSeed % 2];
        int64 szi = int64(bound(seed, -40_000, 40_000));
        MockPosition(POSITION_PRECOMPILE).set(address(vault), asset, szi);
        MockPosition(POSITION2_PRECOMPILE).set(address(vault), asset, szi);
    }

    function moveMark(uint8 assetSeed, uint64 seed) external {
        MockMarkPx(MARK_PX_PRECOMPILE).set(assets[assetSeed % 3], uint64(bound(seed, 5e3, 2e4)));
    }
}

/// Properties that must hold for the HyperEVM vault after any sequence of calls.
///
/// These restate the vault's guarantees as checks rather than examples: the unit tests
/// show each guard refusing the case someone thought of, and these show no sequence
/// anyone failed to think of gets past them. Run with `FOUNDRY_PROFILE=ci` for depth.
contract HLAgentVaultInvariantTest is Test {
    address constant CORE_WRITER = 0x3333333333333333333333333333333333333333;
    address constant POSITION_PRECOMPILE = 0x0000000000000000000000000000000000000800;
    address constant POSITION2_PRECOMPILE = 0x0000000000000000000000000000000000000813;
    address constant MARK_PX_PRECOMPILE = 0x0000000000000000000000000000000000000806;
    address constant MARGIN_SUMMARY_PRECOMPILE = 0x000000000000000000000000000000000000080F;
    address constant TOKEN_INFO_PRECOMPILE = 0x000000000000000000000000000000000000080C;

    uint256 constant HYPEREVM_MAINNET = 999;
    address constant USDC_EVM = 0xb88339CB7199b77E23DB6E890353E22632Ba630f;
    address constant CORE_DEPOSIT_WALLET = 0x6B9E773128f453f5c2C60935Ee2DE2CBc5390A24;

    uint256 constant UNIT = 1e6;
    uint32 constant SOL_PERP = 0; // asset index 0 on testnet - the one a zero-check misses
    uint32 constant BTC_PERP = 3;
    uint32 constant THIN_PERP = 77;

    address governance = makeAddr("governance");
    address guardian = makeAddr("guardian");
    address treasury = makeAddr("treasury");
    address builder = makeAddr("builder");
    address agent = makeAddr("agent");
    address trader = makeAddr("trader");

    AgentRegistry registry;
    HLMarketWhitelist whitelist;
    HLAgentVault vault;
    MockERC20 usdc;
    HLVaultHandler handler;

    function setUp() public {
        vm.etch(CORE_WRITER, address(new MockCoreWriter()).code);
        vm.etch(POSITION_PRECOMPILE, address(new MockPosition()).code);
        vm.etch(POSITION2_PRECOMPILE, address(new MockPosition()).code);
        vm.etch(MARK_PX_PRECOMPILE, address(new MockMarkPx()).code);
        vm.etch(MARGIN_SUMMARY_PRECOMPILE, address(new MockMarginSummary()).code);
        vm.etch(TOKEN_INFO_PRECOMPILE, address(new MockTokenInfo()).code);

        vm.chainId(HYPEREVM_MAINNET);
        vm.etch(CORE_DEPOSIT_WALLET, address(new MockCoreDepositWallet()).code);
        vm.etch(USDC_EVM, address(new MockERC20("USD Coin", "USDC", 6)).code);
        usdc = MockERC20(USDC_EVM);
        MockTokenInfo(TOKEN_INFO_PRECOMPILE).set(address(usdc), 6);
        MockCoreDepositWallet(CORE_DEPOSIT_WALLET).setToken(address(usdc));

        registry = new AgentRegistry(
            governance,
            guardian,
            address(usdc),
            [uint256(2_500 * UNIT), 10_000 * UNIT, 40_000 * UNIT],
            [uint256(25_000 * UNIT), 150_000 * UNIT, 1_000_000 * UNIT],
            Constants.DEFAULT_UNBOND_PERIOD
        );
        whitelist = new HLMarketWhitelist(governance, guardian, Constants.VENUE_TIMELOCK_DELAY);
        HLAgentVault implementation = new HLAgentVault(
            address(usdc), address(registry), address(whitelist), treasury, makeAddr("pb"), 0
        );
        HLAgentVaultFactory factory = new HLAgentVaultFactory(address(implementation));

        vm.prank(governance);
        registry.setVaultFactory(address(factory));

        usdc.mint(builder, 2_500 * UNIT);
        vm.startPrank(builder);
        usdc.approve(address(registry), type(uint256).max);
        registry.registerBuilder();
        registry.stakeBond(2_500 * UNIT);
        bytes32 listingId = registry.submitListing(agent, keccak256("hl-strategy"));
        vm.stopPrank();

        vm.startPrank(governance);
        registry.approveListingAtLaunchTerms(listingId);
        whitelist.queueAddition(SOL_PERP, 0); // index 0: a real asset, and the zero value
        whitelist.queueAddition(BTC_PERP, 0);
        whitelist.queueAddition(THIN_PERP, 300);
        vm.warp(block.timestamp + Constants.VENUE_TIMELOCK_DELAY);
        whitelist.executeAddition(SOL_PERP);
        whitelist.executeAddition(BTC_PERP);
        whitelist.executeAddition(THIN_PERP);
        vm.stopPrank();

        MockMarkPx(MARK_PX_PRECOMPILE).set(SOL_PERP, 1e4);
        MockMarkPx(MARK_PX_PRECOMPILE).set(BTC_PERP, 1e4);
        MockMarkPx(MARK_PX_PRECOMPILE).set(THIN_PERP, 1e4);

        vm.prank(trader);
        vault = HLAgentVault(factory.deployVault(listingId, 0, 0));
        usdc.mint(trader, 10_000 * UNIT);
        vm.startPrank(trader);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(uint64(10_000 * UNIT));
        vm.stopPrank();
        MockMarginSummary(MARGIN_SUMMARY_PRECOMPILE)
            .set(address(vault), int64(uint64(10_000 * UNIT)));
        vault.reconcile(new uint128[](0));

        handler = new HLVaultHandler(
            vault,
            registry,
            whitelist,
            listingId,
            trader,
            agent,
            guardian,
            [SOL_PERP, BTC_PERP, THIN_PERP]
        );
        targetContract(address(handler));
    }

    /// `reserved` is exactly the worst-case cost of the orders still outstanding, and
    /// `openOrders` is exactly how many there are. A drift in either direction is either
    /// trader capital locked by nothing, or exposure the cap no longer counts.
    function invariant_reservedMatchesOutstandingOrders() public view {
        uint128[] memory ids = handler.allCloids();
        uint256 sum;
        uint256 open;
        for (uint256 i; i < ids.length; ++i) {
            (, uint64 maxCost,, bool released) = vault.reservations(ids[i]);
            if (released) continue;
            sum += maxCost;
            ++open;
        }
        assertEq(vault.reserved(), sum, "reserved != sum of outstanding worst-case costs");
        assertEq(vault.openOrders(), open, "openOrders != outstanding reservations");
        assertLe(vault.openOrders(), Constants.MAX_OPEN_ORDERS, "open order bound exceeded");
    }

    /// Every accepted order left exposure plus reservations within the asset's effective
    /// cap. This is the aggregate reading the code implements today; if the cap is
    /// redefined per position, this invariant is the one to change with it.
    function invariant_acceptedOrdersWithinCap() public view {
        assertEq(handler.capBreaches(), 0, "an order was accepted over the position cap");
    }

    /// A cloid is used once and stays used. `_release` marks a reservation released
    /// without clearing it, and CoreWriter gives the vault no way to attribute fills, so
    /// a second order under the same cloid would make its reservation unaccountable.
    function invariant_cloidsAreNeverReused() public view {
        assertEq(handler.duplicatesAccepted(), 0, "a cloid was booked twice");
    }

    function invariant_noOrderPastDrawdownLimit() public view {
        assertEq(handler.drawdownBreaches(), 0, "an order was accepted past the drawdown limit");
    }

    /// High-water-mark accounting: no performance fee without equity above the mark.
    function invariant_feesOnlyAboveHighWaterMark() public view {
        assertEq(handler.feesWithoutGain(), 0, "performance fee accrued without a new high");
    }

    /// The agent's authority is to trade. It never ends up holding the trader's USDC.
    function invariant_agentNeverHoldsUsdc() public view {
        assertEq(usdc.balanceOf(agent), 0, "agent received USDC");
    }

    /// The escape hatch, from any reachable state: with the listing suspended and every
    /// market delisted, the trader alone clears every reservation in one transaction and
    /// can then request everything Core shows as available, whatever the vault's status.
    ///
    /// State-changing, so it runs inside a snapshot and leaves the fuzzed state as found.
    function invariant_traderCanAlwaysClearAndWithdraw() public {
        uint256 snap = vm.snapshotState();

        // The worst case for the trader: governance has suspended the listing and the
        // guardian has delisted every market the vault trades.
        vm.startPrank(guardian);
        registry.suspendListing(handler.listingId());
        whitelist.removeMarket(SOL_PERP);
        whitelist.removeMarket(BTC_PERP);
        whitelist.removeMarket(THIN_PERP);
        vm.stopPrank();

        uint128[] memory ids = handler.allCloids(); // before the prank, which it would consume
        vm.prank(trader);
        vault.cancelAll(ids);
        assertEq(vault.reserved(), 0, "cancelAll left capital reserved");
        assertEq(vault.openOrders(), 0, "cancelAll left orders open");

        uint64 available = vault.availableToWithdraw();
        assertEq(available, vault.equity(), "unreserved equity not fully withdrawable");
        if (available > 0) {
            vm.prank(trader);
            vault.requestWithdraw(available);
        }

        vm.revertToState(snap);
    }

    /// Prints how much real activity a run reached. `-vv` shows it; a run whose
    /// `placed` stays near zero is a handler problem, not a passing vault.
    function invariant_callSummary() public view {
        console2.log("orders accepted:", handler.placed(), "fee assessments:", handler.assessed());
        console2.log("open orders now:", vault.openOrders(), "reserved:", vault.reserved());
    }

    /// Guards against a handler that cannot reach the interesting states, which would
    /// make every invariant above pass vacuously. A per-run `afterInvariant` check is too
    /// strict for that — a run may legitimately suspend the listing on its first call —
    /// so this proves reachability once, deterministically.
    function test_handlerReachesOpenOrders() public {
        handler.placeOrder(0, true, 100, 100, false);
        handler.placeOrder(1, false, 50, 100, false);
        assertEq(handler.placed(), 2);
        assertGt(vault.reserved(), 0);
        invariant_reservedMatchesOutstandingOrders();
        invariant_traderCanAlwaysClearAndWithdraw();
    }

    /// The same guard for `placeDuplicate`, which returns early when no cloid has been
    /// placed yet and would otherwise make `invariant_cloidsAreNeverReused` vacuous.
    /// Reduce-only on asset index 0 is the combination that used to slip through, so it
    /// is the one asserted here.
    function test_handlerReachesDuplicateCloids() public {
        handler.placeOrder(0, true, 100, 100, true); // asset index 0, reduce-only
        assertEq(handler.placed(), 1);
        uint256 openBefore = vault.openOrders();

        handler.placeDuplicate(0, true);
        handler.placeDuplicate(0, false);

        assertEq(handler.duplicatesAccepted(), 0, "a duplicate cloid was accepted");
        assertEq(vault.openOrders(), openBefore, "a refused duplicate consumed a slot");
        invariant_cloidsAreNeverReused();
        invariant_reservedMatchesOutstandingOrders();
    }
}
