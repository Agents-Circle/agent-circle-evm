// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

/// Launch parameters, locked. These are the same numbers the Solana implementation runs
/// with; the two must not drift.
library Constants {
    uint256 internal constant BPS = 10_000;

    // ── economics at launch
    uint16 internal constant DEFAULT_LISTING_FEE_BPS = 0;
    uint16 internal constant DEFAULT_PERFORMANCE_FEE_BPS = 1_000; // 10% of profit
    uint16 internal constant DEFAULT_BUILDER_SPLIT_BPS = 8_000; // 80 builder / 20 platform
    uint16 internal constant DEFAULT_POSITION_CAP_BPS = 1_200; // 12% of vault per position
    uint16 internal constant DEFAULT_MAX_DRAWDOWN_BPS = 1_500; // 15% from high-water mark

    /// Per-trade fee on notional, split evenly between builder and platform.
    ///
    /// The second revenue line, and the one that needs the most care in how it is
    /// described. It is charged on *notional that actually traded* — not on capital under
    /// management — so it is not a management fee, and the commitment in the spec that a
    /// management fee is "deliberately absent" still holds. A vault sitting idle pays
    /// nothing, however long it sits.
    ///
    /// It does create an incentive the performance fee does not: a builder earns on
    /// turnover whether or not the turnover made money. Three things are meant to hold
    /// that in check, and none of them is in this file — net-of-fee ranking, mandatory
    /// turnover display on every listing, and an automatic flag when a listing's fees
    /// exceed its gross profit over thirty days. The guardrail below is the floor under
    /// those, not a substitute for them.
    uint16 internal constant DEFAULT_EXECUTION_FEE_BPS = 2; // 0.02% of notional
    uint16 internal constant DEFAULT_EXECUTION_BUILDER_SPLIT_BPS = 5_000; // 50 / 50

    /// Share of a slashed bond that goes to harmed traders rather than the treasury.
    uint16 internal constant SLASH_TRADER_BPS = 7_000;

    // ── guardrails governance itself cannot exceed
    //
    // A multisig is a smaller attack surface than a single key, not a safe one. These
    // bounds mean a fully compromised multisig still cannot set a 100% performance fee
    // and drain every vault through the fee path.
    uint16 internal constant MAX_LISTING_FEE_BPS = 500;
    uint16 internal constant MAX_PERFORMANCE_FEE_BPS = 2_000;
    uint16 internal constant MIN_BUILDER_SPLIT_BPS = 5_000;
    uint16 internal constant MAX_POSITION_CAP_BPS = 2_500;
    uint16 internal constant MAX_DRAWDOWN_BPS_CEILING = 5_000;

    /// Five times the launch value, and deliberately low in absolute terms: at 10 bps an
    /// agent turning the vault over daily would cost a trader ~36% a year, which is the
    /// point at which the fee stops being a cost of doing business and becomes the
    /// business. Governance can tune within this; it cannot make churn profitable.
    uint16 internal constant MAX_EXECUTION_FEE_BPS = 10;

    /// Equal to the default, so the builder's half of the execution fee is a floor rather
    /// than a starting point. Governance may raise the builder's share and never cut it.
    uint16 internal constant MIN_EXECUTION_BUILDER_SPLIT_BPS = 5_000;

    // ── timing
    uint64 internal constant DEFAULT_UNBOND_PERIOD = 14 days;
    uint64 internal constant MAX_UNBOND_PERIOD = 90 days;
    uint64 internal constant FEE_ASSESSMENT_INTERVAL = 7 days;
    uint64 internal constant VENUE_TIMELOCK_DELAY = 2 days;

    /// Longest an authorised-but-unsettled order may sit on a venue's book.
    ///
    /// A reservation cannot be decremented as fills arrive — a settlement-time signature
    /// check may only read state, never write it — so every authorised order holds its
    /// full worst-case cost until it expires or is cancelled. Short lifetimes are how
    /// that imprecision is kept cheap, and they also bound how stale the state behind a
    /// signature can be.
    uint64 internal constant MAX_ORDER_LIFETIME = 1 hours;

    /// Most orders one vault may have outstanding at once.
    ///
    /// A reservation holds a trader's capital until it is cancelled or expires, and there
    /// is no floor on an order's size — so without this an agent could authorise ten
    /// thousand one-wei orders and leave the trader's exit gated on clearing them all.
    /// The bound is what makes `cancelOrders` a single affordable transaction, and it is
    /// the difference between a reservation being an inconvenience and being a lock.
    uint8 internal constant MAX_OPEN_ORDERS = 8;
}
