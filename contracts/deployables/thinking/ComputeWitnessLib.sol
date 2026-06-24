// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

/// @title ComputeWitnessLib — the ON-CHAIN proof-of-inference witness check.
/// @notice This is the wire that makes "no valid compute proof, no mint" enforceable on-chain
/// (audit gap G6). A prover commits a forward pass as a Merkle root over per-matmul leaves
/// (keccak over the exact-integer operands `(A,B,C)`); a challenger opens a beacon-selected matmul
/// and submits the opening here. {verifyOpening} returns true iff (1) the revealed operands are the
/// COMMITTED ones (Merkle inclusion, the same index-fold as `AICoinMiner._verifyMerkle`) and
/// (2) `C = A·B` under a beacon-bound Freivalds challenge evaluated over the prime field
/// `F_p, p = 2^61-1`. A fabricated output fails (2); a swapped-in output fails (1). The optimistic
/// backend calls this from `challenge()` so a real discrepancy witness — not "any non-empty
/// bytes" — is what slashes a bond.
///
/// Byte-for-byte identical to the prover (`hanzo-engine/src/poi_transcript.rs`) and the Go watcher
/// (`crypto/poi/transcript.go`): same domain tag, same canonical `(rows,cols,data)` serialization,
/// same keccak fold, same `BE32(j)‖BE64(i)` challenge derivation. An opening that verifies in the
/// engine verifies here unchanged.
///
/// Gas: the check is `O(t·k + k·n + t·n)` field ops for the opened matmul. The challenger opens
/// ONE matmul (or a bounded slice of one), so the witness is small even though the model is large
/// — that asymmetry is the whole point of Freivalds. Callers MUST bound the opened dimensions
/// ({MAX_DIM}) so a griefing prover cannot submit an unboundedly large opening.
library ComputeWitnessLib {
    /// @notice The Mersenne prime field modulus `p = 2^61 - 1`. mulmod/addmod stay exact under it.
    uint256 internal constant P = (uint256(1) << 61) - 1;

    /// @notice Domain tag for a matmul leaf — must equal the Rust/Go `DOMAIN_MATMUL_LEAF`.
    bytes internal constant DOMAIN_MATMUL_LEAF = "hanzo/poi/matmul-leaf/v1";

    /// @notice Hard cap on any opened matrix dimension (rows, cols, or inner k). Bounds gas and
    /// rejects a griefing oversized opening. 1024 covers a head/block slice; a full layer is
    /// challenged in slices.
    uint256 internal constant MAX_DIM = 1024;

    error DimTooLarge();
    error BadShape();

    /// @dev A row-major integer matrix opened from the transcript.
    struct Matrix {
        uint32 rows;
        uint32 cols;
        int64[] data; // element (i,j) = data[i*cols + j]
    }

    /// @dev Reduce a signed integer into `[0, p)` (handles negative int8 weights/activations).
    function _toField(int256 x) private pure returns (uint256) {
        int256 r = x % int256(P);
        if (r < 0) r += int256(P);
        return uint256(r);
    }

    /// @dev `m · v` over `F_p`: `m` is `rows×cols` row-major, `v` length `cols`, out length `rows`.
    function _matvec(Matrix memory m, uint256[] memory v) private pure returns (uint256[] memory out) {
        out = new uint256[](m.rows);
        for (uint256 i = 0; i < m.rows; i++) {
            uint256 acc = 0;
            uint256 base = i * m.cols;
            for (uint256 j = 0; j < m.cols; j++) {
                acc = addmod(acc, mulmod(_toField(m.data[base + j]), v[j], P), P);
            }
            out[i] = acc;
        }
    }

    /// @notice Freivalds for ONE challenge vector `r` (length `n`): check `A·(B·r) == C·r` over
    /// `F_p`. `A` is `[t×k]`, `B` is `[k×n]`, `C` is `[t×n]`. Returns false on any shape mismatch
    /// (fail closed). An honest `C = A·B` passes; a fabricated `C` fails with prob ≥ 1 − 1/p.
    function freivalds(Matrix memory a, Matrix memory b, Matrix memory c, uint256[] memory r)
        internal
        pure
        returns (bool)
    {
        if (a.cols != b.rows || b.cols != c.cols || a.rows != c.rows || r.length != b.cols) {
            return false;
        }
        uint256[] memory br = _matvec(b, r); // length k
        uint256[] memory abr = _matvec(a, br); // length t
        uint256[] memory cr = _matvec(c, r); // length t
        for (uint256 i = 0; i < abr.length; i++) {
            if (abr[i] != cr[i]) return false;
        }
        return true;
    }

    /// @dev Canonical serialization `BE32(rows) ‖ BE32(cols) ‖ data[i] as BE64` — abi.encodePacked
    /// emits a uint32 as 4 BE bytes and an int64 as 8 BE (two's-complement) bytes, matching the
    /// Rust/Go `mat_bytes`. (Looped because abi.encodePacked pads array *elements*; per-element does not.)
    function _matBytes(Matrix memory m) private pure returns (bytes memory out) {
        if (m.rows > MAX_DIM || m.cols > MAX_DIM) revert DimTooLarge();
        if (m.data.length != uint256(m.rows) * uint256(m.cols)) revert BadShape();
        out = abi.encodePacked(m.rows, m.cols);
        for (uint256 i = 0; i < m.data.length; i++) {
            out = abi.encodePacked(out, m.data[i]);
        }
    }

    /// @notice The leaf binding one matmul: `keccak(DOMAIN ‖ mat(A) ‖ mat(B) ‖ mat(C))`.
    function matmulLeaf(Matrix memory a, Matrix memory b, Matrix memory c) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(DOMAIN_MATMUL_LEAF, _matBytes(a), _matBytes(b), _matBytes(c)));
    }

    /// @dev Merkle inclusion with the index fold of `AICoinMiner._verifyMerkle`.
    function _merkleVerify(bytes32 leaf, bytes32 root, uint256 index, bytes32[] memory proof)
        private
        pure
        returns (bool)
    {
        bytes32 node = leaf;
        uint256 idx = index;
        for (uint256 i = 0; i < proof.length; i++) {
            if (idx & 1 == 0) {
                node = keccak256(abi.encodePacked(node, proof[i]));
            } else {
                node = keccak256(abi.encodePacked(proof[i], node));
            }
            idx >>= 1;
        }
        return node == root;
    }

    /// @dev One Freivalds challenge vector of length `n` from `seed`, identical to the j=0 row of
    /// the Rust/Go `derive_challenges_keccak`: `r[i] = BE_u64(keccak(seed ‖ BE32(0) ‖ BE64(i))[:8]) % p`.
    function _deriveChallenge(bytes memory seed, uint256 n) private pure returns (uint256[] memory r) {
        r = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            bytes32 h = keccak256(abi.encodePacked(seed, uint32(0), uint64(i)));
            r[i] = uint256(uint64(bytes8(h))) % P;
        }
    }

    /// @notice THE ON-CHAIN CHALLENGER. Verify the prover's opening of the matmul at `index`:
    /// (1) the operands are the committed ones (Merkle inclusion under `root`), and (2) `C = A·B`
    /// (Freivalds, beacon-bound challenge `seed = keccak(beacon ‖ root ‖ BE64(index))`). Returns
    /// true iff the opened matmul is genuine. A challenger proves FRAUD by submitting an opening
    /// for which this returns FALSE — the contract then slashes the prover's bond.
    function verifyOpening(
        bytes32 root,
        bytes memory beacon,
        uint256 index,
        Matrix memory a,
        Matrix memory b,
        Matrix memory c,
        bytes32[] memory merkleProof
    ) internal pure returns (bool) {
        // (1) binding: revealed operands hash to the committed leaf at this index.
        if (!_merkleVerify(matmulLeaf(a, b, c), root, index, merkleProof)) {
            return false;
        }
        // (2) correctness: Freivalds with a prover-unpredictable, beacon-bound challenge.
        bytes memory seed = abi.encodePacked(beacon, root, uint64(index));
        seed = abi.encodePacked(keccak256(seed));
        return freivalds(a, b, c, _deriveChallenge(seed, b.cols));
    }

    /// @notice The on-chain FRAUD PROOF (the complement of {verifyOpening}). Returns true iff the
    /// opened matmul was COMMITTED under `root` (Merkle inclusion) AND its output is FABRICATED
    /// (`C != A·B`, caught by Freivalds under a beacon-bound challenge). A challenger exhibits any
    /// one such matmul from a prover's committed forward pass; an honest pass has none, so an
    /// honest prover can never be slashed. The `beacon` must be unpredictable to the prover at
    /// commit time (e.g. the commit block's hash) so it cannot pre-fit a `C` that dodges the check.
    function provesFraud(
        bytes32 root,
        bytes memory beacon,
        uint256 index,
        Matrix memory a,
        Matrix memory b,
        Matrix memory c,
        bytes32[] memory merkleProof
    ) internal pure returns (bool) {
        // (1) the operands ARE the prover's committed ones — else this is not their matmul.
        if (!_merkleVerify(matmulLeaf(a, b, c), root, index, merkleProof)) {
            return false;
        }
        // (2) the output is fabricated: Freivalds FAILS for the beacon-bound challenge.
        bytes memory seed = abi.encodePacked(keccak256(abi.encodePacked(beacon, root, uint64(index))));
        return !freivalds(a, b, c, _deriveChallenge(seed, b.cols));
    }
}
