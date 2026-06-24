// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IEvidenceBackend} from "../interfaces/IComputeVerifier.sol";
import {ComputeWitnessLib} from "../ComputeWitnessLib.sol";

interface IAttestationRegistryView {
    function isAcceptedModelSpec(bytes32 modelSpec) external view returns (bool);
}

/// @title OptimisticEvidence — proofType 3, the on-chain half of optimistic compute proof.
/// @notice Real Freivalds matrix-product re-execution is off-chain (hanzo-engine); the trust
/// model is "assume honest, prove fraud cheaply". This contract is the on-chain commitment +
/// challenge/slash state machine that makes that economically sound:
///
///   submit(reportData, activationTraceRoot, modelWeightsRoot){bond}  (the PROVER, staked)
///     records the commitment, escrows a bond, opens a challenge window.
///   attests(reportData)  (the CONSUMER, via the verifier, view)
///     true iff a non-fraudulent commitment exists for reportData.
///   challenge(reportData, index, A, B, C, merkleProof)  (ANY watcher, permissionless)
///     a re-executor that found a fabricated matmul EXHIBITS it; the contract re-checks inclusion
///     + Freivalds on-chain (ComputeWitnessLib) and, iff the proof holds, marks the commitment
///     FRAUDULENT and TAKES the bond. Fraud flips attests() to false → the gated mint can no
///     longer occur (or, if it already did under the optimistic assumption, the slashed bond is
///     the compensation). No "trust the watcher": the EVM verifies the discrepancy itself.
///   reclaim(reportData)  (the PROVER, after the window, if un-challenged)
///     returns the bond.
///
/// State: None → Pending(bonded) → {Fraudulent | Reclaimable-and-reclaimed}. Each reportData
/// is one-shot: a fraudulent or reclaimed commitment cannot be re-submitted (no laundering a
/// slashed claim by re-posting). reportData is the join key — the SAME value the binding and
/// every other backend use.
///
/// SECURITY (CEI + pull-of-funds at the boundary):
///   - bond moves out exactly once, to exactly one party (challenger on fraud, prover on
///     reclaim), with the state flipped BEFORE the transfer (no reentrancy re-claim).
///   - a zero-bond commitment is rejected: fraud must always have something to slash, so a
///     liar always has skin in the game.
///   - modelWeightsRoot is required to be a governed-accepted model spec and to be non-zero,
///     and activationTraceRoot non-zero, so a degenerate empty commitment can't be parked.
contract OptimisticEvidence is IEvidenceBackend {
    /// @notice Minimum bond a prover must escrow. Governs the cost of lying; the slash makes a
    /// false claim strictly unprofitable once watched. Immutable: protocol-level economic
    /// constant, not an admin knob.
    uint256 public immutable minBond;

    /// @notice Seconds the challenge window stays open after submit. A consumer wanting
    /// FINALITY (not just optimistic acceptance) reads {finalized}; attests() is true during
    /// the window too (that is the optimistic part).
    uint64 public immutable challengeWindow;

    /// @notice The governed model-spec set: a commitment's claimed weights root must be in it.
    IAttestationRegistryView public immutable registry;

    enum State {
        None, //        0 — never submitted
        Pending, //     1 — committed + bonded, window open or closed-but-unresolved
        Fraudulent, //  2 — a challenger proved fraud and took the bond (terminal)
        Reclaimed //    3 — prover reclaimed the bond after an un-challenged window (terminal)
    }

    struct Commitment {
        State state; // packs with prover + deadline in one slot (1+20+8 = 29 bytes)
        address prover; // who staked
        uint64 deadline; // submit time + challengeWindow
        uint256 bond; // escrowed wei (full width — no truncation footgun on the slashable amount)
        bytes32 activationTraceRoot; // root of the activation trace the off-chain checker re-runs
        bytes32 modelWeightsRoot; // claimed measured weights root (== the binding's modelSpecHash)
        uint64 commitBlock; // block the commitment was mined in; blockhash(commitBlock) is the
        //                     challenge beacon — fixed AFTER the prover signed, so unpredictable to
        //                     it (a tx cannot contain its own block's hash) → no pre-fitting a C
        //                     that dodges the on-chain Freivalds check.
    }

    /// @notice reportData => its commitment. One per reportData, ever.
    mapping(bytes32 => Commitment) private _commitments;

    event Committed(
        bytes32 indexed reportData,
        address indexed prover,
        uint256 bond,
        uint64 deadline,
        bytes32 activationTraceRoot,
        bytes32 modelWeightsRoot
    );
    event Challenged(bytes32 indexed reportData, address indexed challenger, uint256 bondSlashed);
    event Reclaimed(bytes32 indexed reportData, address indexed prover, uint256 bond);

    error BondTooLow(uint256 sent, uint256 required);
    error AlreadyCommitted(bytes32 reportData);
    error ZeroReportData();
    error ZeroActivationTrace();
    error ModelSpecNotAccepted(bytes32 modelWeightsRoot);
    error NotPending(bytes32 reportData);
    error WindowClosed(bytes32 reportData);
    error WindowOpen(bytes32 reportData);
    error NotProver(address caller);
    error NotFraudulent(bytes32 reportData);
    error BeaconUnavailable();
    error TransferFailed();

    constructor(uint256 minBond_, uint64 challengeWindow_, address registry_) {
        require(minBond_ > 0, "minBond must be > 0");
        require(challengeWindow_ > 0, "window must be > 0");
        require(registry_ != address(0), "registry required");
        minBond = minBond_;
        challengeWindow = challengeWindow_;
        registry = IAttestationRegistryView(registry_);
    }

    /// @inheritdoc IEvidenceBackend
    function proofType() external pure override returns (uint8) {
        return 3;
    }

    /// @notice Post an optimistic commitment for `reportData`, staking a bond. Permissionless
    /// to call, but the bond binds the caller as the prover and the commitment is one-shot.
    /// @param reportData the binding value the off-chain output was produced under.
    /// @param activationTraceRoot root the off-chain Freivalds checker re-derives (must be set).
    /// @param modelWeightsRoot the measured weights root the run used (must be a governed model
    ///        spec — defense in depth: the same value is inside reportData, but a commitment
    ///        that names an un-accepted model is refused at the door).
    function submit(
        bytes32 reportData,
        bytes32 activationTraceRoot,
        bytes32 modelWeightsRoot
    ) external payable {
        if (msg.value < minBond) revert BondTooLow(msg.value, minBond);
        if (reportData == bytes32(0)) revert ZeroReportData();
        if (activationTraceRoot == bytes32(0)) revert ZeroActivationTrace();
        if (!registry.isAcceptedModelSpec(modelWeightsRoot)) revert ModelSpecNotAccepted(modelWeightsRoot);

        Commitment storage c = _commitments[reportData];
        // One-shot per reportData: a terminal (fraudulent/reclaimed) or live (pending)
        // commitment blocks re-submission, so a slashed liar cannot re-post the same claim.
        if (c.state != State.None) revert AlreadyCommitted(reportData);

        c.state = State.Pending;
        c.prover = msg.sender;
        c.bond = msg.value;
        c.deadline = uint64(block.timestamp) + challengeWindow;
        c.activationTraceRoot = activationTraceRoot;
        c.modelWeightsRoot = modelWeightsRoot;
        c.commitBlock = uint64(block.number);

        emit Committed(reportData, msg.sender, msg.value, c.deadline, activationTraceRoot, modelWeightsRoot);
    }

    /// @inheritdoc IEvidenceBackend
    /// @notice True iff a non-fraudulent commitment exists. A Reclaimed commitment also returns
    /// false: once the bond is gone there is nothing left to slash, so the optimistic guarantee
    /// has lapsed and the consumer must require a fresh, still-bonded proof. (A consumer needing
    /// hard finality should additionally check {finalized}.)
    function attests(bytes32 reportData, bytes calldata /*evidence*/) external view override returns (bool) {
        return _commitments[reportData].state == State.Pending;
    }

    /// @notice Hard-finality view: the window has closed and no fraud was proven. A pessimistic
    /// consumer (mint-only-after-finalization) gates on this instead of {attests}.
    function finalized(bytes32 reportData) external view returns (bool) {
        Commitment storage c = _commitments[reportData];
        return c.state == State.Pending && block.timestamp > c.deadline;
    }

    /// @notice Permissionless fraud proof, VERIFIED ON-CHAIN. A watcher that re-executed the
    /// committed trace and found a fabricated matmul exhibits it here: the opened matmul's exact
    /// operands `(A,B,C)` at `index`, plus its Merkle proof under the committed
    /// `activationTraceRoot`. {ComputeWitnessLib.provesFraud} accepts the challenge iff the matmul
    /// was COMMITTED (inclusion) AND its output is FABRICATED (`C != A·B`, caught by Freivalds over
    /// `F_p` under a challenge seeded by the commit-block hash — unpredictable to the prover, so it
    /// cannot pre-fit a dodging `C`). On success the commitment is FRAUDULENT (terminal) and the
    /// bond is paid to the challenger. This replaces the old "any non-empty bytes slashes" trust
    /// hole: an honest prover has no fabricated matmul, so it can never be slashed, and a liar is
    /// caught by the EVM itself — not by a watcher's say-so. Window-gated: after the window closes
    /// the commitment finalizes and is no longer slashable.
    function challenge(
        bytes32 reportData,
        uint256 index,
        ComputeWitnessLib.Matrix calldata a,
        ComputeWitnessLib.Matrix calldata b,
        ComputeWitnessLib.Matrix calldata c,
        bytes32[] calldata merkleProof
    ) external {
        Commitment storage cm = _commitments[reportData];
        if (cm.state != State.Pending) revert NotPending(reportData);
        if (block.timestamp > cm.deadline) revert WindowClosed(reportData);

        // The beacon is the commit block's hash — set after the prover signed, so it could not
        // have fit (A,B,C) to the challenge it seeds. Available for 256 blocks after commit.
        bytes32 bh = blockhash(cm.commitBlock);
        if (bh == bytes32(0)) revert BeaconUnavailable();
        bytes memory beacon = abi.encodePacked(bh, reportData);
        if (!ComputeWitnessLib.provesFraud(cm.activationTraceRoot, beacon, index, a, b, c, merkleProof)) {
            revert NotFraudulent(reportData);
        }

        // EFFECTS: flip to terminal-fraud and zero the bond BEFORE paying out.
        uint256 bond = cm.bond;
        cm.state = State.Fraudulent;
        cm.bond = 0;

        // INTERACTION: pay the slashed bond to the challenger.
        emit Challenged(reportData, msg.sender, bond);
        (bool ok, ) = payable(msg.sender).call{value: bond}("");
        if (!ok) revert TransferFailed();
    }

    /// @notice The prover reclaims the bond after an un-challenged window. The commitment stays
    /// finalizable-readable (state flips to Reclaimed, terminal) — its attestation guarantee has
    /// then lapsed, so the consumer must have already consumed it during the live window or it
    /// must be re-proven. Only the prover may reclaim; only after the deadline.
    function reclaim(bytes32 reportData) external {
        Commitment storage c = _commitments[reportData];
        if (c.state != State.Pending) revert NotPending(reportData);
        if (msg.sender != c.prover) revert NotProver(msg.sender);
        if (block.timestamp <= c.deadline) revert WindowOpen(reportData);

        // EFFECTS first.
        uint256 bond = c.bond;
        c.state = State.Reclaimed;
        c.bond = 0;

        // INTERACTION.
        emit Reclaimed(reportData, msg.sender, bond);
        (bool ok, ) = payable(msg.sender).call{value: bond}("");
        if (!ok) revert TransferFailed();
    }

    /// @notice Full commitment view for dashboards / off-chain watchers.
    function commitmentOf(bytes32 reportData) external view returns (Commitment memory) {
        return _commitments[reportData];
    }
}
