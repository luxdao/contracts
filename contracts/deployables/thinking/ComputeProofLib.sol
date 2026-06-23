// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

/// @notice A backend-agnostic proof that a specific output was produced by a specific
/// model+runtime for a specific input. `reportData` is the SAME 32 bytes across every
/// backend (TEE, zkML, optimistic) — it is the single value the whole enforcement layer
/// joins on; `evidence` is the backend-specific witness the matching {IEvidenceBackend}
/// understands. Decoupling the binding (this struct's reportData) from the witness
/// (evidence) is what lets the proof backend be swapped without touching the economics.
struct ComputeProof {
    uint8 proofType; // 1=CC-TEE, 2=zkML, 3=optimistic(Freivalds re-exec), 4=M-of-N TEE
    bytes32 reportData; // the binding (see {ComputeProofLib.reportData}); identical across backends
    bytes evidence; // backend-specific witness, decoded by the dispatched IEvidenceBackend
}

/// @title ComputeProofLib — the compute-proof BINDING, in pure Solidity.
/// @notice The spine of "no valid compute proof → no mint". A signature proves authorship;
/// THIS proves computation. The binding collapses (task, model, prompt, output, runtime,
/// operator, chain-context) into ONE 32-byte value, `reportData`, that every proof backend
/// must reproduce. Because the value is computed identically off-chain by the Go precompile
/// (precompile/computeattest) and the Rust hanzo-engine, a proof minted off-chain verifies
/// here BYTE-FOR-BYTE — the domain separators and keccak chain are pinned to match.
///
/// THE TWO-STEP CHAIN (raw-utf8 domains, NO length prefix — the exact idiom of
/// AICoinMiner.sol's DomainReceipt="lux/aivmbridge/receipt/v1"):
///
///   challenge  = keccak256( DOMAIN_CHALLENGE || taskId || intentID || modelSpecHash
///                           || promptHash || openBlockHash || operator )
///   reportData = keccak256( DOMAIN_REPORT   || challenge || modelSpecHash || promptHash
///                           || outputHash || runtimeMeasurement )
///
/// WHY TWO STEPS: the challenge fixes WHAT was asked (and to whom, in what chain context)
/// BEFORE the model runs; reportData then attests WHAT came out under WHICH measured model
/// and runtime. Folding the challenge into reportData means a proof for task A / operator X
/// can never be replayed for task B / operator Y — the whole context is inside the hash.
///
/// WIRE LAYOUT (the bytes the Go precompile + Rust engine MUST mirror exactly):
///   taskId            : uint256, 32 bytes big-endian
///   intentID          : bytes32, 32 bytes
///   modelSpecHash     : bytes32, 32 bytes (a MEASURED model-weights root)
///   promptHash        : bytes32, 32 bytes
///   openBlockHash     : bytes32, 32 bytes (chain context the challenge opened under)
///   operator          : address, 20 bytes (left-to-right, NOT left-padded)
///   challenge         : bytes32, 32 bytes
///   outputHash        : bytes32, 32 bytes
///   runtimeMeasurement: bytes32, 32 bytes (pins runtime + sampler: e.g. temp==0)
/// abi.encodePacked lays each out with no padding and address as its raw 20 bytes —
/// identical to the Go `append(buf, x.Bytes()...)` concatenation.
library ComputeProofLib {
    /// @notice Domain tag for the pre-execution challenge. Raw utf8, no length prefix.
    bytes internal constant DOMAIN_CHALLENGE = "lux/aivm/compute-challenge/v1";

    /// @notice Domain tag for the post-execution report. Raw utf8, no length prefix.
    bytes internal constant DOMAIN_REPORT = "lux/aivm/compute-report/v1";

    /// @notice The pre-execution challenge: binds the question, the operator, and the chain
    /// context the task opened under. Fixed BEFORE the model runs.
    function challenge(
        uint256 taskId,
        bytes32 intentID,
        bytes32 modelSpecHash,
        bytes32 promptHash,
        bytes32 openBlockHash,
        address operator
    ) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encodePacked(
                    DOMAIN_CHALLENGE,
                    taskId,
                    intentID,
                    modelSpecHash,
                    promptHash,
                    openBlockHash,
                    operator
                )
            );
    }

    /// @notice The post-execution report data: the single value every backend reproduces.
    /// Binds the challenge to the measured model, the input, the output, and the runtime.
    function reportData(
        bytes32 challenge_,
        bytes32 modelSpecHash,
        bytes32 promptHash,
        bytes32 outputHash,
        bytes32 runtimeMeasurement
    ) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encodePacked(
                    DOMAIN_REPORT,
                    challenge_,
                    modelSpecHash,
                    promptHash,
                    outputHash,
                    runtimeMeasurement
                )
            );
    }

    /// @notice One-shot: challenge ∘ reportData. The canonical value a consumer expects a
    /// proof to carry, given the full binding. A proof is valid for THIS work iff its
    /// `reportData` equals this return value.
    function expectedReportData(
        uint256 taskId,
        bytes32 intentID,
        bytes32 modelSpecHash,
        bytes32 promptHash,
        bytes32 openBlockHash,
        address operator,
        bytes32 outputHash,
        bytes32 runtimeMeasurement
    ) internal pure returns (bytes32) {
        bytes32 c = challenge(taskId, intentID, modelSpecHash, promptHash, openBlockHash, operator);
        return reportData(c, modelSpecHash, promptHash, outputHash, runtimeMeasurement);
    }

    /// @notice Decode a wire-encoded {ComputeProof}. The encoding is abi.encode of the tuple
    /// (uint8, bytes32, bytes) — the only structured field, so a single abi.decode is exact
    /// (and reverts on a malformed frame, no silent truncation).
    function decodeProof(bytes calldata raw) internal pure returns (ComputeProof memory p) {
        (p.proofType, p.reportData, p.evidence) = abi.decode(raw, (uint8, bytes32, bytes));
    }
}
