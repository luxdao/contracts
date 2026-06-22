// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IThinkingGovernor} from "./interfaces/IThinkingGovernor.sol";
import {IProofOfThoughtRegistry} from "./interfaces/IProofOfThoughtRegistry.sol";

/**
 * @title GovernancePoTBridge
 * @author Hanzo AI Inc / Lux Network
 * @notice Turns a SETTLED ThinkingGovernor decision into a queryable on-chain
 * Proof-of-Thought receipt. This is the visibility seam the conscious-network
 * roadmap calls for: every governance decision reached by operator-LLM quorum
 * becomes a permanent, indexable PoT record (the DAO subgraph / dashboards read
 * `ThoughtRegistered`), joining the {ThinkingGovernor} verdict to the
 * {ProofOfThoughtRegistry} cognitive ledger.
 *
 * @dev Orthogonal by design (Rich Hickey): it touches NEITHER the governor nor
 * the registry's internals — it only READS the governor's committed settled
 * state and WRITES one receipt. Anyone may call `recordThought(taskId)` once a
 * task is settled; the registry's deterministic id makes it idempotent (a second
 * call reverts `ReceiptAlreadyExists`). Permissionless and stateless.
 *
 * PoT field mapping for a governance thought:
 *   modelId     = thought.modelSpecHash  (which model the operators ran)
 *   promptHash  = thought.promptHash     (the governance question)
 *   outputHash  = consensusHash(modelSpec, canonicalVote, canonicalBucket)
 *                 (the decided {vote, confidence} — byte-identical to the Go
 *                  operator's governance consensus hash)
 *   paymentHash = keccak("lux/governance-settlement/v1", taskId)
 *                 (governance settlement marker; x402 payment binding arrives
 *                  with the paid-quorum market, roadmap PR6)
 *   quorumProof = thought.evidenceRoot   (merkle root of agreeing evidence)
 *   payer       = thought.opener         (who opened/funded the thought)
 *   operator    = the governor           (the on-chain settler of the quorum)
 *   cost        = 0                       (no x402 cost yet)
 */
contract GovernancePoTBridge {
    IThinkingGovernor public immutable governor;
    IProofOfThoughtRegistry public immutable registry;

    /// @notice Domain tag for the governance settlement payment marker.
    bytes32 public constant GOV_SETTLEMENT_DOMAIN = keccak256("lux/governance-settlement/v1");

    error NotSettled(uint256 taskId);

    event GovernanceThoughtRecorded(uint256 indexed taskId, bytes32 indexed receiptId, bytes32 outputHash);

    constructor(IThinkingGovernor governor_, IProofOfThoughtRegistry registry_) {
        governor = governor_;
        registry = registry_;
    }

    /// @notice Record the settled governance decision for `taskId` as a PoT
    /// receipt. Reverts if the task is not settled. Idempotent (registry rejects
    /// a duplicate). Returns the receiptId.
    function recordThought(uint256 taskId) external returns (bytes32 receiptId) {
        IThinkingGovernor.Thought memory t = governor.getThought(taskId);
        if (t.status != IThinkingGovernor.Status.Settled) revert NotSettled(taskId);

        // The decided answer, hashed exactly as the operators' governance
        // consensus hash (so the PoT outputHash equals what was agreed).
        bytes32 outputHash =
            governor.consensusHash(t.modelSpecHash, uint8(t.canonicalVote), t.canonicalBucket);

        bytes32 paymentHash = keccak256(abi.encode(GOV_SETTLEMENT_DOMAIN, taskId));

        receiptId = registry.register(
            t.modelSpecHash, // modelId
            t.promptHash, //    promptHash
            outputHash, //      outputHash (the decision)
            paymentHash, //     paymentHash (governance settlement marker)
            t.evidenceRoot, //  quorumProof (agreeing-evidence merkle root)
            t.opener, //        payer (opened/funded the thought)
            address(governor), // operator (on-chain settler of the quorum)
            0 //                cost (no x402 yet)
        );

        emit GovernanceThoughtRecorded(taskId, receiptId, outputHash);
    }
}
