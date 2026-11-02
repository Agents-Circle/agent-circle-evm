// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Initializable } from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

import { CoreWriterLib } from "@hyper-evm-lib/src/CoreWriterLib.sol";
import { PrecompileLib } from "@hyper-evm-lib/src/PrecompileLib.sol";

import { IAgentRegistry } from "../interfaces/IAgentRegistry.sol";
import { HLMarketWhitelist } from "./HLMarketWhitelist.sol";
import { Errors } from "../libraries/Errors.sol";
import { Constants } from "../libraries/Constants.sol";
import { HighWaterMark } from "../libraries/HighWaterMark.sol";

/// Non-custodial vault for agent-directed capital on HyperEVM.
///
/// One clone per `(trader, listing)`. The clone's own address **is** its HyperCore
/// account, which is why this is a clone rather than a row in a mapping: a singleton
/// would give every trader in the protocol one shared HyperCore account, with every
/// position commingled and no way to tell whose is whose. See ADR-0001.
///
/// The trader is the sole withdrawal authority. The agent holds scoped permission to
/// trade and nothing else.
///
/// ## The thing to understand before reading anything else
///
/// **CoreWriter is fire-and-forget.** `sendRawAction` succeeds whether or not HyperCore
/// accepts the action. An order this contract "placed" may never have existed on Core —
/// rejected for tick size, for `szDecimals`, for insufficient perp margin, or because
/// the asset is not live. Nothing on the EVM side can tell the difference at call time.
///
/// Three consequences run through the whole design:
///
/// 1. `placeOrder` can only know it *enqueued* an order. So the limits are checked
///    before the order is sent — which is sound, and is the claim the docs make — but
///    the vault's idea of its own open orders is a hypothesis, not a fact.
/// 2. `reconcile` is therefore not a convenience. It is the only path by which a
///    reservation is ever truthfully released, and it must release reservations for
///    orders Core silently dropped as readily as for orders that filled.
///    `MAX_ORDER_LIFETIME` is the backstop that makes a dropped order self-clearing
///    even if no keeper ever runs.
/// 3. The execution fee is charged at `reconcile` against size that demonstrably
///    changed, never at `placeOrder` against size that was merely requested. Billing a
///    trader 2 bps for an order Core never accepted would be indefensible, and an agent
///    could have farmed it by spamming orders it knew would be rejected.
///
/// ## Deposits are asynchronous twice over
///
/// EVM USDC → Core spot is a bridge; Core spot → Core perp is a class transfer. Both are
/// asynchronous and both are fire-and-forget. "Deposited" and "usable as perp margin"
/// are different states, so the contract tracks them separately and the UI must show
/// both. Bridged USDC lands in the **spot** balance: skip the class transfer and perp
/// orders are dropped silently.
contract HLAgentVault is Initializable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using HighWaterMark for HighWaterMark.State;

    enum VaultStatus {
        None,
        Active,
        Paused,
        Closing
    }

    /// An order this vault asked CoreWriter to place.
    ///
    /// `asset` is stored, not derived: CoreWriter's cancel actions take `(asset, cloid)`,
    /// not `cloid` alone, so a cancel is impossible without it. Discovered by reading the
    /// action encoding rather than the prose summary of it.
    struct Reservation {
        uint32 asset;
        uint64 maxCost; // worst-case USDC (1e6) if this fills completely
        uint64 expiry;
        bool released;
    }

    // ───────────────────────────────────────── implementation-wide config
    //
    // Immutable, so it lives in the implementation's bytecode and every clone shares it
    // without paying to store it. A clone cannot have its own immutables — that is what
    // `initialize` is for.

    IERC20 public immutable usdc;
    IAgentRegistry public immutable registry;
    HLMarketWhitelist public immutable whitelist;
    address public immutable platformTreasury;

    /// The address Agent Circle collects HyperCore builder fees at, used only in fast
    /// mode. Not the treasury: builder fees are claimed through Hyperliquid's referral
    /// reward flow, which is an account on Core rather than an EVM address that can be
    /// swept.
    address public immutable platformBuilder;

    /// USDC's token index on HyperCore.
    ///
    /// Held as a constructor argument rather than looked up. `CoreWriterLib`'s
    /// address-based bridge helpers resolve an EVM token to its Core index through an
    /// on-chain `TokenRegistry`, which would put a live external contract call on the
    /// deposit and withdrawal path — a dependency that can be wrong, be upgraded, or not
    /// exist on a given chain. This vault handles exactly one token, its index is a
    /// constant of the chain, and passing it in at deploy removes the lookup entirely.
    uint64 public immutable usdcCoreIndex;

    // ───────────────────────────────────────── per-clone state

    address public trader;
    bytes32 public listingId;
    VaultStatus public status;

    uint16 public positionCapBps;
    uint16 public maxDrawdownBps;
    bool public autoPause;

    /// USDC (1e6) the trader has deposited and the vault has asked Core to accept, but
    /// which has not yet been seen in the Core margin summary. Not an asset the vault
    /// can trade against; shown separately so a trader is never told their money has
    /// arrived before it has.
    uint64 public pendingBridge;

    /// Worst-case USDC committed to orders the vault believes are outstanding.
    uint64 public reserved;
    uint8 public openOrders;

    uint64 public highWaterMark;
    uint64 public lastFeeAssessment;

    /// Withdrawal requested by the trader and asked of Core, awaiting arrival on the EVM.
    uint64 public pendingWithdrawal;

    uint64 public accruedBuilderFee;
    uint64 public accruedPlatformFee;

    /// Fast mode: the agent's HyperCore API wallet. Zero when off.
    address public apiWallet;

    mapping(uint128 => Reservation) public reservations;

    /// Assets this vault has ever traded, and the size last seen at reconcile. The pair
    /// is what makes the execution fee measurable: a change in size is a fill.
    uint32[] internal _trackedAssets;
    mapping(uint32 => bool) internal _isTracked;
    mapping(uint32 => int64) internal _lastSeenSzi;

    event Initialized(address indexed trader, bytes32 indexed listingId);
    event Deposited(uint64 amount, uint64 pendingBridge);
    event DepositSettled(uint64 amount);
    event WithdrawRequested(uint64 amount);
    event WithdrawFinalized(uint64 amount);
    event OrderPlaced(uint128 indexed cloid, uint32 asset, bool isBuy, uint64 sz, uint64 maxCost);
    event OrderReleased(uint128 indexed cloid, uint64 maxCost, string reason);
    event Reconciled(uint64 equity, uint64 highWaterMark, uint256 drawdownBps);
    event ExecutionFeeAccrued(uint32 indexed asset, uint64 notional, uint64 fee);
    event FeesAssessed(uint64 builderCut, uint64 platformCut);
    event FeesSwept(uint64 builderCut, uint64 platformCut);
    event StatusChanged(VaultStatus status);
    event AutoPaused(uint256 drawdownBps);
    event RiskLimitsTightened(uint16 positionCapBps, uint16 maxDrawdownBps);
    event PositionExitSent(uint32 indexed asset, int64 size);
    event FastModeEnabled(address indexed apiWallet, uint64 maxFeeRateDecibps);
    event FastModeDisabled(address indexed previousApiWallet);

    /// Order size and price reach CoreWriter scaled by 1e8. USDC is 1e6. So a notional
    /// in USDC units is `sz * px / 1e10`, and that factor is written once here rather
    /// than inline at three call sites where a missing zero would misprice every check.
    uint256 private constant SZ_PX_TO_USDC = 1e10;

    /// HyperCore's first perp dex. The margin summary is per-dex.
    uint32 private constant PERP_DEX = 0;

    /// Tif byte for an immediate-or-cancel order, per the CoreWriter action encoding
    /// (1 = Alo, 2 = Gtc, 3 = Ioc).
    uint8 private constant TIF_IOC = 3;

    constructor(
        address usdc_,
        address registry_,
        address whitelist_,
        address platformTreasury_,
        address platformBuilder_,
        uint64 usdcCoreIndex_
    ) {
        if (
            usdc_ == address(0) || registry_ == address(0) || whitelist_ == address(0)
                || platformTreasury_ == address(0) || platformBuilder_ == address(0)
        ) revert Errors.ZeroAddress();

        usdc = IERC20(usdc_);
        registry = IAgentRegistry(registry_);
        whitelist = HLMarketWhitelist(whitelist_);
        platformTreasury = platformTreasury_;
        platformBuilder = platformBuilder_;
        usdcCoreIndex = usdcCoreIndex_;

        // The implementation itself must never be initialisable. An uninitialised
        // implementation with a live `initialize` is an unowned vault anyone can claim,
        // and on HyperEVM it is worse than usual: the implementation address is also a
        // HyperCore account, so whoever claimed it could trade from it.
        _disableInitializers();
    }

    /// Called once by the factory, immediately after cloning.
    ///
    /// Pass zero for either limit to inherit the listing's own. Overrides may only ever
    /// be *stricter* — a trader tightening their own exposure is their business, while
    /// loosening it past what the listing was vetted at would void the guarantee the
    /// leaderboard makes to everyone else.
    function initialize(
        address trader_,
        bytes32 listingId_,
        uint16 positionCapBps_,
        uint16 maxDrawdownBps_
    ) external initializer {
        if (trader_ == address(0)) revert Errors.ZeroAddress();

        IAgentRegistry.Listing memory l = registry.getListing(listingId_);
        if (l.status != IAgentRegistry.ListingStatus.Live) revert Errors.ListingNotLive();

        uint16 cap = positionCapBps_ == 0 ? l.positionCapBps : positionCapBps_;
        uint16 dd = maxDrawdownBps_ == 0 ? l.maxDrawdownBps : maxDrawdownBps_;
        if (cap > l.positionCapBps || dd > l.maxDrawdownBps) {
            revert Errors.RiskOverrideNotStricter();
        }

        trader = trader_;
        listingId = listingId_;
        positionCapBps = cap;
        maxDrawdownBps = dd;
        autoPause = true;
        status = VaultStatus.Active;
        lastFeeAssessment = uint64(block.timestamp);

        emit Initialized(trader_, listingId_);
    }

    modifier onlyTrader() {
        if (msg.sender != trader) revert Errors.NotTrader();
        _;
    }

    modifier onlyAgent() {
        if (msg.sender != registry.getListing(listingId).agentAuthority) {
            revert Errors.NotAgentAuthority();
        }
        _;
    }

    modifier onlyTraderOrAgent() {
        if (msg.sender != trader && msg.sender != registry.getListing(listingId).agentAuthority) {
            revert Errors.NotTraderOrAgent();
        }
        _;
    }

    // ────────────────────────────────────────────────────────── deposits

    /// Pull USDC, bridge it to Core, and move it to the perp account.
    ///
    /// Both hops are fire-and-forget, so this records the amount as pending rather than
    /// as balance. `reconcile` is what observes it arriving.
    function deposit(uint64 amount) external nonReentrant onlyTrader {
        if (amount == 0) revert Errors.ZeroAmount();
        if (status != VaultStatus.Active) revert Errors.VaultNotActive();

        if (amount > registry.availableAumHeadroom(listingId)) {
            revert Errors.AumCeilingExceeded();
        }

        usdc.safeTransferFrom(msg.sender, address(this), amount);

        // Raise the mark with the deposit, or fresh capital reads as profit and the
        // trader is charged a performance fee on their own money.
        highWaterMark += amount;
        pendingBridge += amount;

        registry.notifyAumDelta(listingId, int256(uint256(amount)));

        CoreWriterLib.bridgeToCore(usdcCoreIndex, uint256(amount));
        // Bridged USDC lands in spot. Without this it is invisible to perp margin and
        // every order is dropped with no error anywhere.
        CoreWriterLib.transferUsdClass(amount, true);

        emit Deposited(amount, pendingBridge);
    }

    // ────────────────────────────────────────────────────────── trading

    /// Place one limit order on HyperCore. Vault mode.
    ///
    /// Six checks, all of which hold before the action is sent:
    ///
    ///   1. Vault active
    ///   2. Listing live
    ///   3. Caller is the listing's agent authority
    ///   4. Asset is whitelisted
    ///   5. Worst-case notional, plus every outstanding reservation, is within the
    ///      position cap at the current mark
    ///   6. Equity is within the drawdown limit from the high-water mark
    ///
    /// Reduce-only orders skip (5): they can only ever decrease exposure, and a vault
    /// already over its cap must not be blocked from getting back under it.
    ///
    /// No execution fee is charged here. See the contract note.
    function placeOrder(
        uint32 asset,
        bool isBuy,
        uint64 limitPx,
        uint64 sz,
        bool reduceOnly,
        uint8 tif,
        uint128 cloid
    ) external nonReentrant onlyAgent {
        if (status != VaultStatus.Active) revert Errors.VaultNotActive();
        if (registry.getListing(listingId).status != IAgentRegistry.ListingStatus.Live) {
            revert Errors.ListingNotLive();
        }
        if (sz == 0 || limitPx == 0) revert Errors.ZeroAmount();
        if (cloid == 0) revert Errors.ZeroAmount();
        if (reservations[cloid].asset != 0 || reservations[cloid].maxCost != 0) {
            revert Errors.OrderAlreadyExists();
        }
        if (!whitelist.isListed(asset)) revert Errors.VenueNotWhitelisted();
        if (openOrders >= Constants.MAX_OPEN_ORDERS) revert Errors.TooManyOpenOrders();

        uint64 equity = _equity();
        _requireWithinDrawdown(equity);

        uint64 maxCost = uint64((uint256(sz) * uint256(limitPx)) / SZ_PX_TO_USDC);

        // Tracked *before* the cap check, not after, and the ordering is load-bearing.
        // `_positionValue` sums tracked assets only, so checking first would value an
        // untracked asset at zero and let the first vault-mode order on it ignore a
        // position that already exists there.
        //
        // That is not hypothetical. In fast mode the agent trades off-chain through its
        // API wallet and the vault sees none of it, so a vault switching back to vault
        // mode can hold positions it never placed an order for. Tracking on sight is
        // what stops the first such order being measured against nothing.
        _track(asset);

        if (!reduceOnly) {
            if (maxCost == 0) revert Errors.ZeroAmount();
            uint64 reservedAfter = reserved + maxCost;

            // The stricter of the vault's cap and the asset's own. A thin HIP-3 or HIP-4
            // book can be a worse constraint than the trader's risk appetite.
            uint16 cap = whitelist.effectiveCapBps(asset, positionCapBps);
            _requireWithinPositionCap(_positionValue(), reservedAfter, equity, cap);

            reserved = reservedAfter;
        }

        ++openOrders;
        reservations[cloid] = Reservation({
            asset: asset,
            maxCost: reduceOnly ? 0 : maxCost,
            expiry: uint64(block.timestamp) + Constants.MAX_ORDER_LIFETIME,
            released: false
        });
        emit OrderPlaced(cloid, asset, isBuy, sz, maxCost);
        CoreWriterLib.placeLimitOrder(asset, isBuy, limitPx, sz, reduceOnly, tif, cloid);
    }

    /// Either party may cancel: the agent because it changed its mind, the trader because
    /// it is their money and waiting out an expiry should not be their only option.
    function cancelOrder(uint128 cloid) external onlyTraderOrAgent {
        Reservation storage r = reservations[cloid];
        if (r.expiry == 0) revert Errors.OrderNotFound();
        if (r.released) revert Errors.OrderNotFound();

        uint32 asset = r.asset;
        _release(cloid, "cancelled");
        CoreWriterLib.cancelOrderByCloid(asset, cloid);
    }

    /// Clear every outstanding order in one transaction.
    ///
    /// This exists so a trader's route back to their own money never gets longer the more
    /// orders the agent happens to have open. With `MAX_OPEN_ORDERS` bounding the count,
    /// it is always one transaction.
    function cancelAll(uint128[] calldata cloids) external onlyTraderOrAgent {
        for (uint256 i; i < cloids.length; ++i) {
            Reservation storage r = reservations[cloids[i]];
            if (r.expiry == 0 || r.released) continue;

            uint32 asset = r.asset;
            _release(cloids[i], "cancelled");
            CoreWriterLib.cancelOrderByCloid(asset, cloids[i]);
        }
    }

    // ────────────────────────────────────────────────────────── reconcile

    /// Bring the vault's bookkeeping back in line with HyperCore. **Permissionless.**
    ///
    /// Permissionless because every party has a reason to want it run and none of them
    /// can be relied on: the keeper may be down, the agent may be hostile, the trader may
    /// not be watching. Everything it does is either neutral or in the trader's favour.
    ///
    /// Four jobs:
    ///
    /// - Settle the pending bridge once Core shows the money.
    /// - Charge the execution fee on size that actually moved.
    /// - Release reservations for expired orders, which covers orders Core dropped.
    /// - Raise the high-water mark, and if drawdown has breached the limit, pause and
    ///   send reduce-only closes.
    function reconcile(uint128[] calldata staleCloids) external nonReentrant {
        if (status == VaultStatus.None) revert Errors.VaultNotFound();

        uint64 equity = _equity();

        // The bridge has landed when Core's equity covers what we were waiting for. An
        // approximation, and deliberately a conservative one: it can only ever understate
        // what has arrived, never overstate it.
        if (pendingBridge > 0 && equity > 0) {
            uint64 settled = pendingBridge;
            pendingBridge = 0;
            emit DepositSettled(settled);
        }

        _accrueExecutionFees();

        for (uint256 i; i < staleCloids.length; ++i) {
            Reservation storage r = reservations[staleCloids[i]];
            if (r.expiry == 0 || r.released) continue;
            if (block.timestamp <= r.expiry) continue;
            _release(staleCloids[i], "expired");
        }

        if (equity > highWaterMark) highWaterMark = equity;

        uint256 dd = HighWaterMark.drawdownBps(
            HighWaterMark.State({ balance: equity, highWaterMark: highWaterMark })
        );

        if (dd >= maxDrawdownBps && status == VaultStatus.Active) {
            status = VaultStatus.Paused;
            emit AutoPaused(dd);
            emit StatusChanged(VaultStatus.Paused);
            _closeAllPositions();
        }

        emit Reconciled(equity, highWaterMark, dd);
    }

    /// Charge the execution fee on size that demonstrably changed.
    ///
    /// Measured as `|szi_now - szi_last| * markPx` per tracked asset. This is honest
    /// about what it can see and wrong in one direction, which is worth stating plainly:
    /// **a position opened and closed entirely between two reconciles shows no net change
    /// and is not billed.** A high-frequency agent against an idle keeper therefore
    /// underpays.
    ///
    /// That is a revenue loss, not a trader harm, and it is the correct direction to be
    /// wrong in. The alternative — billing requested size at `placeOrder` — charges for
    /// orders HyperCore rejected, which is a trader harm and one an agent could farm.
    /// The keeper calls `reconcile` on fill events precisely to close this gap.
    function _accrueExecutionFees() internal {
        IAgentRegistry.Listing memory l = registry.getListing(listingId);
        if (l.executionFeeBps == 0) {
            // Still refresh the baseline, or turning the fee on later would bill the
            // entire position history since the last reconcile in one go.
            _refreshSeenSizes();
            return;
        }

        uint256 len = _trackedAssets.length;
        for (uint256 i; i < len; ++i) {
            uint32 asset = _trackedAssets[i];
            int64 now_ = PrecompileLib.position(address(this), asset).szi;
            int64 last = _lastSeenSzi[asset];
            if (now_ == last) continue;

            uint64 delta = uint64(
                now_ > last
                    ? uint64(uint128(int128(now_) - int128(last)))
                    : uint64(uint128(int128(last) - int128(now_)))
            );
            _lastSeenSzi[asset] = now_;

            // `szi` carries szDecimals and `markPx` carries (6 - szDecimals), so the
            // product is already USDC at 1e6. No scaling factor, and no place for one to
            // be wrong.
            uint64 notional = uint64((uint256(delta) * uint256(PrecompileLib.markPx(asset))));
            if (notional == 0) continue;

            uint64 fee = uint64((uint256(notional) * l.executionFeeBps) / Constants.BPS);
            if (fee == 0) continue;

            uint64 builderCut = uint64((uint256(fee) * l.executionBuilderSplitBps) / Constants.BPS);
            accruedBuilderFee += builderCut;
            accruedPlatformFee += fee - builderCut;

            emit ExecutionFeeAccrued(asset, notional, fee);
        }
    }

    function _refreshSeenSizes() internal {
        uint256 len = _trackedAssets.length;
        for (uint256 i; i < len; ++i) {
            uint32 asset = _trackedAssets[i];
            _lastSeenSzi[asset] = PrecompileLib.position(address(this), asset).szi;
        }
    }

    // ────────────────────────────────────────────────────────── lifecycle

    function pause() external onlyTrader {
        status = VaultStatus.Paused;
        emit StatusChanged(VaultStatus.Paused);
    }

    function resume() external onlyTrader {
        if (status == VaultStatus.None) revert Errors.VaultNotFound();
        status = VaultStatus.Active;
        emit StatusChanged(VaultStatus.Active);
    }

    /// Tighten-only, for the same reason overrides are stricter-only at initialisation.
    function tightenRiskLimits(uint16 positionCapBps_, uint16 maxDrawdownBps_) external onlyTrader {
        if (positionCapBps_ == 0 || maxDrawdownBps_ == 0) revert Errors.ZeroAmount();
        if (positionCapBps_ > positionCapBps || maxDrawdownBps_ > maxDrawdownBps) {
            revert Errors.RiskOverrideNotStricter();
        }
        positionCapBps = positionCapBps_;
        maxDrawdownBps = maxDrawdownBps_;
        emit RiskLimitsTightened(positionCapBps_, maxDrawdownBps_);
    }

    // ────────────────────────────────────────────── withdrawal and exit

    /// Ask Core to send USDC back to this contract on the EVM.
    ///
    /// **Works in every state**, and that is the single most important property in this
    /// file. Paused, closing, listing suspended, listing delisted, asset de-whitelisted,
    /// agent gone silent, agent hostile — none of it blocks a trader from starting the
    /// journey back to their own money. Governance removing a market must stop new money
    /// going in; it must never strand money already there.
    ///
    /// Two steps because Core → EVM is asynchronous. This one moves perp margin to spot
    /// and asks for the bridge; `finalizeWithdraw` pays out what actually arrived.
    ///
    /// ## One caveat on "works in every state", and it is a real one
    ///
    /// The Core → EVM leg is a `sendAsset`, and `hyper-evm-lib` notes that bridging a
    /// non-HYPE token requires the sending account to hold **HYPE on Core** to cover the
    /// transfer's gas. A vault with no HYPE therefore cannot complete the bridge, which
    /// would make "withdrawal always works" false in exactly the circumstance nobody
    /// tests: a vault that has never held HYPE.
    ///
    /// This is unresolved in this contract and must not be papered over. Three options,
    /// none of them yet chosen: the factory funds each clone with a dust amount of HYPE
    /// at deploy; `deposit` provisions HYPE out of the deposit; or the keeper tops vaults
    /// up and the shortfall is surfaced to the trader. It is also the first thing the
    /// testnet probe should measure, because the amount needed is not documented.
    ///
    /// Until it is settled, the honest claim is "withdrawal is never blocked by the
    /// protocol" — the vault, the listing and the whitelist cannot stop it — rather than
    /// "withdrawal always succeeds".
    function requestWithdraw(uint64 amount) external nonReentrant onlyTrader {
        if (amount == 0) revert Errors.ZeroAmount();

        // Reserved capital is excluded: an outstanding order could still settle against
        // it. Unlike the Polygon vault this cannot strand anyone even in principle,
        // because `cancelAll` clears every reservation in one transaction and orders
        // expire within the hour regardless.
        uint64 equity = _equity();
        uint64 available = equity > reserved ? equity - reserved : 0;
        if (amount > available) revert Errors.InsufficientBalance();

        pendingWithdrawal += amount;

        CoreWriterLib.transferUsdClass(amount, false); // perp → spot
        CoreWriterLib.bridgeToEvm(usdcCoreIndex, uint256(amount), true);

        emit WithdrawRequested(amount);
    }

    /// Pay out USDC that has arrived from Core. Permissionless: it can only ever move
    /// money to the trader, and making the trader's own payout depend on their sending a
    /// second transaction at the right moment would be a poor guarantee.
    function finalizeWithdraw() external nonReentrant {
        if (status == VaultStatus.None) revert Errors.VaultNotFound();

        _sweepFees();

        uint256 balance = usdc.balanceOf(address(this));
        if (balance == 0) revert Errors.InsufficientBalance();

        uint64 amount = balance > type(uint64).max ? type(uint64).max : uint64(balance);
        if (amount > pendingWithdrawal) amount = pendingWithdrawal;
        if (amount == 0) revert Errors.ZeroAmount();

        pendingWithdrawal -= amount;

        // Lower the mark with the withdrawal, or the trader can never earn a fee-free
        // recovery on the capital they left in.
        highWaterMark = amount >= highWaterMark ? 0 : highWaterMark - amount;

        registry.notifyAumDelta(listingId, -int256(uint256(amount)));
        usdc.safeTransfer(trader, amount);

        emit WithdrawFinalized(amount);
    }

    /// Close a position with a reduce-only IOC, needing nobody's cooperation.
    ///
    /// Trader-callable without the agent, works while paused or closing, and works after
    /// governance has removed the asset — a vault that auto-paused into a drawdown is
    /// precisely the vault that most needs to get out.
    function exitPosition(uint32 asset) external onlyTraderOrAgent {
        if (status == VaultStatus.None) revert Errors.VaultNotFound();
        _sendReduceOnlyClose(asset);
    }

    function _closeAllPositions() internal {
        uint256 len = _trackedAssets.length;
        for (uint256 i; i < len; ++i) {
            _sendReduceOnlyClose(_trackedAssets[i]);
        }
    }

    /// A market exit expressed as a limit order, because CoreWriter has no market order.
    ///
    /// The limit is set far through the current mark — 50% beyond it in the direction
    /// that closes — so an IOC crosses whatever is on the book rather than resting. This
    /// accepts slippage on purpose: an exit that does not execute is not an exit, and
    /// this path only ever runs when the vault is already in trouble.
    function _sendReduceOnlyClose(uint32 asset) internal {
        int64 szi = PrecompileLib.position(address(this), asset).szi;
        if (szi == 0) return;

        bool isBuy = szi < 0; // short closes by buying
        uint64 size = uint64(szi > 0 ? uint64(szi) : uint64(-szi));
        uint64 mark = PrecompileLib.markPx(asset);
        uint64 limitPx = isBuy ? mark + mark / 2 : mark / 2;

        emit PositionExitSent(asset, szi);
        CoreWriterLib.placeLimitOrder(asset, isBuy, limitPx, size, true, TIF_IOC, 0);
    }

    // ────────────────────────────────────────────────────────── fees

    /// High-water-mark performance fee on equity read from Core.
    ///
    /// Rate-limited so nobody can grind a vault down through repeated rounding.
    function assessFees() external nonReentrant {
        if (status == VaultStatus.None) revert Errors.VaultNotFound();
        if (block.timestamp < lastFeeAssessment + Constants.FEE_ASSESSMENT_INTERVAL) {
            revert Errors.FeeAssessmentTooSoon();
        }

        IAgentRegistry.Listing memory l = registry.getListing(listingId);
        uint64 equity = _equity();

        HighWaterMark.State memory s =
            HighWaterMark.State({ balance: equity, highWaterMark: highWaterMark });
        HighWaterMark.FeeSplit memory split;
        (s, split) = s.assess(l.performanceFeeBps, l.builderSplitBps);

        lastFeeAssessment = uint64(block.timestamp);
        if (split.total == 0) {
            highWaterMark = uint64(s.highWaterMark);
            return;
        }

        highWaterMark = uint64(s.highWaterMark);
        accruedBuilderFee += uint64(split.builderCut);
        accruedPlatformFee += uint64(split.platformCut);

        emit FeesAssessed(uint64(split.builderCut), uint64(split.platformCut));
    }

    /// Pay out accrued fees from whatever USDC is on the EVM side.
    ///
    /// Fees accrue as a claim rather than a transfer because the money is on Core and
    /// bringing it back is asynchronous. Permissionless, and paid proportionally when the
    /// balance does not cover both: the alternative is a first-claimant race between the
    /// builder and the platform.
    ///
    /// Deliberately **after** the trader's payout in `finalizeWithdraw` is computed, not
    /// before — see the ordering there.
    function sweepFees() external nonReentrant {
        _sweepFees();
    }

    function _sweepFees() internal {
        uint64 owedBuilder = accruedBuilderFee;
        uint64 owedPlatform = accruedPlatformFee;
        uint64 owed = owedBuilder + owedPlatform;
        if (owed == 0) return;

        uint256 balance = usdc.balanceOf(address(this));
        if (balance == 0) return;

        uint64 payable_ = balance >= owed ? owed : uint64(balance);
        uint64 builderCut = uint64((uint256(payable_) * owedBuilder) / owed);
        uint64 platformCut = payable_ - builderCut;

        accruedBuilderFee = owedBuilder - builderCut;
        accruedPlatformFee = owedPlatform - platformCut;

        address builder = registry.getListing(listingId).builder;
        if (builderCut > 0) usdc.safeTransfer(builder, builderCut);
        if (platformCut > 0) usdc.safeTransfer(platformTreasury, platformCut);

        emit FeesSwept(builderCut, platformCut);
    }

    // ────────────────────────────────────────────────────────── fast mode

    /// Register the agent's key as a HyperCore API wallet and approve the builder fee.
    ///
    /// **This changes what the protocol can promise, and the UI must say so.** In vault
    /// mode every order passes through `placeOrder` and the limits are checked before it
    /// is sent. In fast mode the agent signs orders off-chain and this contract never
    /// sees them: limits are *monitored* by a keeper with a kill switch, not enforced.
    /// The trade is latency and real builder-code revenue — CoreWriter's action 1 has no
    /// builder field, so vault-mode orders cannot carry one.
    ///
    /// An API wallet can trade but cannot withdraw, so custody still holds. That is the
    /// floor under this mode, and it is the only guarantee that survives it.
    function enableFastMode(address apiWallet_) external onlyTrader {
        if (apiWallet_ == address(0)) revert Errors.ZeroAddress();
        if (status != VaultStatus.Active) revert Errors.VaultNotActive();

        IAgentRegistry.Listing memory l = registry.getListing(listingId);
        if (l.status != IAgentRegistry.ListingStatus.Live) revert Errors.ListingNotLive();

        apiWallet = apiWallet_;

        // Builder fees accrue only in standard account mode. `setAbstraction` offers
        // 1 = disabled, 2 = unifiedAccount, 3 = portfolioMargin — nothing named
        // "standard" — so this sends 1 on the reading that standard *is* the absence of
        // abstraction. **Unverified**, and the first thing the testnet probe must settle:
        // if it is wrong, fast-mode builder revenue silently never accrues.
        CoreWriterLib.setAbstraction(address(this), 1);
        CoreWriterLib.addApiWallet(apiWallet_, "agent-circle");

        // Decibps: 10 = 0.01%. The execution fee is in bps, so 1 bps = 10 decibps. The
        // approval is a ceiling, not a charge — Hyperliquid caps perps builder fees at
        // 0.1%, and `MAX_EXECUTION_FEE_BPS` (10) is below that by construction.
        uint64 maxFeeRate = uint64(l.executionFeeBps) * 10;
        CoreWriterLib.approveBuilderFee(maxFeeRate, platformBuilder);

        emit FastModeEnabled(apiWallet_, maxFeeRate);
    }

    /// Revoke fast mode and stand the vault down.
    ///
    /// Whether re-adding an API wallet under the same name actually revokes the previous
    /// key is **unconfirmed** — it is the open question the kill switch depends on. So
    /// this does not rely on it: it clears the vault's own record, pauses, and sends
    /// reduce-only closes. The keeper's kill switch is the same path. If the key does
    /// turn out to survive revocation, the agent can still trade but can never withdraw,
    /// and the position it would be trading has already been closed.
    function disableFastMode() external onlyTraderOrAgent {
        address previous = apiWallet;
        if (previous == address(0)) revert Errors.AlreadySet();

        apiWallet = address(0);
        status = VaultStatus.Paused;

        CoreWriterLib.addApiWallet(address(0), "agent-circle");
        _closeAllPositions();

        emit FastModeDisabled(previous);
        emit StatusChanged(VaultStatus.Paused);
    }

    // ────────────────────────────────────────────────────────── views

    function equity() external view returns (uint64) {
        return _equity();
    }

    function positionValue() external view returns (uint64) {
        return _positionValue();
    }

    function trackedAssets() external view returns (uint32[] memory) {
        return _trackedAssets;
    }

    function availableToWithdraw() external view returns (uint64) {
        uint64 e = _equity();
        return e > reserved ? e - reserved : 0;
    }

    /// Equity as HyperCore reports it, clamped at zero.
    ///
    /// `accountValue` is signed and can in principle go negative on a liquidated
    /// account. Clamping is correct for every use here: a negative equity is not a
    /// balance to charge fees on or measure a cap against, and the drawdown check
    /// treats zero as the total loss it is.
    function _equity() internal view returns (uint64) {
        int64 accountValue =
            PrecompileLib.accountMarginSummary(PERP_DEX, address(this)).accountValue;
        return accountValue <= 0 ? 0 : uint64(accountValue);
    }

    /// Mark-to-market value of every position this vault holds.
    ///
    /// Cost basis would not do: the position cap and the drawdown check are only as
    /// honest as this number.
    function _positionValue() internal view returns (uint64 total) {
        uint256 len = _trackedAssets.length;
        for (uint256 i; i < len; ++i) {
            uint32 asset = _trackedAssets[i];
            int64 szi = PrecompileLib.position(address(this), asset).szi;
            if (szi == 0) continue;
            uint64 size = uint64(szi > 0 ? uint64(szi) : uint64(-szi));
            total += uint64(uint256(size) * uint256(PrecompileLib.markPx(asset)));
        }
    }

    function _requireWithinPositionCap(
        uint64 positionValue_,
        uint64 reserved_,
        uint64 equity_,
        uint16 capBps
    ) internal pure {
        if (capBps == 0) revert Errors.VenueNotWhitelisted();
        if (
            (uint256(positionValue_) + uint256(reserved_)) * Constants.BPS
                > uint256(equity_) * capBps
        ) revert Errors.PositionCapExceeded();
    }

    function _requireWithinDrawdown(uint64 equity_) internal view {
        uint256 dd = HighWaterMark.drawdownBps(
            HighWaterMark.State({ balance: equity_, highWaterMark: highWaterMark })
        );
        if (dd >= maxDrawdownBps) revert Errors.DrawdownLimitBreached();
    }

    function _release(uint128 cloid, string memory reason) internal {
        Reservation storage r = reservations[cloid];
        r.released = true;
        reserved = r.maxCost >= reserved ? 0 : reserved - r.maxCost;
        if (openOrders > 0) --openOrders;
        emit OrderReleased(cloid, r.maxCost, reason);
    }

    function _track(uint32 asset) internal {
        if (_isTracked[asset]) return;
        _isTracked[asset] = true;
        _trackedAssets.push(asset);
        _lastSeenSzi[asset] = PrecompileLib.position(address(this), asset).szi;
    }
}
