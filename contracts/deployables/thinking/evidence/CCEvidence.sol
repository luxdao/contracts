// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IEvidenceBackend} from "../interfaces/IComputeVerifier.sol";

interface IAttestationRegistryRootView {
    function isAcceptedAttestationRoot(bytes32 attestationRoot) external view returns (bool);
}

/// @title CCEvidence — proofType 1, Confidential-Compute (TEE) attestation backend.
/// @notice STUB FOR THE HEAVY CRYPTO, NOT FOR THE TRUST. The NVIDIA/AMD device cert-chain
/// verification (parsing the attestation report, walking the X.509/SPDM chain to the device
/// root, checking the measurement registers) is done in the Go precompile
/// `precompile/computeattest` — it is far too heavy for the EVM and lives where the consensus
/// engine can gas-meter it natively. What THIS contract enforces on-chain is the part that
/// MUST live in governed contract state and is the actual trust decision:
///
///   - the quote names an attestation root that GOVERNANCE has accepted
///     ({AttestationRootRegistry.isAcceptedAttestationRoot}); a self-signed or unknown-vendor
///     root is rejected.
///   - that root has VOUCHED for this exact reportData via {vouch} (called by the precompile/
///     bridge adapter that already verified the cert chain). An un-vouched reportData fails.
///
/// So it is NOT a no-op: the verifier's reportData binding + this contract's root-acceptance +
/// per-reportData vouch together mean a CC proof only stands for a reportData that a trusted
/// TEE actually attested. The `evidence` bytes carry the attestation-root id the quote chains
/// to; on-chain we check governance accepts it and that it vouched. The cert-chain math is the
/// stubbed half.
///
// TODO: NVIDIA cert-chain verification in the Go precompile precompile/computeattest
contract CCEvidence is IEvidenceBackend {
    /// @notice Governance-curated attestation roots.
    IAttestationRegistryRootView public immutable registry;

    /// @notice The privileged adapter (the computeattest precompile mirror / bridge) permitted
    /// to record a vouch after it has verified the device cert chain off the EVM. Set by admin;
    /// this is the seam where the heavy Go verification meets governed on-chain state.
    address public admin;
    mapping(address => bool) public isVoucher;

    /// @notice (attestationRoot, reportData) => the trusted root vouched this report. Both must
    /// hold for attests() to pass; the verifier additionally enforces the binding.
    mapping(bytes32 => mapping(bytes32 => bool)) public vouched;

    event VoucherSet(address indexed voucher, bool allowed);
    event Vouched(bytes32 indexed attestationRoot, bytes32 indexed reportData, address indexed voucher);
    event AdminTransferred(address indexed from, address indexed to);

    error NotAdmin();
    error NotVoucher(address caller);
    error RootNotAccepted(bytes32 attestationRoot);

    constructor(address registry_, address admin_) {
        require(registry_ != address(0), "registry required");
        registry = IAttestationRegistryRootView(registry_);
        admin = admin_ == address(0) ? msg.sender : admin_;
    }

    function setVoucher(address voucher, bool allowed) external {
        if (msg.sender != admin) revert NotAdmin();
        isVoucher[voucher] = allowed;
        emit VoucherSet(voucher, allowed);
    }

    function transferAdmin(address admin_) external {
        if (msg.sender != admin) revert NotAdmin();
        emit AdminTransferred(admin, admin_);
        admin = admin_;
    }

    /// @inheritdoc IEvidenceBackend
    function proofType() external pure override returns (uint8) {
        return 1;
    }

    /// @notice Record that an accepted attestation root vouched for `reportData`. Called by a
    /// voucher (the computeattest precompile adapter) AFTER it verified the device cert chain
    /// off-chain. Rejects a root governance has not accepted, so the heavy off-chain step still
    /// cannot vouch under an untrusted vendor root.
    function vouch(bytes32 attestationRoot, bytes32 reportData) external {
        if (!isVoucher[msg.sender]) revert NotVoucher(msg.sender);
        if (!registry.isAcceptedAttestationRoot(attestationRoot)) revert RootNotAccepted(attestationRoot);
        vouched[attestationRoot][reportData] = true;
        emit Vouched(attestationRoot, reportData, msg.sender);
    }

    /// @inheritdoc IEvidenceBackend
    /// @notice True iff the attestation root named in `evidence` is governance-accepted AND it
    /// vouched for this reportData. `evidence` is the 32-byte attestation-root id (abi-encoded).
    /// The binding itself is enforced by the verifier before this is reached.
    function attests(bytes32 reportData, bytes calldata evidence) external view override returns (bool) {
        if (evidence.length != 32) return false;
        bytes32 attestationRoot = abi.decode(evidence, (bytes32));
        if (!registry.isAcceptedAttestationRoot(attestationRoot)) return false;
        return vouched[attestationRoot][reportData];
    }
}
