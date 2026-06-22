// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IThinkingGovernor} from "./interfaces/IThinkingGovernor.sol";

/**
 * @title ThinkingReputation
 * @author Hanzo AI Inc / Lux Network
 * @notice Proof-of-AI reputation for thinking-validators — the on-chain,
 * continuous signal that replaces slashing-as-primary (Thinking Chains §7,
 * "Proof-of-AI: The AI Bitcoin"). A validator earns standing by AGREEING with
 * the settled canonical decision over time, and loses it by diverging. Bad
 * actors are routed around (their weight decays toward zero), not slashed — the
 * Bittensor lesson: pay for measured, ongoing answer quality rather than threaten
 * to burn capital, so heterogeneous/permissionless providers can participate.
 *
 * `weightBps` is an exponential moving average (EMA) of per-thought agreement,
 * in basis points [0, 10000]:
 *   agreed  this thought:  w <- w + alpha*(10000 - w)/10000   (rises toward 10000)
 *   diverged this thought: w <- w - alpha*w/10000             (decays toward 0)
 * where `alphaBps` sets responsiveness. New validators start at 0 and earn weight
 * by being right alongside the quorum (Yuma-style), so reputation must be earned,
 * never granted. "Agreement" = the validator's revealed (vote, confidenceBucket)
 * equals the thought's settled canonical pair — the same consensus key the
 * governor tallied.
 *
 * @dev Orthogonal by design (Rich Hickey): holds its own ledger, only READS the
 * governor's committed settled state (`getThought`, `getVerdicts`) and WRITES
 * reputation; it never touches the governor and changes no consensus outcome.
 * Permissionless + idempotent: anyone may call `recordSettled(taskId)` once a
 * thought is settled; each task is counted exactly once. Dissent is information
 * (constitutional Rule 9): divergence decays weight gently via the EMA — it is
 * not a punishment event, and an honest minority that is later vindicated recovers
 * as subsequent thoughts settle its way. Withholding (committed, never revealed)
 * is out of scope here — it is the one fault left to the optional bonded backstop.
 */
contract ThinkingReputation {
    IThinkingGovernor public immutable governor;

    /// @notice Full weight in basis points.
    uint32 public constant ONE = 10_000;

    /// @notice EMA responsiveness in bps (e.g. 2000 = 0.2): higher reacts faster
    /// to recent behavior, lower is steadier/longer-memory.
    uint32 public immutable alphaBps;

    /// @notice A validator's measured Proof-of-AI standing.
    struct Rep {
        uint32 weightBps; //    EMA of agreement-with-canonical, 0..10000
        uint32 participated; // settled thoughts this validator revealed in
        uint32 agreed; //       of those, how many matched the canonical pair
        uint64 lastTaskId1; //  (last task id recorded) + 1; 0 = never seen
        uint64 lastUpdated; //  block timestamp of last update
    }

    mapping(address => Rep) private _rep;
    mapping(uint256 => bool) public processed; // taskId => already recorded
    address[] private _known; //                enumerable set of measured validators
    mapping(address => bool) private _seen;

    event ReputationUpdated(
        address indexed operator, uint256 indexed taskId, bool agreed, uint32 weightBps
    );
    event ThoughtScored(uint256 indexed taskId, uint8 revealed, uint8 agreed);

    error NotSettled(uint256 taskId);
    error AlreadyProcessed(uint256 taskId);

    constructor(IThinkingGovernor governor_, uint32 alphaBps_) {
        require(alphaBps_ > 0 && alphaBps_ <= ONE, "alpha out of range");
        governor = governor_;
        alphaBps = alphaBps_;
    }

    /// @notice Fold the settled decision of `taskId` into every revealing
    /// validator's reputation. Reverts if not settled or already processed.
    function recordSettled(uint256 taskId) external {
        if (processed[taskId]) revert AlreadyProcessed(taskId);
        IThinkingGovernor.Thought memory t = governor.getThought(taskId);
        if (t.status != IThinkingGovernor.Status.Settled) revert NotSettled(taskId);
        processed[taskId] = true;

        IThinkingGovernor.Verdict[] memory vs = governor.getVerdicts(taskId);
        uint8 nAgreed;
        for (uint256 i; i < vs.length; ++i) {
            bool agreed = (vs[i].vote == t.canonicalVote && vs[i].confidenceBucket == t.canonicalBucket);
            if (agreed) ++nAgreed;
            _update(vs[i].operator, taskId, agreed);
        }
        emit ThoughtScored(taskId, uint8(vs.length), nAgreed);
    }

    /// @dev Apply one EMA step. The unsigned math keeps `weightBps` in [0, ONE]:
    /// agreed never exceeds ONE (w + alpha*(ONE-w)/ONE <= ONE); diverged never
    /// goes below 0 (w - alpha*w/ONE >= 0).
    function _update(address op, uint256 taskId, bool agreed) private {
        Rep storage r = _rep[op];
        if (!_seen[op]) {
            _seen[op] = true;
            _known.push(op);
        }
        uint256 w = r.weightBps;
        if (agreed) {
            w = w + (uint256(alphaBps) * (ONE - w)) / ONE;
            unchecked {
                r.agreed += 1;
            }
        } else {
            w = w - (uint256(alphaBps) * w) / ONE;
        }
        r.weightBps = uint32(w);
        unchecked {
            r.participated += 1;
        }
        r.lastTaskId1 = uint64(taskId) + 1;
        r.lastUpdated = uint64(block.timestamp);
        emit ReputationUpdated(op, taskId, agreed, r.weightBps);
    }

    // ----------------------------------------------------------------------
    // views — the visibility surface the DAO / dashboard reads
    // ----------------------------------------------------------------------

    /// @notice A validator's current Proof-of-AI weight (bps, 0..10000).
    function weightOf(address operator) external view returns (uint32) {
        return _rep[operator].weightBps;
    }

    /// @notice A validator's full reputation record.
    function repOf(address operator) external view returns (Rep memory) {
        return _rep[operator];
    }

    /// @notice Lifetime agreement rate (bps) — `agreed/participated`, 0 if never seen.
    function agreementRateBps(address operator) external view returns (uint32) {
        Rep storage r = _rep[operator];
        if (r.participated == 0) return 0;
        return uint32((uint256(r.agreed) * ONE) / r.participated);
    }

    /// @notice Number of validators ever measured.
    function knownCount() external view returns (uint256) {
        return _known.length;
    }

    /// @notice The validator address at `index` (measurement order), for enumeration.
    function knownAt(uint256 index) external view returns (address) {
        return _known[index];
    }
}
