// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

/// @title ComputeProfile — the ONE place that maps a tier to its required proof strength.
/// @notice The policy axis, decoupled from the binding ({ComputeProofLib}), the backends
/// ({IEvidenceBackend}), and the economics (miners). This is the on-chain analogue of the Go
/// `RefuseUnderStrictPQ` gate: a single function, in a single contract, decides "what does a
/// task at this tier need?" — so the rule lives in exactly one location and every consumer
/// reads it the same way.
///
///   requiredProofType(tier) == 0  → PERMISSIVE: no compute proof required (the default for
///       every unconfigured tier, so existing behavior — and existing tests — are unchanged
///       until governance opts a tier in).
///   requiredProofType(tier) == k  → a valid proof of proofType k is mandatory; k matches the
///       backend slots (1=CC-TEE, 2=zkML, 3=optimistic, 4=M-of-N TEE).
///
/// Governance raises a tier's bar by setting its required proofType. Lowering back to 0 is
/// possible (a tier can be de-gated) but the only way to mint under a gated tier is a proof
/// the {ComputeVerifier} accepts. Fail-secure: an unset tier returns 0 = permissive by design
/// (matching RefuseUnderStrictPQ's "permissive unless explicitly opted in"); a DEPLOYMENT that
/// wants strictness sets its tiers at construction/genesis, never relies on the default.
contract ComputeProfile {
    address public admin;

    /// @notice tier => required proofType. 0 (absent) = permissive. The whole policy.
    mapping(uint8 => uint8) private _required;

    event RequiredProofTypeSet(uint8 indexed tier, uint8 proofType);
    event AdminTransferred(address indexed from, address indexed to);

    error NotAdmin();

    constructor(address admin_) {
        admin = admin_ == address(0) ? msg.sender : admin_;
    }

    /// @notice Set the proof strength a tier demands. proofType 0 de-gates the tier.
    function setRequiredProofType(uint8 tier, uint8 proofType) external {
        if (msg.sender != admin) revert NotAdmin();
        _required[tier] = proofType;
        emit RequiredProofTypeSet(tier, proofType);
    }

    function transferAdmin(address admin_) external {
        if (msg.sender != admin) revert NotAdmin();
        emit AdminTransferred(admin, admin_);
        admin = admin_;
    }

    /// @notice The proof type a tier requires (0 = none/permissive). The single source of the
    /// tier→proof policy; every miner gates on this.
    function requiredProofType(uint8 tier) external view returns (uint8) {
        return _required[tier];
    }
}
