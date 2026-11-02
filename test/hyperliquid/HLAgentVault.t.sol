// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";

import { AgentRegistry } from "../../src/AgentRegistry.sol";
import { IAgentRegistry } from "../../src/interfaces/IAgentRegistry.sol";
import { HLAgentVault } from "../../src/hyperliquid/HLAgentVault.sol";
import { HLAgentVaultFactory } from "../../src/hyperliquid/HLAgentVaultFactory.sol";
import { HLMarketWhitelist } from "../../src/hyperliquid/HLMarketWhitelist.sol";
import { Errors } from "../../src/libraries/Errors.sol";
import { Constants } from "../../src/libraries/Constants.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import {
    MockCoreWriter,
    MockMarginSummary,
    MockPosition,
    MockMarkPx,
    MockTokenInfo,
    MockCoreDepositWallet
} from "./mocks/MockHyperCore.sol";

/// The HyperEVM vault against a controllable HyperCore.
///
/// The mocks are etched at the real precompile and CoreWriter addresses, so the vault
/// under test is the production contract calling production library code at production
/// addresses. `test/hyperliquid/mocks/MockHyperCore.sol` explains why these rather than
/// hyper-evm-lib's own simulator — the short version is that the simulator needs solc
/// ^0.8.28 and cannot model an action being silently dropped, which is the behaviour this
/// vault is built around.
contract HLAgentVaultTest is Test {
    address constant CORE_WRITER = 0x3333333333333333333333333333333333333333;
    address constant POSITION_PRECOMPILE = 0x0000000000000000000000000000000000000800;
    /// `PrecompileLib.position` reads POSITION2 at 0x813, not the older 0x800. Both are
    /// etched: the vault only uses the library's accessor, but a future read of the
    /// original would otherwise fail in a way that looks like a logic bug.
    address constant POSITION2_PRECOMPILE = 0x0000000000000000000000000000000000000813;
    address constant MARK_PX_PRECOMPILE = 0x0000000000000000000000000000000000000806;
    address constant MARGIN_SUMMARY_PRECOMPILE = 0x000000000000000000000000000000000000080F;
    address constant TOKEN_INFO_PRECOMPILE = 0x000000000000000000000000000000000000080C;

    /// Mainnet HyperEVM. `HLConstants` resolves USDC and the deposit wallet from
    /// `block.chainid`, so the tests run as the chain the vault will be deployed to
    /// rather than at Foundry's default 31337, where those lookups point nowhere.
    uint256 constant HYPEREVM_MAINNET = 999;
    address constant USDC_EVM = 0xb88339CB7199b77E23DB6E890353E22632Ba630f;
    address constant CORE_DEPOSIT_WALLET = 0x6B9E773128f453f5c2C60935Ee2DE2CBc5390A24;

    AgentRegistry registry;
    HLMarketWhitelist whitelist;
    HLAgentVaultFactory factory;
    HLAgentVault implementation;
    MockERC20 usdc;

    address governance = makeAddr("governance");
    address guardian = makeAddr("guardian");
    address treasury = makeAddr("treasury");
    address builderFeeAccount = makeAddr("builderFeeAccount");
    address builder = makeAddr("builder");
    address agent = makeAddr("agent");
    address trader = makeAddr("trader");
    address otherTrader = makeAddr("otherTrader");
    address attacker = makeAddr("attacker");

    uint256 constant UNIT = 1e6;
    uint32 constant BTC_PERP = 3;
    uint32 constant THIN_PERP = 77; // stands in for a thin HIP-3 / HIP-4 market
    uint64 constant USDC_CORE_INDEX = 0;

    bytes32 listingId;
    HLAgentVault vault;

    function setUp() public {
        // Etch the mocks at the addresses the production library calls. `vm.etch` copies
        // code, not storage, so each etched instance has its own fresh storage at that
        // address — which is why the setters below are called *on the precompile
        // address* rather than on the contract that was deployed to create the code.
        vm.etch(CORE_WRITER, address(new MockCoreWriter()).code);
        vm.etch(POSITION_PRECOMPILE, address(new MockPosition()).code);
        vm.etch(POSITION2_PRECOMPILE, address(new MockPosition()).code);
        vm.etch(MARK_PX_PRECOMPILE, address(new MockMarkPx()).code);
        vm.etch(MARGIN_SUMMARY_PRECOMPILE, address(new MockMarginSummary()).code);
        vm.etch(TOKEN_INFO_PRECOMPILE, address(new MockTokenInfo()).code);

        vm.chainId(HYPEREVM_MAINNET);
        vm.etch(CORE_DEPOSIT_WALLET, address(new MockCoreDepositWallet()).code);
        // USDC has to live at the address HLConstants resolves, because the library's
        // USDC bridge path uses that address rather than one the vault passes in.
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

        implementation = new HLAgentVault(
            address(usdc),
            address(registry),
            address(whitelist),
            treasury,
            builderFeeAccount,
            USDC_CORE_INDEX
        );
        factory = new HLAgentVaultFactory(address(implementation));

        vm.prank(governance);
        registry.setVaultFactory(address(factory));

        usdc.mint(builder, 2_500 * UNIT);
        vm.startPrank(builder);
        usdc.approve(address(registry), type(uint256).max);
        registry.registerBuilder();
        registry.stakeBond(2_500 * UNIT);
        listingId = registry.submitListing(agent, keccak256("hl-strategy"));
        vm.stopPrank();

        vm.startPrank(governance);
        registry.approveListingAtLaunchTerms(listingId);
        whitelist.queueAddition(BTC_PERP, 0); // deep market, no asset-specific cap
        whitelist.queueAddition(THIN_PERP, 300); // thin market, 3%
        vm.warp(block.timestamp + Constants.VENUE_TIMELOCK_DELAY);
        whitelist.executeAddition(BTC_PERP);
        whitelist.executeAddition(THIN_PERP);
        vm.stopPrank();

        // Units matter here and are easy to get wrong, so they are stated once.
        //
        // HyperCore splits six decimals between size and price: `szi` carries
        // `szDecimals` and `markPx` carries `6 - szDecimals`, so `szi * markPx` is
        // already USDC at 1e6 with no scaling factor. These tests use szDecimals = 2,
        // which makes a $1 mark `1e4` and a position of N units `N * 100`.
        _setMark(BTC_PERP, 1e4);
        _setMark(THIN_PERP, 1e4);

        vault = _openVault(trader, 10_000);
    }

    // ─────────────────────────────────────── helpers

    function _setMark(uint32 perp, uint64 px) internal {
        MockMarkPx(MARK_PX_PRECOMPILE).set(perp, px);
    }

    function _setEquity(address who, uint256 whole) internal {
        MockMarginSummary(MARGIN_SUMMARY_PRECOMPILE).set(who, int64(uint64(whole * UNIT)));
    }

    function _setPosition(address who, uint32 perp, int64 szi) internal {
        MockPosition(POSITION_PRECOMPILE).set(who, perp, szi);
        MockPosition(POSITION2_PRECOMPILE).set(who, perp, szi);
    }

    function _openVault(address who, uint256 whole) internal returns (HLAgentVault v) {
        vm.prank(who);
        v = HLAgentVault(factory.deployVault(listingId, 0, 0));

        usdc.mint(who, whole * UNIT);
        vm.startPrank(who);
        usdc.approve(address(v), type(uint256).max);
        v.deposit(uint64(whole * UNIT));
        vm.stopPrank();

        // Core now reports the money. The bridge is asynchronous, so the vault only
        // learns this at reconcile; the two-hop deposit has its own test below.
        _setEquity(address(v), whole);
        return v;
    }

    function _coreWriter() internal pure returns (MockCoreWriter) {
        return MockCoreWriter(CORE_WRITER);
    }

    /// Order size, in CoreWriter's 1e8 scale, worth `whole` USDC at a $1 limit price.
    ///
    /// `maxCost` is `sz * limitPx / 1e10`, so with `limitPx = 1e8` ($1) this gives
    /// exactly `whole` USDC.
    function _size(uint256 whole) internal pure returns (uint64) {
        return uint64(whole * 1e8);
    }

    /// A position size worth `whole` USDC at the $1 mark set above, in `szDecimals = 2`.
    function _sziWorth(uint256 whole) internal pure returns (int64) {
        return int64(uint64(whole * 100));
    }

    // ─────────────────────────────────────── provenance and isolation

    function test_onlyFactoryChildrenCanMoveAum() public {
        assertTrue(factory.isVault(address(vault)));
        assertFalse(factory.isVault(attacker));

        vm.prank(attacker);
        vm.expectRevert(Errors.NotVault.selector);
        registry.notifyAumDelta(listingId, int256(1_000_000 * UNIT));
    }

    function test_vaultFactoryIsOneShot() public {
        vm.prank(governance);
        vm.expectRevert(Errors.AlreadySet.selector);
        registry.setVaultFactory(attacker);
    }

    function test_oneTraderCannotOpenTwoVaultsAgainstOneListing() public {
        vm.prank(trader);
        vm.expectRevert(Errors.VaultAlreadyExists.selector);
        factory.deployVault(listingId, 0, 0);
    }

    function test_predictedAddressMatchesTheDeployedOne() public {
        address predicted = factory.predictVault(otherTrader, listingId);
        vm.prank(otherTrader);
        assertEq(factory.deployVault(listingId, 0, 0), predicted);
    }

    /// The clone-topology version of the isolation test ADR-0001 asks for.
    ///
    /// Under the singleton this proved per-vault `idle` bookkeeping held. Here the
    /// property is structural — each vault is its own address and therefore its own
    /// HyperCore account, so there is no shared pot to mis-attribute. Still worth
    /// testing: structural guarantees are the ones nobody checks until somebody changes
    /// the structure.
    function test_clonesCannotTouchEachOthersBalances() public {
        HLAgentVault other = _openVault(otherTrader, 5_000);

        assertTrue(address(other) != address(vault));
        assertEq(vault.equity(), 10_000 * UNIT);
        assertEq(other.equity(), 5_000 * UNIT);

        vm.prank(otherTrader);
        vm.expectRevert(Errors.NotTrader.selector);
        vault.requestWithdraw(uint64(1 * UNIT));

        vm.prank(trader);
        vm.expectRevert(Errors.NotTrader.selector);
        other.requestWithdraw(uint64(1 * UNIT));

        vm.prank(trader);
        vault.requestWithdraw(uint64(1_000 * UNIT));
        assertEq(other.equity(), 5_000 * UNIT, "untouched");
        assertEq(other.pendingWithdrawal(), 0);
    }

    function test_implementationCannotBeInitialised() public {
        vm.expectRevert();
        implementation.initialize(attacker, listingId, 0, 0);
    }

    // ─────────────────────────────────────── deposits are asynchronous

    function test_depositIsPendingUntilCoreShowsIt() public {
        HLAgentVault v;
        vm.prank(otherTrader);
        v = HLAgentVault(factory.deployVault(listingId, 0, 0));

        usdc.mint(otherTrader, 1_000 * UNIT);
        vm.startPrank(otherTrader);
        usdc.approve(address(v), type(uint256).max);
        v.deposit(uint64(1_000 * UNIT));
        vm.stopPrank();

        // Core has not credited it yet. The vault says so rather than pretending.
        assertEq(v.pendingBridge(), 1_000 * UNIT);
        assertEq(v.equity(), 0);
        // The mark rose with the deposit all the same, or the trader would be charged a
        // performance fee on their own money the moment it arrived.
        assertEq(v.highWaterMark(), 1_000 * UNIT);

        _setEquity(address(v), 1_000);
        uint128[] memory none = new uint128[](0);
        v.reconcile(none);

        assertEq(v.pendingBridge(), 0, "settled");
        assertEq(v.equity(), 1_000 * UNIT);
    }

    /// Bridged USDC lands in spot, so the class transfer to perp is not optional: without
    /// it every perp order is dropped with no error anywhere.
    function test_depositSendsBothHops() public {
        HLAgentVault v;
        vm.prank(otherTrader);
        v = HLAgentVault(factory.deployVault(listingId, 0, 0));

        uint256 before = _coreWriter().actionCount();

        usdc.mint(otherTrader, 1_000 * UNIT);
        vm.startPrank(otherTrader);
        usdc.approve(address(v), type(uint256).max);
        v.deposit(uint64(1_000 * UNIT));
        vm.stopPrank();

        // A bridge (a spot send to the system address) and a USD class transfer.
        assertEq(_coreWriter().actionCount(), before + 1, "class transfer reached CoreWriter");
        assertEq(_coreWriter().actionIdAt(before), 7, "action 7: USD class transfer");
    }

    // ─────────────────────────────────────── order authorisation

    function test_onlyTheAgentCanPlaceOrders() public {
        vm.prank(attacker);
        vm.expectRevert(Errors.NotAgentAuthority.selector);
        vault.placeOrder(BTC_PERP, true, 1e8, _size(1), false, 2, 1);

        vm.prank(trader);
        vm.expectRevert(Errors.NotAgentAuthority.selector);
        vault.placeOrder(BTC_PERP, true, 1e8, _size(1), false, 2, 1);
    }

    function test_orderRefusedOnAnUnlistedAsset() public {
        vm.prank(agent);
        vm.expectRevert(Errors.VenueNotWhitelisted.selector);
        vault.placeOrder(999, true, 1e8, _size(1), false, 2, 1);
    }

    function test_orderRefusedWhilePausedAndWhileSuspended() public {
        vm.prank(trader);
        vault.pause();
        vm.prank(agent);
        vm.expectRevert(Errors.VaultNotActive.selector);
        vault.placeOrder(BTC_PERP, true, 1e8, _size(1), false, 2, 1);

        vm.prank(trader);
        vault.resume();

        vm.prank(guardian);
        registry.suspendListing(listingId);
        vm.prank(agent);
        vm.expectRevert(Errors.ListingNotLive.selector);
        vault.placeOrder(BTC_PERP, true, 1e8, _size(1), false, 2, 1);
    }

    function test_orderReachesCoreWriterAsActionOne() public {
        uint256 before = _coreWriter().actionCount();
        vm.prank(agent);
        vault.placeOrder(BTC_PERP, true, 1e8, _size(100), false, 2, 1);

        assertEq(_coreWriter().actionCount(), before + 1);
        assertEq(_coreWriter().actionIdAt(before), 1, "action 1: limit order");
    }

    /// The reservation is what makes the cap hold across several orders.
    ///
    /// 12% of 10,000 is 1,200. Three 500-USDC orders each pass the cap alone and breach
    /// it together, which is the entire reason worst-case cost is booked up front rather
    /// than measured afterwards.
    function test_reservationsAccumulateAgainstTheCap() public {
        vm.startPrank(agent);
        vault.placeOrder(BTC_PERP, true, 1e8, _size(500), false, 2, 1);
        assertEq(vault.reserved(), 500 * UNIT, "worst case booked immediately");

        vault.placeOrder(BTC_PERP, true, 1e8, _size(500), false, 2, 2);
        assertEq(vault.reserved(), 1_000 * UNIT);

        vm.expectRevert(Errors.PositionCapExceeded.selector);
        vault.placeOrder(BTC_PERP, true, 1e8, _size(500), false, 2, 3);
        vm.stopPrank();
    }

    /// An existing position counts against the cap alongside the reservations.
    function test_openPositionCountsTowardsTheCap() public {
        // 1,000 of position plus a 500 order is 1,500 against a 1,200 cap.
        _setPosition(address(vault), BTC_PERP, _sziWorth(1_000));

        vm.prank(agent);
        vm.expectRevert(Errors.PositionCapExceeded.selector);
        vault.placeOrder(BTC_PERP, true, 1e8, _size(500), false, 2, 1);
    }

    function test_maxOpenOrdersIsEnforced() public {
        vm.startPrank(agent);
        for (uint128 i = 1; i <= Constants.MAX_OPEN_ORDERS; ++i) {
            vault.placeOrder(BTC_PERP, true, 1e8, _size(1), false, 2, i);
        }
        vm.expectRevert(Errors.TooManyOpenOrders.selector);
        vault.placeOrder(BTC_PERP, true, 1e8, _size(1), false, 2, 99);
        vm.stopPrank();
    }

    function test_duplicateCloidIsRefused() public {
        vm.startPrank(agent);
        vault.placeOrder(BTC_PERP, true, 1e8, _size(1), false, 2, 7);
        vm.expectRevert(Errors.OrderAlreadyExists.selector);
        vault.placeOrder(BTC_PERP, true, 1e8, _size(1), false, 2, 7);
        vm.stopPrank();
    }

    /// A thin market's own cap binds even when the trader's is looser.
    function test_thinMarketCapBindsBeforeTheVaultCap() public {
        // 3% of 10,000 is 300: 500 is inside the vault's 12% and outside the asset's 3%.
        vm.prank(agent);
        vm.expectRevert(Errors.PositionCapExceeded.selector);
        vault.placeOrder(THIN_PERP, true, 1e8, _size(500), false, 2, 1);

        vm.prank(agent);
        vault.placeOrder(THIN_PERP, true, 1e8, _size(200), false, 2, 2);
        assertEq(vault.reserved(), 200 * UNIT);
    }

    function test_reduceOnlyOrdersSkipTheCap() public {
        vm.startPrank(agent);
        vault.placeOrder(BTC_PERP, true, 1e8, _size(1_000), false, 2, 1);
        // Accepted even at the cap: it can only lower exposure, and a vault at its cap is
        // exactly the one that must be able to reduce.
        vault.placeOrder(BTC_PERP, false, 1e8, _size(1_000), true, 3, 2);
        vm.stopPrank();

        assertEq(vault.openOrders(), 2);
        assertEq(vault.reserved(), 1_000 * UNIT, "reduce-only reserves nothing");
    }

    // ─────────────────────────────────────── fire-and-forget

    /// The case the whole design exists for.
    ///
    /// CoreWriter accepted the action at the EVM level and HyperCore discarded it. The
    /// vault believes it has an open order; Core will never report a fill or a cancel.
    /// Without expiry the reservation would hold the trader's capital for ever on the
    /// strength of an order that never existed.
    function test_silentlyDroppedOrderDoesNotStrandCapital() public {
        _coreWriter().setDropNextAction(true);

        vm.prank(agent);
        vault.placeOrder(BTC_PERP, true, 1e8, _size(500), false, 2, 1);

        // The vault reserved against an order Core never received, and cannot know.
        assertEq(vault.reserved(), 500 * UNIT);
        assertEq(vault.openOrders(), 1);

        uint128[] memory cloids = new uint128[](1);
        cloids[0] = 1;

        // Not released early: an order may yet fill, and guessing would be worse.
        vault.reconcile(cloids);
        assertEq(vault.reserved(), 500 * UNIT, "not released before expiry");

        vm.warp(block.timestamp + Constants.MAX_ORDER_LIFETIME + 1);
        vault.reconcile(cloids);

        assertEq(vault.reserved(), 0, "expiry is the backstop");
        assertEq(vault.openOrders(), 0);
    }

    /// And the trader never has to wait for the keeper to get their money back.
    function test_traderCanClearADroppedOrderImmediately() public {
        _coreWriter().setDropNextAction(true);
        vm.prank(agent);
        vault.placeOrder(BTC_PERP, true, 1e8, _size(500), false, 2, 1);

        uint128[] memory cloids = new uint128[](1);
        cloids[0] = 1;
        vm.prank(trader);
        vault.cancelAll(cloids);

        assertEq(vault.reserved(), 0);
    }

    // ─────────────────────────────────────── reconcile

    function test_reconcileIsPermissionless() public {
        uint128[] memory none = new uint128[](0);
        vm.prank(attacker);
        vault.reconcile(none);
    }

    function test_reconcileRaisesTheMarkAndNeverLowersIt() public {
        uint128[] memory none = new uint128[](0);
        assertEq(vault.highWaterMark(), 10_000 * UNIT);

        _setEquity(address(vault), 12_000);
        vault.reconcile(none);
        assertEq(vault.highWaterMark(), 12_000 * UNIT);

        _setEquity(address(vault), 11_000);
        vault.reconcile(none);
        assertEq(vault.highWaterMark(), 12_000 * UNIT, "a mark that falls is not a mark");
    }

    function test_drawdownBreachAutoPausesAndSendsCloses() public {
        uint128[] memory none = new uint128[](0);
        _setPosition(address(vault), BTC_PERP, _sziWorth(100));

        // Track the asset so reconcile knows to close it.
        vm.prank(agent);
        vault.placeOrder(BTC_PERP, true, 1e8, _size(100), false, 2, 1);

        uint256 before = _coreWriter().actionCount();
        _setEquity(address(vault), 8_400); // 16% down from 10,000
        vault.reconcile(none);

        assertEq(uint256(vault.status()), uint256(HLAgentVault.VaultStatus.Paused));
        assertGt(_coreWriter().actionCount(), before, "a reduce-only close was sent");

        vm.prank(agent);
        vm.expectRevert(Errors.VaultNotActive.selector);
        vault.placeOrder(BTC_PERP, true, 1e8, _size(1), false, 2, 2);
    }

    function test_orderRefusedWhenAlreadyPastTheDrawdownLimit() public {
        _setEquity(address(vault), 8_400);
        vm.prank(agent);
        vm.expectRevert(Errors.DrawdownLimitBreached.selector);
        vault.placeOrder(BTC_PERP, true, 1e8, _size(1), false, 2, 1);
    }

    // ─────────────────────────────────────── execution fee

    /// Charged on size that moved, not size that was requested.
    function test_executionFeeChargesObservedFillsOnly() public {
        uint128[] memory none = new uint128[](0);

        vm.prank(agent);
        vault.placeOrder(BTC_PERP, true, 1e8, _size(1_000), false, 2, 1);

        // Nothing has filled yet, so nothing is owed — even though 1,000 was requested.
        vault.reconcile(none);
        assertEq(vault.accruedBuilderFee(), 0, "a request is not a fill");
        assertEq(vault.accruedPlatformFee(), 0);

        // 1,000 of size appears. 2 bps of 1,000 USDC is 0.2 USDC, split 50/50.
        _setPosition(address(vault), BTC_PERP, _sziWorth(1_000));
        vault.reconcile(none);

        assertEq(vault.accruedBuilderFee(), 100_000, "0.1 USDC");
        assertEq(vault.accruedPlatformFee(), 100_000, "0.1 USDC");
    }

    /// Closing is a fill too: the fee is on turnover, in both directions.
    function test_executionFeeChargesTheCloseAsWell() public {
        uint128[] memory none = new uint128[](0);
        vm.prank(agent);
        vault.placeOrder(BTC_PERP, true, 1e8, _size(1_000), false, 2, 1);

        _setPosition(address(vault), BTC_PERP, _sziWorth(1_000));
        vault.reconcile(none);
        uint64 afterOpen = vault.accruedBuilderFee();

        _setPosition(address(vault), BTC_PERP, 0);
        vault.reconcile(none);

        assertEq(vault.accruedBuilderFee(), afterOpen * 2, "open and close both billed");
    }

    /// An idle vault pays nothing, however long it sits. This is what makes the execution
    /// fee not a management fee, and the claim is worth a test rather than a comment.
    function test_idleVaultAccruesNoExecutionFee() public {
        uint128[] memory none = new uint128[](0);
        vm.warp(block.timestamp + 365 days);
        vault.reconcile(none);
        assertEq(vault.accruedBuilderFee(), 0);
        assertEq(vault.accruedPlatformFee(), 0);
    }

    // ─────────────────────────────────────── withdrawal in every state

    /// The property that matters more than any other in this contract.
    function test_withdrawalWorksInEveryState() public {
        uint64 amount = uint64(100 * UNIT);

        vm.prank(trader);
        vault.requestWithdraw(amount);

        vm.startPrank(trader);
        vault.pause();
        vault.requestWithdraw(amount);
        vm.stopPrank();

        vm.prank(guardian);
        registry.suspendListing(listingId);
        vm.prank(trader);
        vault.requestWithdraw(amount);

        vm.prank(guardian);
        whitelist.removeMarket(BTC_PERP);
        vm.prank(trader);
        vault.requestWithdraw(amount);

        assertEq(vault.pendingWithdrawal(), amount * 4);
    }

    function test_finalizeWithdrawPaysTheTraderAndLowersTheMark() public {
        vm.prank(trader);
        vault.requestWithdraw(uint64(1_000 * UNIT));

        // Core has returned the money to the EVM side.
        usdc.mint(address(vault), 1_000 * UNIT);

        uint256 before = usdc.balanceOf(trader);
        vault.finalizeWithdraw();

        assertEq(usdc.balanceOf(trader) - before, 1_000 * UNIT);
        assertEq(vault.highWaterMark(), 9_000 * UNIT, "or no fee-free recovery is possible");
        assertEq(vault.pendingWithdrawal(), 0);
    }

    function test_exitWorksWithoutTheAgentAndAfterDelisting() public {
        _setPosition(address(vault), BTC_PERP, _sziWorth(100));

        vm.prank(trader);
        vault.pause();

        vm.prank(guardian);
        whitelist.removeMarket(BTC_PERP);

        uint256 before = _coreWriter().actionCount();
        vm.prank(trader);
        vault.exitPosition(BTC_PERP);

        assertEq(_coreWriter().actionCount(), before + 1, "closes even after removal");
    }

    function test_onlyTraderOrAgentCanExit() public {
        vm.prank(attacker);
        vm.expectRevert(Errors.NotTraderOrAgent.selector);
        vault.exitPosition(BTC_PERP);
    }

    function test_reservedCapitalIsNotWithdrawable() public {
        vm.prank(agent);
        vault.placeOrder(BTC_PERP, true, 1e8, _size(1_000), false, 2, 1);

        assertEq(vault.availableToWithdraw(), 9_000 * UNIT);

        vm.prank(trader);
        vm.expectRevert(Errors.InsufficientBalance.selector);
        vault.requestWithdraw(uint64(10_000 * UNIT));
    }

    /// And a reservation can never trap anyone: the trader clears every one alone.
    function test_traderClearsEveryReservationAlone() public {
        uint128[] memory cloids = new uint128[](Constants.MAX_OPEN_ORDERS);
        vm.startPrank(agent);
        for (uint128 i; i < Constants.MAX_OPEN_ORDERS; ++i) {
            vault.placeOrder(BTC_PERP, true, 1e8, _size(1), false, 2, i + 1);
            cloids[i] = i + 1;
        }
        vm.stopPrank();

        assertGt(vault.reserved(), 0);
        vm.prank(trader);
        vault.cancelAll(cloids);

        assertEq(vault.reserved(), 0);
        assertEq(vault.openOrders(), 0);
    }

    // ─────────────────────────────────────── fees

    function test_performanceFeeIsRateLimited() public {
        vm.expectRevert(Errors.FeeAssessmentTooSoon.selector);
        vault.assessFees();
    }

    function test_performanceFeeAccruesOnlyAboveTheMark() public {
        vm.warp(block.timestamp + Constants.FEE_ASSESSMENT_INTERVAL + 1);
        _setEquity(address(vault), 9_000);
        vault.assessFees();
        assertEq(vault.accruedBuilderFee(), 0, "no fee on a loss");

        vm.warp(block.timestamp + Constants.FEE_ASSESSMENT_INTERVAL + 1);
        _setEquity(address(vault), 12_000);
        vault.assessFees();

        assertEq(vault.accruedBuilderFee(), 160 * UNIT, "80% of 10% of 2,000");
        assertEq(vault.accruedPlatformFee(), 40 * UNIT);
    }

    function test_varianceCannotBeFarmedAcrossAssessments() public {
        vm.warp(block.timestamp + Constants.FEE_ASSESSMENT_INTERVAL + 1);
        _setEquity(address(vault), 12_000);
        vault.assessFees();
        uint64 first = vault.accruedBuilderFee();

        // Down, then back to the same high. The second run must charge nothing: the
        // profit was already billed once.
        vm.warp(block.timestamp + Constants.FEE_ASSESSMENT_INTERVAL + 1);
        _setEquity(address(vault), 9_000);
        vault.assessFees();

        vm.warp(block.timestamp + Constants.FEE_ASSESSMENT_INTERVAL + 1);
        _setEquity(address(vault), 11_800);
        vault.assessFees();

        assertEq(vault.accruedBuilderFee(), first, "no second bite at the same profit");
    }

    function test_feeSweepSplitsProportionallyWhenShort() public {
        vm.warp(block.timestamp + Constants.FEE_ASSESSMENT_INTERVAL + 1);
        _setEquity(address(vault), 12_000);
        vault.assessFees();

        // Only half of what is owed has made it back to the EVM side.
        usdc.mint(address(vault), 100 * UNIT);
        vault.sweepFees();

        assertEq(usdc.balanceOf(builder), 80 * UNIT, "80% of what was available");
        assertEq(usdc.balanceOf(treasury), 20 * UNIT);
        assertEq(vault.accruedBuilderFee(), 80 * UNIT, "the rest stays owed");
        assertEq(vault.accruedPlatformFee(), 20 * UNIT);
    }

    // ─────────────────────────────────────── fast mode

    function test_onlyTraderCanEnableFastMode() public {
        vm.prank(agent);
        vm.expectRevert(Errors.NotTrader.selector);
        vault.enableFastMode(agent);
    }

    function test_fastModeEmitsWhatTheKeeperConsumes() public {
        vm.expectEmit(true, false, false, true, address(vault));
        emit HLAgentVault.FastModeEnabled(agent, uint64(Constants.DEFAULT_EXECUTION_FEE_BPS) * 10);

        vm.prank(trader);
        vault.enableFastMode(agent);
        assertEq(vault.apiWallet(), agent);
    }

    function test_fastModeSendsAbstractionApiWalletAndBuilderApproval() public {
        uint256 before = _coreWriter().actionCount();
        vm.prank(trader);
        vault.enableFastMode(agent);

        assertEq(_coreWriter().actionCount(), before + 3);
        assertEq(_coreWriter().actionIdAt(before), 16, "action 16: set abstraction");
        assertEq(_coreWriter().actionIdAt(before + 1), 9, "action 9: add API wallet");
        assertEq(_coreWriter().actionIdAt(before + 2), 12, "action 12: approve builder fee");
    }

    /// Standing down does not rely on the API wallet actually being revoked, because
    /// whether re-adding one under the same name revokes the previous key is unconfirmed.
    /// It pauses and closes, leaving the key nothing to trade.
    function test_disableFastModePausesAndCloses() public {
        _setPosition(address(vault), BTC_PERP, _sziWorth(100));
        vm.prank(agent);
        vault.placeOrder(BTC_PERP, true, 1e8, _size(100), false, 2, 1);

        vm.prank(trader);
        vault.enableFastMode(agent);

        uint256 before = _coreWriter().actionCount();
        vm.prank(trader);
        vault.disableFastMode();

        assertEq(vault.apiWallet(), address(0));
        assertEq(uint256(vault.status()), uint256(HLAgentVault.VaultStatus.Paused));
        assertGt(_coreWriter().actionCount(), before, "closes were sent");
    }

    /// The keeper acts through the agent key, so the agent must be able to stand the
    /// vault down even though only the trader may stand it up.
    function test_agentCanTriggerTheKillSwitch() public {
        vm.prank(trader);
        vault.enableFastMode(agent);

        vm.prank(agent);
        vault.disableFastMode();
        assertEq(vault.apiWallet(), address(0));
    }

    function test_disableFastModeWhenOffReverts() public {
        vm.prank(trader);
        vm.expectRevert(Errors.AlreadySet.selector);
        vault.disableFastMode();
    }

    // ─────────────────────────────────────── risk limits

    function test_limitsCanOnlyBeTightened() public {
        vm.startPrank(trader);
        vault.tightenRiskLimits(600, 800);
        assertEq(vault.positionCapBps(), 600);

        vm.expectRevert(Errors.RiskOverrideNotStricter.selector);
        vault.tightenRiskLimits(700, 800);

        vm.expectRevert(Errors.ZeroAmount.selector);
        vault.tightenRiskLimits(0, 800);
        vm.stopPrank();
    }

    function test_openingWithLooserLimitsThanTheListingIsRefused() public {
        vm.prank(otherTrader);
        vm.expectRevert(Errors.RiskOverrideNotStricter.selector);
        factory.deployVault(listingId, Constants.DEFAULT_POSITION_CAP_BPS + 1, 0);
    }

    function test_tighteningTheCapBitesOnTheNextOrder() public {
        vm.prank(trader);
        vault.tightenRiskLimits(300, 1_500); // 3% of 10,000 = 300

        vm.prank(agent);
        vm.expectRevert(Errors.PositionCapExceeded.selector);
        vault.placeOrder(BTC_PERP, true, 1e8, _size(500), false, 2, 1);
    }

    // ─────────────────────────────────────── property

    /// Reservations plus positions never exceed the cap, whatever order sizes an agent
    /// picks. The invariant the whole reservation mechanism exists to hold.
    function testFuzz_reservationsNeverBreachTheCap(uint64 a, uint64 b, uint64 c) public {
        a = uint64(bound(a, 1e6, 2_000e8));
        b = uint64(bound(b, 1e6, 2_000e8));
        c = uint64(bound(c, 1e6, 2_000e8));

        uint64[3] memory sizes = [a, b, c];
        vm.startPrank(agent);
        for (uint128 i; i < 3; ++i) {
            try vault.placeOrder(BTC_PERP, true, 1e8, sizes[i], false, 2, i + 1) { } catch { }
        }
        vm.stopPrank();

        uint256 cap = (uint256(vault.equity()) * vault.positionCapBps()) / Constants.BPS;
        assertLe(
            uint256(vault.positionValue()) + uint256(vault.reserved()),
            cap,
            "accepted orders can never add up past the cap"
        );
    }
}
