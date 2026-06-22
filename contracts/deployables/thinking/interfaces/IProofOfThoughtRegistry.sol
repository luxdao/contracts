// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

/**
 * @title IProofOfThoughtRegistry
 * @author Hanzo AI Inc / Lux Network
 * @notice On-chain registry of Proof-of-Thought (PoT) receipts — the accountable
 * record that a paid cognitive act happened.
 *
 * @dev A PoT receipt is the join of three things the Thinking Chains stack
 * already produces separately:
 *   1. an x402 PAYMENT receipt  (paymentHash)  — the cognition was paid for,
 *   2. a MODEL output           (outputHash)   — what the cognition produced,
 *   3. a QUORUM / deterministic PROOF (quorumProof) — that it was produced
 *      under the agreed mechanism (operator quorum or in-consensus determinism).
 *
 * Recording all three under one `receiptId` makes every paid thought
 * inspectable on-chain: who paid, who served, which model, what it cost, and
 * the proof it was legitimate. This is the unit the ThinkingGovernor consumes,
 * the conservation tithe meters, and the recursive-upgrade loop audits.
 *
 * The registry stores nothing about HOW payment/quorum were verified — it is a
 * deterministic ledger of committed receipts. Verification of the x402 payment
 * and the quorum proof happens upstream (facilitator / aiquorum); this contract
 * binds them together immutably and emits them for indexers (the DAO subgraph
 * reads `ThoughtRegistered`).
 */
interface IProofOfThoughtRegistry {
    /// @notice A Proof-of-Thought receipt. `quorumProof` is opaque to the
    /// registry (a keccak-merkle root / settlement hash / deterministic marker
    /// from the producing layer); callers verify it before registering.
    struct ThoughtReceipt {
        bytes32 modelId; //      registered ModelSpec hash (which model thought)
        bytes32 promptHash; //   hash of the input (the question)
        bytes32 outputHash; //   hash of the canonical output (the answer)
        bytes32 paymentHash; //  x402 payment receipt hash (proof it was paid)
        bytes32 quorumProof; //  quorum/deterministic proof (proof it was legitimate)
        address payer; //        who paid for the cognition
        address operator; //     who served it (quorum aggregate addr, or 0 for Tier-1)
        uint96 cost; //          amount paid (wei), uint96 packs with operator
        uint64 registeredAt; //  block timestamp when recorded
        uint64 blockNumber; //   block height when recorded
    }

    /// @notice Emitted when a PoT receipt is recorded. The canonical on-chain
    /// "a paid thought happened" event the DAO/dashboards index.
    event ThoughtRegistered(
        bytes32 indexed receiptId,
        bytes32 indexed modelId,
        address indexed payer,
        address operator,
        bytes32 promptHash,
        bytes32 outputHash,
        bytes32 paymentHash,
        bytes32 quorumProof,
        uint96 cost
    );

    error ReceiptAlreadyExists(bytes32 receiptId);
    error UnknownReceipt(bytes32 receiptId);
    error ZeroModelId();
    error ZeroPaymentHash();
    error ZeroPayer();

    /// @notice Record a PoT receipt. `receiptId` is derived deterministically
    /// from (modelId, promptHash, outputHash, paymentHash, payer, operator) so
    /// the same paid thought cannot be registered twice (replay-safe), and
    /// anyone can recompute the id. Reverts if already present or required
    /// fields are zero. Returns the receiptId.
    function register(
        bytes32 modelId,
        bytes32 promptHash,
        bytes32 outputHash,
        bytes32 paymentHash,
        bytes32 quorumProof,
        address payer,
        address operator,
        uint96 cost
    ) external returns (bytes32 receiptId);

    /// @notice The deterministic id for a (modelId, promptHash, outputHash,
    /// paymentHash, payer, operator) tuple. Pure; recomputable off-chain.
    function computeReceiptId(
        bytes32 modelId,
        bytes32 promptHash,
        bytes32 outputHash,
        bytes32 paymentHash,
        address payer,
        address operator
    ) external pure returns (bytes32);

    /// @notice Read a recorded receipt. Reverts if unknown.
    function getReceipt(bytes32 receiptId) external view returns (ThoughtReceipt memory);

    /// @notice Whether a receipt has been recorded.
    function exists(bytes32 receiptId) external view returns (bool);

    /// @notice Total receipts recorded.
    function receiptCount() external view returns (uint256);

    /// @notice The receiptId at a given index (registration order), for enumeration.
    function receiptAt(uint256 index) external view returns (bytes32);
}
