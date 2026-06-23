// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

/// @title AttestationRootRegistry — the governed sets the compute-proof gate trusts.
/// @notice Where {AIReceiptRoots} lets a free relayer ASSERT receipt roots (the C3 hole),
/// this registry GOVERNS the measurements a compute proof is allowed to claim. Admin (the
/// DAO / governance) curates three sets:
///
///   1. accepted MODEL SPECS    — measured model-weights roots that are "real enough" to mint
///      for. A cheap/wrong/un-measured model's spec is simply not in the set, so its proof's
///      reportData (which binds modelSpecHash) is rejected. This closes H2.
///   2. accepted RUNTIME MEASUREMENTS — runtime+sampler measurements. A run with temp!=0, a
///      tampered kernel, or an unpinned sampler produces a measurement that is not in the set.
///   3. accepted ATTESTATION ROOTS — for hardware-attested backends (CC-TEE / M-of-N TEE), the
///      root of trust (e.g. an NVIDIA/AMD device cert root) whose quotes the chain honors.
///
/// Plus a global REVOCATION set: a measurement/root added then later found compromised is
/// revoked WITHOUT being removed, so audit history is preserved and a fast kill-switch exists
/// independent of the add/remove bookkeeping. `isAccepted*` always excludes revoked values.
///
/// Membership IS the trust statement — exactly like {AIReceiptRoots.isKnownRoot} — but the
/// asserter here is GOVERNANCE, not an unprivileged relayer. That difference is the whole
/// point: a forged value can never enter the set without an admin tx.
contract AttestationRootRegistry {
    /// @notice Governance that curates the sets.
    address public admin;

    /// @notice Measured model-weights roots accepted for minting. Excludes revoked.
    mapping(bytes32 => bool) private _modelSpec;

    /// @notice Runtime+sampler measurements accepted for minting. Excludes revoked.
    mapping(bytes32 => bool) private _runtime;

    /// @notice Attestation roots (HW root-of-trust) accepted for TEE backends. Excludes revoked.
    mapping(bytes32 => bool) private _attestationRoot;

    /// @notice Global revocation set. A revoked value is never accepted regardless of which
    /// set it was added to. One-way (no un-revoke): a compromised value stays dead.
    mapping(bytes32 => bool) public isRevoked;

    event ModelSpecSet(bytes32 indexed modelSpec, bool accepted);
    event RuntimeSet(bytes32 indexed runtimeMeasurement, bool accepted);
    event AttestationRootSet(bytes32 indexed attestationRoot, bool accepted);
    event Revoked(bytes32 indexed value);
    event AdminTransferred(address indexed from, address indexed to);

    error NotAdmin();
    error ZeroValue();

    constructor(address admin_) {
        admin = admin_ == address(0) ? msg.sender : admin_;
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    // ---- curation (admin-only) -------------------------------------------------

    function setModelSpec(bytes32 modelSpec, bool accepted) external onlyAdmin {
        if (modelSpec == bytes32(0)) revert ZeroValue();
        _modelSpec[modelSpec] = accepted;
        emit ModelSpecSet(modelSpec, accepted);
    }

    function setRuntime(bytes32 runtimeMeasurement, bool accepted) external onlyAdmin {
        if (runtimeMeasurement == bytes32(0)) revert ZeroValue();
        _runtime[runtimeMeasurement] = accepted;
        emit RuntimeSet(runtimeMeasurement, accepted);
    }

    function setAttestationRoot(bytes32 attestationRoot, bool accepted) external onlyAdmin {
        if (attestationRoot == bytes32(0)) revert ZeroValue();
        _attestationRoot[attestationRoot] = accepted;
        emit AttestationRootSet(attestationRoot, accepted);
    }

    /// @notice Permanently revoke a value (kill-switch). Affects every set at once; not
    /// reversible. Use when a model/runtime/root is found compromised.
    function revoke(bytes32 value) external onlyAdmin {
        if (value == bytes32(0)) revert ZeroValue();
        isRevoked[value] = true;
        emit Revoked(value);
    }

    function transferAdmin(address admin_) external onlyAdmin {
        emit AdminTransferred(admin, admin_);
        admin = admin_;
    }

    // ---- membership views (revocation-aware) -----------------------------------

    function isAcceptedModelSpec(bytes32 modelSpec) external view returns (bool) {
        return _modelSpec[modelSpec] && !isRevoked[modelSpec];
    }

    function isAcceptedRuntime(bytes32 runtimeMeasurement) external view returns (bool) {
        return _runtime[runtimeMeasurement] && !isRevoked[runtimeMeasurement];
    }

    function isAcceptedAttestationRoot(bytes32 attestationRoot) external view returns (bool) {
        return _attestationRoot[attestationRoot] && !isRevoked[attestationRoot];
    }
}
