// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IThinkingGovernor} from "./interfaces/IThinkingGovernor.sol";
import {IProofOfThoughtRegistry} from "./interfaces/IProofOfThoughtRegistry.sol";

/**
 * @title ThinkingChainObservatory
 * @author Hanzo AI Inc / Lux Network
 * @notice Read-only visibility surface over the thinking chain: one contract the
 * DAO dashboard (~/work/lux/dao) calls to SEE thinking-chain behavior in a few
 * RPC calls instead of dozens. It composes the two on-chain organs —
 * {ThinkingGovernor} (operator-LLM quorum that decides DAO knobs) and
 * {ProofOfThoughtRegistry} (the cognition ledger) — into batched,
 * dashboard-ready structs.
 *
 * This is the "show it all on chain / visibility into thinking chain behavior is
 * KEY" seam: every governance decision the thinking validators reach, and every
 * paid thought the network settles, is summarized here for human inspection.
 *
 * @dev Pure read, orthogonal (Rich Hickey): it holds no state, touches NEITHER
 * contract's internals, makes no writes. It only batches existing public views
 * (`taskCount`+`getThought`, `receiptCount`+`receiptAt`+`getReceipt`,
 * `minBond`/`openFee`/`treasury`). All functions are `view` and intended for
 * off-chain `eth_call` (the overview tally iterates all tasks — unbounded by
 * design, but free off-chain; `recentThoughts`/`recentReceipts` are explicitly
 * paginated for on-chain composability). Task ids are 0-based (`getThought(i)`,
 * i in `[0, taskCount)`).
 */
contract ThinkingChainObservatory {
    IThinkingGovernor public immutable governor;
    IProofOfThoughtRegistry public immutable registry;

    /// @notice Whole-network thinking summary — the dashboard header.
    struct Overview {
        uint256 taskCount; //       governance thoughts ever opened
        uint256 openCount; //       still accepting verdicts
        uint256 settledCount; //    quorum reached, knob decided
        uint256 failedCount; //     settled with no quorum
        uint256 thoughtReceipts; // total PoT receipts (cognition volume)
        uint256 minBond; //         operator stake floor
        uint256 openFee; //         cost to open a thought
        address treasury; //        where fees accrue
    }

    /// @notice Compact dashboard row for one governance thought.
    struct ThoughtView {
        uint256 taskId;
        bytes32 modelSpecHash; //     which model the operators ran
        bytes32 promptHash; //        the governance question (audit)
        string knobKey; //            the governed parameter
        IThinkingGovernor.Status status;
        IThinkingGovernor.Vote canonicalVote; // decided vote (Invalid until settled)
        uint16 canonicalBucket; //    decided confidence (bps)
        uint8 n; //                   committee size
        uint8 threshold; //           quorum needed
        uint8 submissionCount; //     verdicts in so far
        uint8 agreeCount; //          size of the winning group
        uint64 openedAt;
        uint64 deadline;
    }

    constructor(IThinkingGovernor governor_, IProofOfThoughtRegistry registry_) {
        governor = governor_;
        registry = registry_;
    }

    /// @notice Whole-network thinking summary. Iterates all tasks to tally
    /// lifecycle counts — off-chain `eth_call` only.
    function overview() external view returns (Overview memory o) {
        uint256 tc = governor.taskCount();
        o.taskCount = tc;
        for (uint256 i = 0; i < tc; ++i) {
            IThinkingGovernor.Status s = governor.getThought(i).status;
            if (s == IThinkingGovernor.Status.Open) {
                ++o.openCount;
            } else if (s == IThinkingGovernor.Status.Settled) {
                ++o.settledCount;
            } else if (s == IThinkingGovernor.Status.Failed) {
                ++o.failedCount;
            }
        }
        o.thoughtReceipts = registry.receiptCount();
        o.minBond = governor.minBond();
        o.openFee = governor.openFee();
        o.treasury = governor.treasury();
    }

    /// @notice The compact view for one governance thought.
    function thoughtView(uint256 taskId) public view returns (ThoughtView memory v) {
        IThinkingGovernor.Thought memory t = governor.getThought(taskId);
        v = ThoughtView({
            taskId: taskId,
            modelSpecHash: t.modelSpecHash,
            promptHash: t.promptHash,
            knobKey: t.knobKey,
            status: t.status,
            canonicalVote: t.canonicalVote,
            canonicalBucket: t.canonicalBucket,
            n: t.n,
            threshold: t.threshold,
            submissionCount: t.submissionCount,
            agreeCount: t.agreeCount,
            openedAt: t.openedAt,
            deadline: t.deadline
        });
    }

    /// @notice The most recent `limit` governance thoughts, newest first
    /// (descending task id). Returns fewer if fewer exist.
    function recentThoughts(uint256 limit) external view returns (ThoughtView[] memory out) {
        uint256 tc = governor.taskCount();
        uint256 k = limit < tc ? limit : tc;
        out = new ThoughtView[](k);
        for (uint256 i = 0; i < k; ++i) {
            out[i] = thoughtView(tc - 1 - i); // newest first
        }
    }

    /// @notice The most recent `limit` Proof-of-Thought receipts, newest first
    /// (descending registration order). Returns fewer if fewer exist.
    function recentReceipts(uint256 limit)
        external
        view
        returns (IProofOfThoughtRegistry.ThoughtReceipt[] memory out)
    {
        uint256 rc = registry.receiptCount();
        uint256 k = limit < rc ? limit : rc;
        out = new IProofOfThoughtRegistry.ThoughtReceipt[](k);
        for (uint256 i = 0; i < k; ++i) {
            bytes32 id = registry.receiptAt(rc - 1 - i); // newest first
            out[i] = registry.getReceipt(id);
        }
    }

    /// @notice Convenience passthrough: the current on-chain value of a governed
    /// knob (the live result of all settled thinking about it).
    function knob(bytes32 modelSpecHash, string calldata key) external view returns (bytes32) {
        return governor.getKnob(modelSpecHash, key);
    }
}
