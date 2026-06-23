// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {ComputeProof} from "../ComputeProofLib.sol";

/// @title IEvidenceBackend — a swappable proof-system SLOT.
/// @notice One backend per proofType (1=CC-TEE, 2=zkML, 3=optimistic, 4=M-of-N TEE). The
/// {ComputeVerifier} dispatches to the registered backend AFTER it has already enforced the
/// two backend-independent invariants — the reportData binding and runtime-measurement
/// membership — so a backend ONLY answers the backend-specific question: "does this evidence
/// witness this reportData?". This is the orthogonality line: binding ⊥ membership ⊥ witness.
interface IEvidenceBackend {
    /// @notice The proofType this backend serves. The verifier rejects a mismatch.
    function proofType() external view returns (uint8);

    /// @notice Does `evidence` witness `reportData` under this proof system, right now?
    /// MUST NOT re-derive the binding (the verifier already did) — only judge the witness.
    /// For optimistic evidence this is "recorded, bonded, and not (yet) proven fraudulent";
    /// for a TEE backend this is "an accepted attestation root vouched for this reportData".
    /// Pure-view: economics call it at consume time, so it reads state, never mutates.
    function attests(bytes32 reportData, bytes calldata evidence) external view returns (bool);
}

/// @title IComputeVerifier — the single compute-proof gate.
/// @notice "No valid compute proof → no mint" is THIS function returning false. It enforces,
/// in one place and one order:
///   (1) proof.reportData == expectedReportData  — the binding (challenge→model→input→output);
///   (2) runtimeMeasurement ∈ governed accepted set, and NOT revoked — kills cheap/wrong model
///       or temp!=0 sampler;
///   (3) the registered {IEvidenceBackend} for proof.proofType attests the evidence.
/// Economics (miners) call this and mint nothing on false. Backends are swappable; the
/// binding and the policy are not.
interface IComputeVerifier {
    /// @param proof the submitted compute proof (proofType, reportData, evidence).
    /// @param expectedReportData the value the consumer expects, computed from the work's
    ///        full binding via {ComputeProofLib.expectedReportData}.
    /// @param runtimeMeasurement the runtime+sampler measurement bound into reportData; checked
    ///        against the governed accepted set (defense in depth — it is also inside reportData,
    ///        but the verifier re-checks membership so a consumer can't be tricked into accepting
    ///        a binding it never validated the runtime of).
    /// @return ok true iff all three invariants hold.
    function verify(
        ComputeProof calldata proof,
        bytes32 expectedReportData,
        bytes32 runtimeMeasurement
    ) external view returns (bool ok);

    /// @notice The backend registered for a proofType (address(0) if none — verify returns
    /// false for an unregistered type, never reverts).
    function backendFor(uint8 proofType) external view returns (address);
}
