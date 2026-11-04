// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import { Constants } from "../../src/libraries/Constants.sol";
import { HighWaterMark } from "../../src/libraries/HighWaterMark.sol";

/// Machine-checked properties of `HighWaterMark`, for solc's SMTChecker (CHC engine, z3).
///
/// Not a Foundry test: nothing here is run by `forge test`. `script/formal/smtcheck.sh`
/// compiles this file with the model checker on, and every `assert` below must come back
/// "safe" — proved for every input that satisfies the `require`s, not sampled. The
/// `require`s are the preconditions, and they are the real ones: fees within the bounds
/// `Constants` gives governance, and balances below 2^128 (the vault keeps USDC at 1e6 in
/// a uint64, so 2^128 is far past anything reachable).
///
/// The property IDs (HWM-1 …) are the ones in the handbook's
/// `plans/verification/properties.md`. Change one here and change it there.
contract HighWaterMarkSMT {
    uint256 private constant LIMIT = 2 ** 128;

    function _pre(HighWaterMark.State memory s, uint16 feeBps, uint16 splitBps) private pure {
        require(s.balance < LIMIT && s.highWaterMark < LIMIT);
        require(feeBps <= Constants.MAX_PERFORMANCE_FEE_BPS);
        require(splitBps <= Constants.BPS);
    }

    /// HWM-1: the builder's and the platform's cuts always sum to exactly the fee.
    function splitSumsToTotal(uint256 balance, uint256 mark, uint16 feeBps, uint16 splitBps)
        external
        pure
    {
        HighWaterMark.State memory s = HighWaterMark.State(balance, mark);
        _pre(s, feeBps, splitBps);
        (, HighWaterMark.FeeSplit memory f) = HighWaterMark.assess(s, feeBps, splitBps);
        assert(f.builderCut + f.platformCut == f.total);
    }

    /// HWM-2: the fee is at most the fee rate times the profit above the mark, and after
    /// it the trader is never below the mark they started from.
    function feeBoundedByProfit(uint256 balance, uint256 mark, uint16 feeBps, uint16 splitBps)
        external
        pure
    {
        HighWaterMark.State memory s = HighWaterMark.State(balance, mark);
        _pre(s, feeBps, splitBps);
        (HighWaterMark.State memory after_, HighWaterMark.FeeSplit memory f) =
            HighWaterMark.assess(s, feeBps, splitBps);
        if (balance > mark) {
            assert(f.total * Constants.BPS <= (balance - mark) * feeBps);
            assert(f.total <= balance - mark);
            assert(after_.balance >= mark);
        }
    }

    /// HWM-3: at or below the mark there is no fee and nothing changes.
    function noFeeAtOrBelowMark(uint256 balance, uint256 mark, uint16 feeBps, uint16 splitBps)
        external
        pure
    {
        HighWaterMark.State memory s = HighWaterMark.State(balance, mark);
        _pre(s, feeBps, splitBps);
        require(balance <= mark);
        (HighWaterMark.State memory after_, HighWaterMark.FeeSplit memory f) =
            HighWaterMark.assess(s, feeBps, splitBps);
        assert(f.total == 0 && f.builderCut == 0 && f.platformCut == 0);
        assert(after_.balance == balance && after_.highWaterMark == mark);
    }

    /// HWM-4: the same profit is never charged twice. Assessing again straight after an
    /// assessment charges nothing, and the mark never falls.
    function noDoubleCharge(uint256 balance, uint256 mark, uint16 feeBps, uint16 splitBps)
        external
        pure
    {
        HighWaterMark.State memory s = HighWaterMark.State(balance, mark);
        _pre(s, feeBps, splitBps);
        (HighWaterMark.State memory once,) = HighWaterMark.assess(s, feeBps, splitBps);
        assert(once.highWaterMark >= mark);
        (, HighWaterMark.FeeSplit memory again) = HighWaterMark.assess(once, feeBps, splitBps);
        assert(again.total == 0);
    }

    /// HWM-5: a deposit is never profit. It moves balance and mark together, so the
    /// distance between them, and so any fee, is unchanged.
    function depositIsNotProfit(uint256 balance, uint256 mark, uint256 amount) external pure {
        HighWaterMark.State memory s = HighWaterMark.State(balance, mark);
        require(balance < LIMIT && mark < LIMIT && amount < LIMIT);
        HighWaterMark.State memory d = HighWaterMark.onDeposit(s, amount);
        assert(d.balance - balance == d.highWaterMark - mark);
        assert((d.balance > d.highWaterMark) == (balance > mark));
        if (balance > mark) assert(d.balance - d.highWaterMark == balance - mark);
    }

    /// HWM-6: a withdrawal never raises the mark, and never manufactures profit: the
    /// trader is above the mark afterwards only if they were before.
    function withdrawNeverCreatesProfit(uint256 balance, uint256 mark, uint256 amount)
        external
        pure
    {
        HighWaterMark.State memory s = HighWaterMark.State(balance, mark);
        require(balance < LIMIT && mark < LIMIT && amount <= balance);
        HighWaterMark.State memory w = HighWaterMark.onWithdraw(s, amount);
        assert(w.highWaterMark <= mark);
        assert(w.balance == balance - amount);
        // Above the mark and withdrawing less than it: the profit above the mark is kept
        // exactly, so the withdrawal neither creates nor destroys a fee.
        if (balance >= mark && amount < mark) {
            assert(w.balance - w.highWaterMark == balance - mark);
        }
        // At or below the mark: still at or below it afterwards.
        if (balance <= mark) assert(w.balance <= w.highWaterMark || w.highWaterMark == 0);
    }

    /// HWM-7: drawdown is a share of the mark, so it never exceeds 100%.
    function drawdownAtMostAll(uint256 balance, uint256 mark) external pure {
        HighWaterMark.State memory s = HighWaterMark.State(balance, mark);
        require(balance < LIMIT && mark < LIMIT);
        assert(HighWaterMark.drawdownBps(s) <= Constants.BPS);
    }
}
