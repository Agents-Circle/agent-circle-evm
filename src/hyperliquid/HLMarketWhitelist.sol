// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import { Errors } from "../libraries/Errors.sol";
import { Constants } from "../libraries/Constants.sol";

/// The set of HyperCore assets vaults are permitted to trade.
///
/// Structurally the same object as `VenueWhitelist`, and carries the same two defences
/// for the same reason — an allowlist whose compromise reaches every vault at once, and
/// the Drift precedent of April 2026 where months of social engineering yielded admin
/// control and the attacker whitelisted fake collateral:
///
///   1. A timelock on additions. Queued publicly, cannot execute for `delay`. A
///      compromised governance key buys the attacker an announcement, not the funds.
///   2. A guardian that can veto a queued addition and remove instantly, but can never
///      add. Least authority in the direction that matters.
///
/// Removals bypass the timelock deliberately. Waiting out a delay to stop an active
/// exploit is the wrong trade.
///
/// ## Why this is not just `VenueWhitelist` with a different key type
///
/// On Polygon a venue is an adapter contract and the question is binary: may vaults call
/// it or not. On HyperCore an asset is an integer, and the assets differ enormously in
/// how much size they can absorb. BTC perps take a vault's full position cap without
/// noticing. A HIP-3 equity perp or a HIP-4 outcome market may have a book so thin that
/// 12% of a large vault *is* the book — and a position that cannot be exited at anything
/// near its mark is not a position within its risk limit, whatever the arithmetic says.
///
/// So each asset carries its own cap, and the vault enforces the stricter of the two.
/// A whitelist that could only say yes or no would force governance to choose between
/// listing a thin market at full size or not listing it at all.
contract HLMarketWhitelist {
    struct Market {
        /// Tighter of the two caps wins at the vault. Zero means "no asset-specific cap",
        /// which is the right default for a deep market and must be set deliberately for
        /// a thin one.
        uint16 positionCapBps;
        bool listed;
    }

    struct Queued {
        uint64 eta;
        uint16 positionCapBps;
        bool vetoed;
        bool exists;
    }

    address public governance;
    address public guardian;
    uint64 public immutable delay;

    mapping(uint32 => Market) public markets;
    mapping(uint32 => Queued) public queued;

    event AdditionQueued(uint32 indexed asset, uint16 positionCapBps, uint64 eta);
    event AdditionExecuted(uint32 indexed asset, uint16 positionCapBps);
    event AdditionVetoed(uint32 indexed asset, address indexed by);
    event MarketRemoved(uint32 indexed asset, address indexed by);
    event MarketCapTightened(uint32 indexed asset, uint16 positionCapBps);
    event GuardianChanged(address indexed previous, address indexed next);

    modifier onlyGovernance() {
        if (msg.sender != governance) revert Errors.NotGovernance();
        _;
    }

    /// Governance is the normal path for removal; the guardian is the 3am path.
    modifier onlyGovernanceOrGuardian() {
        if (msg.sender != governance && msg.sender != guardian) revert Errors.NotGuardian();
        _;
    }

    constructor(address governance_, address guardian_, uint64 delay_) {
        if (governance_ == address(0) || guardian_ == address(0)) revert Errors.ZeroAddress();
        governance = governance_;
        guardian = guardian_;
        delay = delay_;
    }

    // ────────────────────────────────────────────────────────── additions

    function queueAddition(uint32 asset, uint16 positionCapBps) external onlyGovernance {
        if (positionCapBps > Constants.MAX_POSITION_CAP_BPS) revert Errors.ParameterOutOfBounds();

        uint64 eta = uint64(block.timestamp) + delay;
        queued[asset] =
            Queued({ eta: eta, positionCapBps: positionCapBps, vetoed: false, exists: true });
        emit AdditionQueued(asset, positionCapBps, eta);
    }

    function executeAddition(uint32 asset) external onlyGovernance {
        Queued memory q = queued[asset];
        if (!q.exists) revert Errors.TimelockNotQueued();
        if (q.vetoed) revert Errors.ProposalVetoed();
        if (block.timestamp < q.eta) revert Errors.TimelockNotElapsed();

        delete queued[asset];
        markets[asset] = Market({ positionCapBps: q.positionCapBps, listed: true });
        emit AdditionExecuted(asset, q.positionCapBps);
    }

    function vetoAddition(uint32 asset) external onlyGovernanceOrGuardian {
        if (!queued[asset].exists) revert Errors.TimelockNotQueued();
        queued[asset].vetoed = true;
        emit AdditionVetoed(asset, msg.sender);
    }

    /// No timelock. See the contract-level note.
    function removeMarket(uint32 asset) external onlyGovernanceOrGuardian {
        delete markets[asset];
        delete queued[asset];
        emit MarketRemoved(asset, msg.sender);
    }

    /// Tighten a listed market's cap with no delay, because tightening only ever reduces
    /// what vaults may do. Loosening is an addition in disguise and has to go back
    /// through the timelock, which is why there is no matching `loosen`: a thin market
    /// discovered to be thinner than it looked must be fixable in one transaction, and a
    /// market discovered to be deeper than it looked can wait two days.
    ///
    /// Zero is rejected here even though zero means "uncapped" in storage. Setting a
    /// listed market's cap to zero would silently *remove* its cap under the guise of
    /// tightening it — the one direction this function must not be able to go.
    function tightenMarketCap(uint32 asset, uint16 positionCapBps)
        external
        onlyGovernanceOrGuardian
    {
        Market storage m = markets[asset];
        if (!m.listed) revert Errors.VenueNotWhitelisted();
        if (positionCapBps == 0) revert Errors.ZeroAmount();

        uint16 current = m.positionCapBps;
        // An uncapped market (zero) may be given any valid cap; a capped one may only go
        // down. Both are a reduction in what the vault is permitted to do.
        if (current != 0 && positionCapBps >= current) revert Errors.RiskOverrideNotStricter();
        if (positionCapBps > Constants.MAX_POSITION_CAP_BPS) revert Errors.ParameterOutOfBounds();

        m.positionCapBps = positionCapBps;
        emit MarketCapTightened(asset, positionCapBps);
    }

    /// Deliberately immediate: a suspected-compromised guardian needs replacing faster
    /// than a timelock allows.
    function setGuardian(address next) external onlyGovernance {
        if (next == address(0)) revert Errors.ZeroAddress();
        emit GuardianChanged(guardian, next);
        guardian = next;
    }

    // ────────────────────────────────────────────────────────── views

    function isListed(uint32 asset) external view returns (bool) {
        return markets[asset].listed;
    }

    /// The cap a vault must hold itself to on this asset, given its own cap.
    ///
    /// Returns zero for an unlisted asset rather than reverting. The vault checks listing
    /// separately and with a named error; a cap read that reverted would make the two
    /// failures indistinguishable in a trace.
    function effectiveCapBps(uint32 asset, uint16 vaultCapBps) external view returns (uint16) {
        Market storage m = markets[asset];
        if (!m.listed) return 0;
        if (m.positionCapBps == 0) return vaultCapBps;
        return m.positionCapBps < vaultCapBps ? m.positionCapBps : vaultCapBps;
    }
}
