// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import { IAgentRegistry } from "./interfaces/IAgentRegistry.sol";
import { Errors } from "./libraries/Errors.sol";
import { Constants } from "./libraries/Constants.sol";

/// Builder identity, agent listings, and the staked bonds that back them.
///
/// A builder posts a bond in the platform token. The bond buys a tier, and the tier sets
/// a ceiling on how much trader capital that builder may have under management across
/// *all* their listings at once. The ceiling is per-builder rather than per-listing on
/// purpose: a builder able to defraud across three agents is exposed for the total, not
/// for each one separately.
///
/// The registry never touches trader funds. It is the permission and reputation layer;
/// `AgentVault` is the custody layer.
contract AgentRegistry is IAgentRegistry, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable bondToken;
    uint64 public immutable unbondPeriod;

    address public governance;
    address public guardian;
    address public vault;
    /// Clone factory whose children may move AUM figures. See `setVaultFactory`.
    address public vaultFactory;

    /// Bond required for each tier, ascending.
    uint256[3] public tierBonds;
    /// AUM ceiling unlocked by each tier, ascending.
    uint256[3] public tierCeilings;

    /// How much of a tier's USDC bond staked $AGENT may substitute for. Zero, and it
    /// stays zero: $AGENT does not exist. The hook is here so the shape is settled and
    /// tested before there is any pressure to ship it in a hurry.
    ///
    /// Read the warning on `setAgentBondDiscount` before enabling it.
    uint16 public agentBondDiscountBps;

    mapping(address => Builder) internal _builders;
    mapping(bytes32 => Listing) internal _listings;

    event BuilderRegistered(address indexed builder);
    event BondStaked(address indexed builder, uint256 amount, uint8 tier);
    event UnbondRequested(address indexed builder, uint256 amount, uint64 availableAt);
    event BondWithdrawn(address indexed builder, uint256 amount, uint8 tier);
    event BondSlashed(address indexed builder, uint256 amount, uint256 toTraders);
    event ListingSubmitted(bytes32 indexed listingId, address indexed builder, bytes32 metadata);
    event ListingApproved(bytes32 indexed listingId);
    event ListingRejected(bytes32 indexed listingId);
    event ListingSuspended(bytes32 indexed listingId, address indexed by);
    event AgentAuthorityChanged(bytes32 indexed listingId, address indexed next);
    event VaultSet(address indexed vault);
    event VaultFactorySet(address indexed factory);
    event GuardianChanged(address indexed previous, address indexed next);
    event AgentBondDiscountSet(uint16 discountBps);

    modifier onlyGovernance() {
        if (msg.sender != governance) revert Errors.NotGovernance();
        _;
    }

    modifier onlyGovernanceOrGuardian() {
        if (msg.sender != governance && msg.sender != guardian) revert Errors.NotGuardian();
        _;
    }

    constructor(
        address governance_,
        address guardian_,
        address bondToken_,
        uint256[3] memory tierBonds_,
        uint256[3] memory tierCeilings_,
        uint64 unbondPeriod_
    ) {
        if (governance_ == address(0) || guardian_ == address(0) || bondToken_ == address(0)) {
            revert Errors.ZeroAddress();
        }
        if (unbondPeriod_ > Constants.MAX_UNBOND_PERIOD) revert Errors.ParameterOutOfBounds();

        governance = governance_;
        guardian = guardian_;
        bondToken = IERC20(bondToken_);
        tierBonds = tierBonds_;
        tierCeilings = tierCeilings_;
        unbondPeriod = unbondPeriod_;
    }

    // ────────────────────────────────────────────────────────── builders

    function registerBuilder() external {
        Builder storage b = _builders[msg.sender];
        if (b.exists) revert Errors.BuilderAlreadyRegistered();

        b.exists = true;
        b.createdAt = uint64(block.timestamp);
        emit BuilderRegistered(msg.sender);
    }

    function stakeBond(uint256 amount) external nonReentrant {
        if (amount == 0) revert Errors.ZeroAmount();
        Builder storage b = _builders[msg.sender];
        if (!b.exists) revert Errors.BuilderNotRegistered();

        bondToken.safeTransferFrom(msg.sender, address(this), amount);
        b.bondAmount += amount;
        b.tier = _tierFor(b.bondAmount);

        emit BondStaked(msg.sender, amount, b.tier);
    }

    /// Unbonding is a delay, not a penalty. A builder who wants out gets out; the delay
    /// exists so traders have a window to withdraw before the bond backing their capital
    /// disappears, and so misconduct discovered late still has something to slash.
    function requestUnbond(uint256 amount) external {
        Builder storage b = _builders[msg.sender];
        if (!b.exists) revert Errors.BuilderNotRegistered();
        if (amount == 0) revert Errors.ZeroAmount();
        if (amount > b.bondAmount) revert Errors.UnbondAmountExceedsBond();

        b.unbondAmount = amount;
        b.unbondRequestedAt = uint64(block.timestamp);

        emit UnbondRequested(msg.sender, amount, uint64(block.timestamp) + unbondPeriod);
    }

    function withdrawBond() external nonReentrant {
        Builder storage b = _builders[msg.sender];
        if (b.unbondRequestedAt == 0) revert Errors.NoUnbondRequested();
        if (block.timestamp < b.unbondRequestedAt + unbondPeriod) {
            revert Errors.UnbondPeriodNotElapsed();
        }

        uint256 amount = b.unbondAmount;
        if (amount > b.bondAmount) amount = b.bondAmount;

        // The bond must still cover capital under management after the withdrawal.
        // Traders exit first, then the builder unwinds — not the other way round.
        uint256 remaining = b.bondAmount - amount;
        if (_ceilingFor(_tierFor(remaining)) < b.totalAum) revert Errors.BondBelowAumCoverage();

        b.bondAmount = remaining;
        b.tier = _tierFor(remaining);
        b.unbondAmount = 0;
        b.unbondRequestedAt = 0;

        bondToken.safeTransfer(msg.sender, amount);
        emit BondWithdrawn(msg.sender, amount, b.tier);
    }

    /// Slashing is governance-executed, not automatic.
    ///
    /// Being honest about what that means: a bond deters, it does not make fraud
    /// impossible, and the decision to slash is a human one made by whoever holds the
    /// multisig. Anyone told otherwise is being sold something.
    function slashBond(address builder, uint256 amount, address traderRecipient)
        external
        onlyGovernance
        nonReentrant
    {
        Builder storage b = _builders[builder];
        if (!b.exists) revert Errors.BuilderNotRegistered();
        if (amount > b.bondAmount) revert Errors.UnbondAmountExceedsBond();
        if (traderRecipient == address(0)) revert Errors.ZeroAddress();

        b.bondAmount -= amount;
        b.tier = _tierFor(b.bondAmount);
        b.slashCount += 1;

        uint256 toTraders = (amount * Constants.SLASH_TRADER_BPS) / Constants.BPS;
        bondToken.safeTransfer(traderRecipient, toTraders);
        bondToken.safeTransfer(governance, amount - toTraders);

        emit BondSlashed(builder, amount, toTraders);
    }

    // ────────────────────────────────────────────────────────── listings

    function listingId(address builder, uint16 index) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(builder, index));
    }

    /// Fees are deliberately left at zero here and only set on approval. A listing that
    /// never passes vetting must never carry live economics.
    function submitListing(address agentAuthority, bytes32 metadataHash)
        external
        returns (bytes32 id)
    {
        Builder storage b = _builders[msg.sender];
        if (!b.exists) revert Errors.BuilderNotRegistered();
        if (agentAuthority == address(0)) revert Errors.ZeroAddress();

        id = listingId(msg.sender, b.agentCount);
        b.agentCount += 1;

        _listings[id] = Listing({
            builder: msg.sender,
            agentAuthority: agentAuthority,
            status: ListingStatus.Vetting,
            performanceFeeBps: 0,
            builderSplitBps: 0,
            executionFeeBps: 0,
            executionBuilderSplitBps: 0,
            positionCapBps: 0,
            maxDrawdownBps: 0,
            submittedAt: uint64(block.timestamp),
            metadataHash: metadataHash
        });

        emit ListingSubmitted(id, msg.sender, metadataHash);
    }

    function approveListing(bytes32 id, Terms calldata terms) external onlyGovernance {
        _approveListing(id, terms);
    }

    /// Approve with the locked launch parameters. The common path.
    function approveListingAtLaunchTerms(bytes32 id) external onlyGovernance {
        _approveListing(
            id,
            Terms({
                performanceFeeBps: Constants.DEFAULT_PERFORMANCE_FEE_BPS,
                builderSplitBps: Constants.DEFAULT_BUILDER_SPLIT_BPS,
                executionFeeBps: Constants.DEFAULT_EXECUTION_FEE_BPS,
                executionBuilderSplitBps: Constants.DEFAULT_EXECUTION_BUILDER_SPLIT_BPS,
                positionCapBps: Constants.DEFAULT_POSITION_CAP_BPS,
                maxDrawdownBps: Constants.DEFAULT_MAX_DRAWDOWN_BPS
            })
        );
    }

    function _approveListing(bytes32 id, Terms memory t) internal {
        Listing storage l = _listings[id];
        if (l.status != ListingStatus.Vetting) revert Errors.ListingNotVetting();

        // Every bound here is one a fully compromised multisig still cannot cross. The
        // execution-fee pair is bounded in both directions for the same reason the
        // performance split is: a ceiling stops the fee being used to drain a vault
        // through churn, and a floor under the builder's share stops governance quietly
        // reassigning the builder's half to the platform.
        //
        // Zero is permitted for the execution fee — unlike the position cap, where zero
        // would mean a vault that cannot trade at all. A listing on zero execution fee is
        // a coherent thing to approve, and may well be the right call for a low-turnover
        // agent.
        if (
            t.performanceFeeBps > Constants.MAX_PERFORMANCE_FEE_BPS
                || t.builderSplitBps < Constants.MIN_BUILDER_SPLIT_BPS
                || t.builderSplitBps > Constants.BPS
                || t.executionFeeBps > Constants.MAX_EXECUTION_FEE_BPS
                || t.executionBuilderSplitBps < Constants.MIN_EXECUTION_BUILDER_SPLIT_BPS
                || t.executionBuilderSplitBps > Constants.BPS || t.positionCapBps == 0
                || t.positionCapBps > Constants.MAX_POSITION_CAP_BPS || t.maxDrawdownBps == 0
                || t.maxDrawdownBps > Constants.MAX_DRAWDOWN_BPS_CEILING
        ) revert Errors.ParameterOutOfBounds();

        l.performanceFeeBps = t.performanceFeeBps;
        l.builderSplitBps = t.builderSplitBps;
        l.executionFeeBps = t.executionFeeBps;
        l.executionBuilderSplitBps = t.executionBuilderSplitBps;
        l.positionCapBps = t.positionCapBps;
        l.maxDrawdownBps = t.maxDrawdownBps;
        l.status = ListingStatus.Live;

        emit ListingApproved(id);
    }

    function rejectListing(bytes32 id) external onlyGovernance {
        Listing storage l = _listings[id];
        if (l.status != ListingStatus.Vetting) revert Errors.ListingNotVetting();
        l.status = ListingStatus.Rejected;
        emit ListingRejected(id);
    }

    /// Either key may suspend. Suspension stops new trades immediately; it does not
    /// touch trader funds, which remain withdrawable by their owners throughout.
    function suspendListing(bytes32 id) external onlyGovernanceOrGuardian {
        Listing storage l = _listings[id];
        if (l.status == ListingStatus.None) revert Errors.ListingNotFound();
        l.status = ListingStatus.Suspended;
        emit ListingSuspended(id, msg.sender);
    }

    /// A builder rotating a compromised agent key must not have to re-run vetting.
    function setAgentAuthority(bytes32 id, address next) external {
        Listing storage l = _listings[id];
        if (l.builder != msg.sender) revert Errors.NotBuilder();
        if (next == address(0)) revert Errors.ZeroAddress();
        l.agentAuthority = next;
        emit AgentAuthorityChanged(id, next);
    }

    // ────────────────────────────────────────────────────────── AUM

    function notifyAumDelta(bytes32 id, int256 delta) external {
        if (!_isAuthorisedVault(msg.sender)) revert Errors.NotVault();
        Listing storage l = _listings[id];
        if (l.status == ListingStatus.None) revert Errors.ListingNotFound();

        Builder storage b = _builders[l.builder];
        if (delta >= 0) {
            uint256 add = uint256(delta);
            if (b.totalAum + add > _ceilingFor(b.tier)) revert Errors.AumCeilingExceeded();
            b.totalAum += add;
        } else {
            uint256 sub = uint256(-delta);
            b.totalAum = sub >= b.totalAum ? 0 : b.totalAum - sub;
        }
    }

    function availableAumHeadroom(bytes32 id) external view returns (uint256) {
        Listing storage l = _listings[id];
        if (l.status == ListingStatus.None) return 0;

        Builder storage b = _builders[l.builder];
        uint256 ceiling = _ceilingFor(b.tier);
        return ceiling > b.totalAum ? ceiling - b.totalAum : 0;
    }

    // ────────────────────────────────────────────────────────── governance

    /// One-shot. The vault is the only contract permitted to move AUM figures, so making
    /// it re-settable would let a compromised governance key point the registry at a
    /// contract that mints headroom out of nothing.
    function setVault(address vault_) external onlyGovernance {
        if (vault != address(0)) revert Errors.AlreadySet();
        if (vault_ == address(0)) revert Errors.ZeroAddress();
        vault = vault_;
        emit VaultSet(vault_);
    }

    /// Register the clone factory whose children may move AUM figures.
    ///
    /// One-shot for the same reason `setVault` is, and the reason is sharper here. With a
    /// singleton, a re-settable pointer would let a compromised key authorise one rogue
    /// contract. With a factory it would authorise an unbounded *set* of them, since the
    /// attacker's factory attests whatever it likes. This is the new trust edge ADR-0001
    /// names, and making it unchangeable is most of what makes it safe.
    ///
    /// Both paths coexist: Polygon runs a singleton vault, HyperEVM runs clones, and one
    /// registry deployment serves one chain. Leaving `vault` unset on HyperEVM and
    /// `vaultFactory` unset on Polygon is the expected configuration, not an oversight.
    function setVaultFactory(address factory_) external onlyGovernance {
        if (vaultFactory != address(0)) revert Errors.AlreadySet();
        if (factory_ == address(0)) revert Errors.ZeroAddress();
        vaultFactory = factory_;
        emit VaultFactorySet(factory_);
    }

    /// Whether `caller` may move AUM figures.
    ///
    /// The factory is asked rather than trusted to have told us: `isVault` reads a
    /// mapping only the factory's own deploy path writes, so a contract cannot vouch for
    /// itself. A `staticcall` with a decoded bool, rather than a plain interface call, so
    /// that a factory address pointing at something which is not a factory fails closed
    /// instead of reverting the trader's deposit.
    function _isAuthorisedVault(address caller) internal view returns (bool) {
        if (caller == vault && vault != address(0)) return true;
        if (vaultFactory == address(0)) return false;

        (bool ok, bytes memory ret) =
            vaultFactory.staticcall(abi.encodeWithSignature("isVault(address)", caller));
        return ok && ret.length == 32 && abi.decode(ret, (bool));
    }

    function setGuardian(address next) external onlyGovernance {
        if (next == address(0)) revert Errors.ZeroAddress();
        emit GuardianChanged(guardian, next);
        guardian = next;
    }

    /// Let staked $AGENT substitute for part of a tier's USDC bond. Disabled at zero.
    ///
    /// **This weakens every bond already posted, immediately and retroactively.** A
    /// builder at tier 2 on exactly the tier-2 bond stays at tier 2 and may now withdraw
    /// the difference, so turning this on hands back collateral that is currently
    /// backing live trader capital. That is not a side effect to be managed; it is what
    /// the function does.
    ///
    /// It is deliberately left untimelocked and bounded instead, because a timelock here
    /// would be security theatre: the bound is what makes a compromised multisig unable
    /// to zero the bonds, and a two-day delay on a change that only ever reduces
    /// collateral protects nobody who was not already watching. The real control is that
    /// `MAX_AGENT_BOND_DISCOUNT_BPS` caps it at half, whatever governance intends.
    ///
    /// Before enabling it, the AUM coverage check in `withdrawBond` should be the thing
    /// that holds — and it is: a builder still cannot withdraw below the tier covering
    /// their live AUM. The discount lowers what that tier costs, not what it covers.
    function setAgentBondDiscount(uint16 discountBps) external onlyGovernance {
        if (discountBps > Constants.MAX_AGENT_BOND_DISCOUNT_BPS) {
            revert Errors.ParameterOutOfBounds();
        }
        agentBondDiscountBps = discountBps;
        emit AgentBondDiscountSet(discountBps);
    }

    // ────────────────────────────────────────────────────────── views

    function getListing(bytes32 id) external view returns (Listing memory) {
        return _listings[id];
    }

    function getBuilder(address builder) external view returns (Builder memory) {
        return _builders[builder];
    }

    function aumCeiling(address builder) external view returns (uint256) {
        return _ceilingFor(_builders[builder].tier);
    }

    /// Tier is the count of bond thresholds met: 0 means unbonded and unable to take
    /// capital at all.
    function _tierFor(uint256 bond) internal view returns (uint8 tier) {
        for (uint256 i; i < 3; ++i) {
            if (bond >= requiredBond(i + 1)) tier = uint8(i + 1);
        }
    }

    /// USDC a builder must post to reach `tier`, after any $AGENT discount.
    ///
    /// Identical to `tierBonds[tier - 1]` while the discount is off, which is its
    /// permanent state until $AGENT exists. Routed through a function rather than read
    /// directly so that turning the discount on later changes one place instead of
    /// every tier comparison, and so the disabled path is the one under test today.
    function requiredBond(uint256 tier) public view returns (uint256) {
        if (tier == 0 || tier > 3) return 0;
        uint256 full = tierBonds[tier - 1];
        if (agentBondDiscountBps == 0) return full;
        return full - (full * agentBondDiscountBps) / Constants.BPS;
    }

    function _ceilingFor(uint8 tier) internal view returns (uint256) {
        return tier == 0 ? 0 : tierCeilings[tier - 1];
    }
}
