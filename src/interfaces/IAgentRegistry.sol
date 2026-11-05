// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

interface IAgentRegistry {
    enum ListingStatus {
        None,
        Vetting,
        Live,
        Rejected,
        Suspended,
        Delisted
    }

    struct Listing {
        address builder;
        address agentAuthority;
        ListingStatus status;
        uint16 performanceFeeBps;
        uint16 builderSplitBps;
        uint16 positionCapBps;
        uint16 maxDrawdownBps;
        // Placed here rather than appended so the fee fields stay together, and because
        // slot 1 had three spare bytes after `maxDrawdownBps`. The pair costs four, so
        // one lands in slot 1 and one joins `submittedAt` in slot 2 — four slots before,
        // four slots after.
        uint16 executionFeeBps;
        uint16 executionBuilderSplitBps;
        uint64 submittedAt;
        bytes32 metadataHash;
    }

    /// Everything governance sets on a listing at approval time.
    ///
    /// A struct rather than six positional `uint16`s, and not for tidiness: the six are
    /// mutually transposable at the call site, and transposing `builderSplitBps` with
    /// `positionCapBps` would be accepted by every bound in `_approveListing` while
    /// silently mispricing the listing. A multisig signer reading a decoded simulation
    /// should not have to count arguments. This also mirrors the Anchor side's
    /// `FeeConfig`, which the error names in `CircleErrors.sol` are already kept parallel to.
    struct Terms {
        uint16 performanceFeeBps;
        uint16 builderSplitBps;
        uint16 executionFeeBps;
        uint16 executionBuilderSplitBps;
        uint16 positionCapBps;
        uint16 maxDrawdownBps;
    }

    struct Builder {
        uint256 bondAmount;
        uint256 totalAum;
        uint256 unbondAmount;
        uint64 unbondRequestedAt;
        uint64 createdAt;
        uint16 slashCount;
        uint16 agentCount;
        uint8 tier;
        bool exists;
    }

    function getListing(bytes32 listingId) external view returns (Listing memory);
    function getBuilder(address builder) external view returns (Builder memory);

    /// Remaining headroom under the builder's tier ceiling, in quote-token units.
    function availableAumHeadroom(bytes32 listingId) external view returns (uint256);

    /// Called by the vault on deposit (positive) and withdrawal (negative).
    /// The AUM ceiling is enforced per-*builder* across all their listings, so it cannot
    /// be tracked inside a single vault.
    function notifyAumDelta(bytes32 listingId, int256 delta) external;
}
