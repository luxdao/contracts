// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {ComputeWitnessLib} from "../contracts/deployables/thinking/ComputeWitnessLib.sol";

/// @notice Proves the ON-CHAIN proof-of-inference witness (audit gap G6) end to end: a forward
/// pass committed by the Rust/Go prover is challenged here, in Solidity, and a fabricated output
/// is CAUGHT on-chain by a Freivalds check over F_p — no off-chain trust. The fixed vectors are
/// emitted by the canonical Go prover (crypto/poi), so a green test is also a cross-language wire
/// check: the same keccak leaf, the same Merkle fold, the same challenge derivation.
contract ComputeWitnessTest is Test {
    function _m(uint32 r, uint32 c, int64[] memory d) internal pure returns (ComputeWitnessLib.Matrix memory) {
        return ComputeWitnessLib.Matrix(r, c, d);
    }

    function _d4(int64 a, int64 b, int64 c, int64 d) internal pure returns (int64[] memory o) {
        o = new int64[](4);
        o[0] = a;
        o[1] = b;
        o[2] = c;
        o[3] = d;
    }

    function _d6(int64 a, int64 b, int64 c, int64 d, int64 e, int64 f) internal pure returns (int64[] memory o) {
        o = new int64[](6);
        o[0] = a;
        o[1] = b;
        o[2] = c;
        o[3] = d;
        o[4] = e;
        o[5] = f;
    }

    bytes constant BEACON = "beacon:self";

    /// The leaf the Solidity matBytes+keccak produces MUST equal the Go prover's leaf for the same
    /// (A,B,C). Pinned from crypto/poi MatmulLeaf(2x2 fixture). Proves the serialization parity that
    /// everything else rests on.
    function test_LeafParityWithProver() public pure {
        bytes32 leaf = ComputeWitnessLib.matmulLeaf(
            _m(2, 2, _d4(1, 2, 3, 4)), _m(2, 2, _d4(5, 6, 7, 8)), _m(2, 2, _d4(19, 22, 43, 50))
        );
        assertEq(
            leaf,
            0x5be6ad2542abf72783237ceab4ea082c270ee94755604ee4fa42a62db72f56bf,
            "Solidity matmulLeaf must match the Go prover byte-for-byte"
        );
    }

    /// A 3-matmul transcript opening EMITTED BY THE GO PROVER verifies on-chain: the beacon-selected
    /// matmul, its Merkle inclusion proof under the committed root, and the on-chain Freivalds check
    /// all agree. This is the full prover→chain wire, proven.
    function test_GoOpeningVerifiesOnChain() public pure {
        // crypto/poi transcript: matmul[0] A=[2x3], B=[3x2], C=A·B=[58,24,-83,10]; challenged idx=0.
        ComputeWitnessLib.Matrix memory a = _m(2, 3, _d6(1, -2, 3, 4, 5, -6));
        ComputeWitnessLib.Matrix memory b = _m(3, 2, _d6(7, 8, -9, 10, 11, 12));
        ComputeWitnessLib.Matrix memory c = _m(2, 2, _d4(58, 24, -83, 10));
        bytes32[] memory proof = new bytes32[](2);
        proof[0] = 0xa642ccf1ce98a7e11b2b0ea818774a7ac6f602ff1f46e3e189e4f6e9af54cffd;
        proof[1] = 0xaed8d2c8f708282461c38107cb53da3c693be11e14bfc425a25a3cadeb58a6da;
        bytes32 root = 0x2e0d81f37a3fd4bf386852ec6aa1f8668a3e143fd51bf87e8e0df7d8372d660d;
        assertTrue(
            ComputeWitnessLib.verifyOpening(root, "beacon:onchain", 0, a, b, c, proof),
            "an honest Go-emitted opening must verify on-chain"
        );
    }

    /// A fabricated output is CAUGHT on-chain. A 1-matmul transcript (root == leaf, empty proof):
    /// honest C=A·B verifies; flipping one output entry and recommitting fails the on-chain
    /// Freivalds check. This is "no real compute, no valid proof" enforced in the EVM.
    function test_FabricatedOutputCaughtOnChain() public pure {
        ComputeWitnessLib.Matrix memory a = _m(2, 2, _d4(1, 2, 3, 4));
        ComputeWitnessLib.Matrix memory b = _m(2, 2, _d4(5, 6, 7, 8));
        ComputeWitnessLib.Matrix memory c = _m(2, 2, _d4(19, 22, 43, 50)); // A·B
        bytes32[] memory empty = new bytes32[](0);

        bytes32 root = ComputeWitnessLib.matmulLeaf(a, b, c); // 1-leaf tree: root == leaf
        assertTrue(ComputeWitnessLib.verifyOpening(root, BEACON, 0, a, b, c, empty), "honest verifies");

        // fabricate: claim 51 where A·B = 50. Commit over the fake, then open it.
        ComputeWitnessLib.Matrix memory cFake = _m(2, 2, _d4(19, 22, 43, 51));
        bytes32 fakeRoot = ComputeWitnessLib.matmulLeaf(a, b, cFake);
        assertFalse(
            ComputeWitnessLib.verifyOpening(fakeRoot, BEACON, 0, a, b, cFake, empty),
            "a fabricated output must be CAUGHT on-chain by Freivalds"
        );
    }

    /// Swapped reveal: the prover committed an honest matmul but opens with a tampered C to dodge a
    /// check — Merkle inclusion fails on-chain because that C was never committed.
    function test_SwappedRevealCaughtOnChain() public pure {
        ComputeWitnessLib.Matrix memory a = _m(2, 2, _d4(1, 2, 3, 4));
        ComputeWitnessLib.Matrix memory b = _m(2, 2, _d4(5, 6, 7, 8));
        ComputeWitnessLib.Matrix memory cHonest = _m(2, 2, _d4(19, 22, 43, 50));
        bytes32[] memory empty = new bytes32[](0);
        bytes32 root = ComputeWitnessLib.matmulLeaf(a, b, cHonest);

        ComputeWitnessLib.Matrix memory cTampered = _m(2, 2, _d4(19, 22, 43, 49));
        assertFalse(
            ComputeWitnessLib.verifyOpening(root, BEACON, 0, a, b, cTampered, empty),
            "revealing a C that was never committed must fail Merkle inclusion on-chain"
        );
    }

    /// The on-chain Freivalds primitive itself: honest passes, one tampered entry fails.
    function test_FreivaldsOverField() public pure {
        ComputeWitnessLib.Matrix memory a = _m(2, 2, _d4(1, 2, 3, 4));
        ComputeWitnessLib.Matrix memory b = _m(2, 2, _d4(5, 6, 7, 8));
        ComputeWitnessLib.Matrix memory c = _m(2, 2, _d4(19, 22, 43, 50));
        uint256[] memory r = new uint256[](2);
        r[0] = 12345;
        r[1] = 67890;
        assertTrue(ComputeWitnessLib.freivalds(a, b, c, r), "honest C=A*B passes Freivalds over F_p");
        ComputeWitnessLib.Matrix memory cBad = _m(2, 2, _d4(19, 22, 43, 51));
        assertFalse(ComputeWitnessLib.freivalds(a, b, cBad, r), "tampered C fails Freivalds over F_p");
    }
}
