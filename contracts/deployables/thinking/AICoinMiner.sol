// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {ComputeProof, ComputeProofLib} from "./ComputeProofLib.sol";

interface IAICoinMintable {
    function mintSubsidy(address to, uint256 amount) external;
    function emissionAllowance() external view returns (uint256);
}

interface IAIReceiptRootsView {
    function isKnownRoot(bytes32 root) external view returns (bool);
}

interface IComputeVerifierM {
    function verify(ComputeProof calldata proof, bytes32 expectedReportData, bytes32 runtimeMeasurement)
        external
        view
        returns (bool);
}

/// @title AICoinMiner — mine AICoin by proving verified A-Chain AI work, on ANY EVM.
/// @notice Real AI mining with NO trusted minter key. The Lux A-Chain (aivm) settles an
/// inference under its own consensus + provider quorum and commits a keccak merkle root
/// over the resulting receipts. This contract turns ONE committed receipt into a
/// fair-launch AICoin subsidy mint, after verifying — in PURE SOLIDITY, so the same code
/// runs on any EVM — that the receipt is included under a root this chain has accepted
/// ({AIReceiptRoots}). The receipt encoding, the receipt hash, the merkle leaf, and the
/// node folding are recomputed here BYTE-FOR-BYTE against the shared A<->C wire spec
/// (precompile/aivmbridge/{receipt,proof}.go), so "verify" is deterministic and host-
/// independent. A Lux EVM sources the root natively (the aivmbridge precompile at the
/// A->C atomic boundary); a foreign EVM sources it from a warp relay — the verification
/// is identical. Unified attestation in; subsidy out; one mechanism, every chain.
contract AICoinMiner {
    // ---- shared A<->C wire spec (pinned; must match precompile/aivmbridge byte-for-byte)
    bytes internal constant DOMAIN_RECEIPT = "lux/aivmbridge/receipt/v1"; // keccak domain, raw utf8, no length prefix
    uint16 internal constant RECEIPT_VERSION = 1;
    uint256 internal constant RECEIPT_LEN = 355; // fixed-width canonical encoding
    uint8 internal constant STATUS_COMPLETED = 2; // only a completed receipt is actionable
    uint256 internal constant MAX_PROOF_DEPTH = 64;
    // field offsets into the 355-byte canonical receipt encoding
    uint256 internal constant OFF_INTENT = 2; // after u16 Version
    uint256 internal constant OFF_TASKID = 34; // ...+IntentID(32)
    uint256 internal constant OFF_REQUESTER = 130; // Version+IntentID+TaskID+CChainID+AChainID
    uint256 internal constant OFF_MODELSPEC = 150; // ...+Requester(20)
    uint256 internal constant OFF_PROMPT = 182; // ...+ModelSpecHash(32)
    uint256 internal constant OFF_OUTPUT = 214; // ...+PromptHash(32)
    uint256 internal constant OFF_STATUS = 246; // ...+CanonicalOutputHash(32)

    IAICoinMintable public immutable coin;
    IAIReceiptRootsView public immutable roots;

    /// @notice The compute-proof gate. A forged receipt root alone no longer mints (the C3
    /// hole): mine() ALSO requires a valid {ComputeProof} binding the receipt's measured model,
    /// prompt, and output under a governance-accepted runtime. address(0) ⇒ proof enforcement
    /// disabled (the pre-enforcement deployment); when set, every mint is gated on a proof.
    IComputeVerifierM public immutable verifier;

    address public admin;

    /// @notice Subsidy minted per verified completed receipt (governable). Clamped down to
    /// the vested halving allowance at mint time, so issuance never exceeds the schedule.
    uint256 public rewardPerReceipt;

    /// @notice intentID => already mined. One subsidy per settled A-Chain intent (the
    /// A-Chain itself binds one receipt per intent; this is the C-side replay guard).
    mapping(bytes32 => bool) public consumed;

    event Mined(bytes32 indexed intentID, address indexed requester, uint256 amount, bytes32 indexed root);
    event RewardSet(uint256 amount);
    event AdminTransferred(address indexed from, address indexed to);

    error NotAdmin();
    error BadReceiptLength();
    error BadVersion();
    error NotCompleted();
    error ZeroOutput();
    error UnknownRoot(bytes32 root);
    error BadProof();
    error AlreadyMined(bytes32 intentID);
    error NothingToMint();
    error InvalidComputeProof();
    error ProofGateUnavailable();

    constructor(
        IAICoinMintable coin_,
        IAIReceiptRootsView roots_,
        address admin_,
        uint256 rewardPerReceipt_,
        IComputeVerifierM verifier_
    ) {
        coin = coin_;
        roots = roots_;
        admin = admin_ == address(0) ? msg.sender : admin_;
        rewardPerReceipt = rewardPerReceipt_;
        verifier = verifier_;
    }

    function setReward(uint256 amount) external {
        if (msg.sender != admin) revert NotAdmin();
        rewardPerReceipt = amount;
        emit RewardSet(amount);
    }

    function transferAdmin(address admin_) external {
        if (msg.sender != admin) revert NotAdmin();
        emit AdminTransferred(admin, admin_);
        admin = admin_;
    }

    /// @notice Mine the AICoin subsidy for ONE verified A-Chain inference receipt.
    /// Permissionless: anyone may submit a valid (receipt, proof) pair; the subsidy is
    /// minted to the receipt's BOUND requester (read from the attestation), never to the
    /// submitter, so a relayer/keeper cannot redirect rewards. Bounded by the halving
    /// schedule (AICoin clamps to the vested allowance) and one-shot per intent.
    /// @param receipt the canonical 355-byte A-Chain receipt encoding.
    /// @param proof   the inclusion proof: root(32) || u64be index || u16be pathLen || path.
    /// @param computeProof a {ComputeProof} proving the receipt's CanonicalOutputHash was
    ///        actually computed by the receipt's measured model under an accepted runtime — the
    ///        hard gate that makes a forged root alone (C3) insufficient to mint.
    /// @param openBlockHash chain context bound into the compute challenge.
    /// @param runtimeMeasurement the runtime+sampler measurement (must be governance-accepted);
    ///        bound into reportData and re-checked by the verifier.
    ///
    /// @dev On Lux the receipt root SHOULD come from the aivmbridge precompile / C-committed
    /// state (not a permissioned relayer); regardless of the root's provenance, the compute-proof
    /// requirement below is the load-bearing gate: inclusion under a root proves "the A-Chain
    /// committed this receipt", the compute proof proves "this output is real computation".
    function mine(
        bytes calldata receipt,
        bytes calldata proof,
        ComputeProof calldata computeProof,
        bytes32 openBlockHash,
        bytes32 runtimeMeasurement
    ) external returns (uint256 amount) {
        // 1. shape + finality — only a completed receipt carrying a real output is actionable
        if (receipt.length != RECEIPT_LEN) revert BadReceiptLength();
        if (_u16(receipt, 0) != RECEIPT_VERSION) revert BadVersion();
        if (uint8(receipt[OFF_STATUS]) != STATUS_COMPLETED) revert NotCompleted();
        if (_b32(receipt, OFF_OUTPUT) == bytes32(0)) revert ZeroOutput();

        bytes32 intentID = _b32(receipt, OFF_INTENT);
        if (consumed[intentID]) revert AlreadyMined(intentID);
        address requester = address(bytes20(_b32(receipt, OFF_REQUESTER)));

        // 2. attestation — recompute the leaf and prove inclusion under an accepted root
        //    leaf = keccak( keccak(DOMAIN || receipt) )  [matches aivmbridge leafHash]
        bytes32 leaf = keccak256(abi.encodePacked(keccak256(abi.encodePacked(DOMAIN_RECEIPT, receipt))));
        (bytes32 root, uint256 index, bytes32[] memory path) = _decodeProof(proof);
        if (!roots.isKnownRoot(root)) revert UnknownRoot(root);
        if (!_verifyMerkle(leaf, root, index, path)) revert BadProof();

        // 3. COMPUTE PROOF — recompute the expected reportData from the receipt's OWN measured
        //    model, prompt, output, and taskId (fields the submitter cannot forge — they are in
        //    the merkle-proven receipt), bound to the requester + caller-supplied chain context
        //    and runtime. A forged root over a fabricated receipt now ALSO needs a proof whose
        //    reportData reproduces THIS receipt's binding under a governance-accepted runtime.
        // FAIL CLOSED (audit G3): no verifier wired ⇒ no mint. A receipt + merkle proof
        // alone (a relayer-anchored root over a fabricated receipt) must NEVER mint; the
        // compute proof binding real (model, prompt, output) is mandatory, not optional.
        if (address(verifier) == address(0)) revert ProofGateUnavailable();
        {
            bytes32 expected = ComputeProofLib.expectedReportData(
                uint256(_b32(receipt, OFF_TASKID)),
                intentID,
                _b32(receipt, OFF_MODELSPEC),
                _b32(receipt, OFF_PROMPT),
                openBlockHash,
                requester,
                _b32(receipt, OFF_OUTPUT),
                runtimeMeasurement
            );
            if (!verifier.verify(computeProof, expected, runtimeMeasurement)) revert InvalidComputeProof();
        }

        // 4. mint (CEI: mark consumed before the external mint; a mint revert rolls it back)
        consumed[intentID] = true;
        amount = rewardPerReceipt;
        uint256 allowed = coin.emissionAllowance();
        if (amount > allowed) amount = allowed; // clamp to the vested halving allowance
        if (amount == 0) revert NothingToMint();
        coin.mintSubsidy(requester, amount);
        emit Mined(intentID, requester, amount, root);
    }

    /// @notice View whether a receipt is mintable right now (not consumed, valid shape, included
    /// under an accepted root, AND — when the gate is wired — backed by the supplied compute
    /// proof). Lets a keeper/dashboard check before sending a tx. Mirrors {mine}'s checks exactly.
    function verifiable(
        bytes calldata receipt,
        bytes calldata proof,
        ComputeProof calldata computeProof,
        bytes32 openBlockHash,
        bytes32 runtimeMeasurement
    ) external view returns (bool) {
        if (receipt.length != RECEIPT_LEN) return false;
        if (_u16(receipt, 0) != RECEIPT_VERSION) return false;
        if (uint8(receipt[OFF_STATUS]) != STATUS_COMPLETED) return false;
        if (_b32(receipt, OFF_OUTPUT) == bytes32(0)) return false;
        if (consumed[_b32(receipt, OFF_INTENT)]) return false;
        bytes32 leaf = keccak256(abi.encodePacked(keccak256(abi.encodePacked(DOMAIN_RECEIPT, receipt))));
        (bytes32 root, uint256 index, bytes32[] memory path) = _decodeProof(proof);
        if (!roots.isKnownRoot(root)) return false;
        if (!_verifyMerkle(leaf, root, index, path)) return false;
        if (address(verifier) == address(0)) return false; // fail closed (audit G3): mirrors mine()
        {
            bytes32 expected = ComputeProofLib.expectedReportData(
                uint256(_b32(receipt, OFF_TASKID)),
                _b32(receipt, OFF_INTENT),
                _b32(receipt, OFF_MODELSPEC),
                _b32(receipt, OFF_PROMPT),
                openBlockHash,
                address(bytes20(_b32(receipt, OFF_REQUESTER))),
                _b32(receipt, OFF_OUTPUT),
                runtimeMeasurement
            );
            if (!verifier.verify(computeProof, expected, runtimeMeasurement)) return false;
        }
        return true;
    }

    // ---- pure verification helpers (byte-for-byte with precompile/aivmbridge) ----------

    /// @dev keccak binary merkle fold. bit i of index selects sibling order: 0 => leaf is
    /// LEFT (keccak(node||sib)), 1 => leaf is RIGHT (keccak(sib||node)). Index must fit in
    /// `depth` bits (no high-bit aliasing to a different position). Mirrors VerifyMerkle.
    function _verifyMerkle(bytes32 leaf, bytes32 root, uint256 index, bytes32[] memory path)
        internal
        pure
        returns (bool)
    {
        uint256 depth = path.length;
        if (depth > MAX_PROOF_DEPTH) return false;
        if (depth < 256 && index >= (uint256(1) << depth)) return false;
        bytes32 node = leaf;
        uint256 idx = index;
        for (uint256 i = 0; i < depth; i++) {
            if (idx & 1 == 0) {
                node = keccak256(abi.encodePacked(node, path[i]));
            } else {
                node = keccak256(abi.encodePacked(path[i], node));
            }
            idx >>= 1;
        }
        return node == root;
    }

    /// @dev decode the proof wire frame (precompile/aivmbridge/proof.go DecodeProof):
    /// [0:32] root | [32:40] u64be index | [40:42] u16be pathLen | [42:] pathLen*32 path.
    function _decodeProof(bytes calldata p)
        internal
        pure
        returns (bytes32 root, uint256 index, bytes32[] memory path)
    {
        if (p.length < 42) revert BadProof();
        root = _b32(p, 0);
        index = uint64(uint256(_b32(p, 8))); // low 64 bits == p[32:40] big-endian
        uint256 pathLen = uint16(uint256(_b32(p, 10))); // low 16 bits == p[40:42] big-endian
        if (pathLen > MAX_PROOF_DEPTH) revert BadProof();
        if (p.length != 42 + pathLen * 32) revert BadProof(); // exact frame: no truncation / junk
        path = new bytes32[](pathLen);
        for (uint256 i = 0; i < pathLen; i++) {
            path[i] = _b32(p, 42 + i * 32);
        }
    }

    /// @dev big-endian u16 at calldata offset `off`.
    function _u16(bytes calldata b, uint256 off) internal pure returns (uint16) {
        return (uint16(uint8(b[off])) << 8) | uint16(uint8(b[off + 1]));
    }

    /// @dev the 32-byte word at calldata offset `off`.
    function _b32(bytes calldata b, uint256 off) internal pure returns (bytes32 v) {
        assembly {
            v := calldataload(add(b.offset, off))
        }
    }
}
