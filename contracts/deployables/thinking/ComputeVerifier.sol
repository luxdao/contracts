// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {ComputeProof} from "./ComputeProofLib.sol";
import {IComputeVerifier, IEvidenceBackend} from "./interfaces/IComputeVerifier.sol";

interface IRuntimeRegistryView {
    function isAcceptedRuntime(bytes32 runtimeMeasurement) external view returns (bool);
}

/// @title ComputeVerifier — the one compute-proof gate; binding ⊥ policy ⊥ backend.
/// @notice Every "may this mint?" question routes through {verify}. It enforces, in this exact
/// order, the two invariants that are TRUE for every proof system, then defers the system-
/// specific judgement to a swappable backend slot:
///
///   (1) BINDING:   proof.reportData == expectedReportData. This is the C1 fix — the proof is
///       welded to (task, model, prompt, output, runtime, operator, chain-context). A proof
///       for other work has a different reportData and fails here.
///   (2) POLICY:    runtimeMeasurement ∈ governed accepted runtimes (and not revoked). This is
///       the H2 fix — a cheap/wrong model or a non-zero-temp sampler yields a measurement that
///       governance never accepted. Checked here even though it is also inside reportData, so a
///       consumer cannot be steered into honoring a binding whose runtime it never validated.
///   (3) WITNESS:   the {IEvidenceBackend} registered for proof.proofType attests the evidence.
///
/// Backends are registered per proofType by admin (the swappable SLOTS: CC/zk/optimistic/M-of-N).
/// Unknown type or no backend → false, never a revert: the gate fails CLOSED and a consumer
/// reading a bool always denies. verify is view: economics call it at consume time.
contract ComputeVerifier is IComputeVerifier {
    address public admin;
    IRuntimeRegistryView public immutable registry;

    /// @notice proofType => backend. The dispatch table. address(0) = unsupported type.
    mapping(uint8 => address) private _backend;

    event BackendSet(uint8 indexed proofType, address indexed backend);
    event AdminTransferred(address indexed from, address indexed to);

    error NotAdmin();
    error ZeroRegistry();
    error BackendTypeMismatch(uint8 wanted, uint8 got);

    constructor(address registry_, address admin_) {
        if (registry_ == address(0)) revert ZeroRegistry();
        registry = IRuntimeRegistryView(registry_);
        admin = admin_ == address(0) ? msg.sender : admin_;
    }

    /// @notice Register (or clear, with address(0)) the backend for a proofType. The backend's
    /// self-reported {IEvidenceBackend.proofType} MUST equal the slot, so a CC backend cannot be
    /// wired into the optimistic slot by mistake.
    function setBackend(uint8 proofType, address backend) external {
        if (msg.sender != admin) revert NotAdmin();
        if (backend != address(0)) {
            uint8 got = IEvidenceBackend(backend).proofType();
            if (got != proofType) revert BackendTypeMismatch(proofType, got);
        }
        _backend[proofType] = backend;
        emit BackendSet(proofType, backend);
    }

    function transferAdmin(address admin_) external {
        if (msg.sender != admin) revert NotAdmin();
        emit AdminTransferred(admin, admin_);
        admin = admin_;
    }

    /// @inheritdoc IComputeVerifier
    function backendFor(uint8 proofType) external view override returns (address) {
        return _backend[proofType];
    }

    /// @inheritdoc IComputeVerifier
    function verify(
        ComputeProof calldata proof,
        bytes32 expectedReportData,
        bytes32 runtimeMeasurement
    ) external view override returns (bool ok) {
        // (1) BINDING — the proof must be FOR this exact work.
        if (proof.reportData != expectedReportData) return false;

        // (2) POLICY — the runtime+sampler must be governance-accepted (and not revoked).
        if (!registry.isAcceptedRuntime(runtimeMeasurement)) return false;

        // (3) WITNESS — dispatch to the backend slot for this proof system.
        address backend = _backend[proof.proofType];
        if (backend == address(0)) return false; // unsupported type → fail closed
        return IEvidenceBackend(backend).attests(proof.reportData, proof.evidence);
    }
}
