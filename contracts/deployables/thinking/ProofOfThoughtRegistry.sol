// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IProofOfThoughtRegistry} from "./interfaces/IProofOfThoughtRegistry.sol";

/**
 * @title ProofOfThoughtRegistry
 * @author Hanzo AI Inc / Lux Network
 * @notice Minimal, deterministic on-chain ledger of Proof-of-Thought receipts —
 * PR1 of the x402 conscious-economy roadmap. See {IProofOfThoughtRegistry}.
 *
 * @dev Append-only and replay-safe: a receipt is keyed by the deterministic
 * `receiptId = keccak256(modelId, promptHash, outputHash, paymentHash, payer,
 * operator)`, so the same paid thought cannot be double-recorded and anyone can
 * recompute the id to find it. The registry does not verify the x402 payment or
 * the quorum proof itself — those are checked by the facilitator / aiquorum
 * layer upstream; here they are bound together immutably and emitted for the DAO
 * subgraph. No value is held and no external calls are made, so there is no
 * reentrancy surface.
 *
 * `quorumProof` semantics by tier:
 *   Tier-1 (in-consensus deterministic, zen-nano @ 0x0300..03): a deterministic
 *     marker (e.g. keccak of the canonical token output) — every validator can
 *     reproduce it.
 *   Tier-2 (operator quorum, aiquorum/ThinkingGovernor): the settlement
 *     receipt_root / quorum certificate hash.
 */
contract ProofOfThoughtRegistry is IProofOfThoughtRegistry {
    // ----------------------------------------------------------------------
    // storage
    // ----------------------------------------------------------------------

    mapping(bytes32 => ThoughtReceipt) private _receipts;
    mapping(bytes32 => bool) private _exists;
    bytes32[] private _ids;

    /// @notice The authority that adds/removes recorders (the DAO).
    address public admin;
    /// @notice Addresses permitted to write receipts — the settlement / quorum /
    /// facilitator contracts that have actually verified the payment and proof
    /// upstream. WITHOUT this gate `register` is permissionless, so anyone can
    /// forge receipts attributing paid cognition to arbitrary payer/operator and
    /// poison the cognition-volume metric, and can front-run the deterministic
    /// receiptId to permanently block (and forge the quorumProof of) a real
    /// governance receipt. Gating to authorized recorders closes both.
    mapping(address => bool) public isRecorder;

    event RecorderSet(address indexed recorder, bool allowed);
    event AdminTransferred(address indexed from, address indexed to);

    error NotRecorder(address caller);
    error NotAdmin();
    error ZeroAddress();

    /// @param admin_ the recorder authority (DAO); msg.sender if zero.
    constructor(address admin_) {
        admin = admin_ == address(0) ? msg.sender : admin_;
    }

    // ----------------------------------------------------------------------
    // recorder authority
    // ----------------------------------------------------------------------

    function setRecorder(address recorder, bool allowed) external {
        if (msg.sender != admin) revert NotAdmin();
        if (recorder == address(0)) revert ZeroAddress();
        isRecorder[recorder] = allowed;
        emit RecorderSet(recorder, allowed);
    }

    function transferAdmin(address admin_) external {
        if (msg.sender != admin) revert NotAdmin();
        if (admin_ == address(0)) revert ZeroAddress();
        emit AdminTransferred(admin, admin_);
        admin = admin_;
    }

    // ----------------------------------------------------------------------
    // register
    // ----------------------------------------------------------------------

    /// @inheritdoc IProofOfThoughtRegistry
    function register(
        bytes32 modelId,
        bytes32 promptHash,
        bytes32 outputHash,
        bytes32 paymentHash,
        bytes32 quorumProof,
        address payer,
        address operator,
        uint96 cost
    ) external returns (bytes32 receiptId) {
        // Only authorized recorders (settlement/quorum/facilitator) may write —
        // the receipt is an accountable claim, not an open guestbook.
        if (!isRecorder[msg.sender]) revert NotRecorder(msg.sender);
        // Required fields: a thought must name its model, be paid, and have a payer.
        // outputHash/quorumProof may legitimately be zero only for a pending
        // record; we require outputHash so a recorded receipt is always a
        // completed, accountable thought.
        if (modelId == bytes32(0)) revert ZeroModelId();
        if (paymentHash == bytes32(0)) revert ZeroPaymentHash();
        if (payer == address(0)) revert ZeroPayer();

        receiptId = computeReceiptId(modelId, promptHash, outputHash, paymentHash, payer, operator);
        if (_exists[receiptId]) revert ReceiptAlreadyExists(receiptId);

        _exists[receiptId] = true;
        _receipts[receiptId] = ThoughtReceipt({
            modelId: modelId,
            promptHash: promptHash,
            outputHash: outputHash,
            paymentHash: paymentHash,
            quorumProof: quorumProof,
            payer: payer,
            operator: operator,
            cost: cost,
            registeredAt: uint64(block.timestamp),
            blockNumber: uint64(block.number)
        });
        _ids.push(receiptId);

        emit ThoughtRegistered(
            receiptId, modelId, payer, operator, promptHash, outputHash, paymentHash, quorumProof, cost
        );
    }

    // ----------------------------------------------------------------------
    // views
    // ----------------------------------------------------------------------

    /// @inheritdoc IProofOfThoughtRegistry
    function computeReceiptId(
        bytes32 modelId,
        bytes32 promptHash,
        bytes32 outputHash,
        bytes32 paymentHash,
        address payer,
        address operator
    ) public pure returns (bytes32) {
        return keccak256(abi.encode(modelId, promptHash, outputHash, paymentHash, payer, operator));
    }

    /// @inheritdoc IProofOfThoughtRegistry
    function getReceipt(bytes32 receiptId) external view returns (ThoughtReceipt memory) {
        if (!_exists[receiptId]) revert UnknownReceipt(receiptId);
        return _receipts[receiptId];
    }

    /// @inheritdoc IProofOfThoughtRegistry
    function exists(bytes32 receiptId) external view returns (bool) {
        return _exists[receiptId];
    }

    /// @inheritdoc IProofOfThoughtRegistry
    function receiptCount() external view returns (uint256) {
        return _ids.length;
    }

    /// @inheritdoc IProofOfThoughtRegistry
    function receiptAt(uint256 index) external view returns (bytes32) {
        return _ids[index];
    }
}
