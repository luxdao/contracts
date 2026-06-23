// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {AICoin} from "../contracts/deployables/thinking/AICoin.sol";
import {AIReceiptRoots} from "../contracts/deployables/thinking/AIReceiptRoots.sol";
import {AICoinMiner, IAICoinMintable, IAIReceiptRootsView, IComputeVerifierM} from "../contracts/deployables/thinking/AICoinMiner.sol";
import {ComputeProof} from "../contracts/deployables/thinking/ComputeProofLib.sol";

/// @notice Proves real AI mining from a unified A-Chain attestation, in pure Solidity:
/// a committed inference receipt + merkle inclusion proof under an accepted root mints the
/// AICoin subsidy to the receipt's bound requester — no trusted minter key, runnable on any
/// EVM. The receipt encoding, receipt hash, leaf, and merkle fold are built here exactly as
/// the A-Chain builds them (precompile/aivmbridge/{receipt,proof}.go), so a green test is a
/// cross-module wire check too.
contract AICoinMinerTest is Test {
    AICoin coin;
    AIReceiptRoots roots;
    AICoinMiner miner;

    address constant ADMIN = address(0xA11CE);
    address constant RELAYER = address(0xBEEF);
    address constant REQUESTER = address(0xCAFE);
    address constant STRANGER = address(0xD00D);
    uint256 constant REWARD = 1000 ether; // 1000 AI per verified receipt

    bytes constant DOMAIN_RECEIPT = "lux/aivmbridge/receipt/v1";

    function setUp() public {
        vm.warp(1_700_000_000);
        // AICoin with no minter yet; then point the mint seam at the attestation miner.
        coin = new AICoin("AI Coin", "AI", ADMIN, address(0), 0);
        roots = new AIReceiptRoots(ADMIN);
        // This suite proves the merkle/replay/clamp machinery in isolation: the compute-proof
        // gate is left UNWIRED (verifier == address(0)) so these tests stay orthogonal to it.
        // The gate's own enforcement (forged-root-without-proof, binding, registry) is proven in
        // ComputeProofEnforcement.t.sol against a fully wired miner.
        miner = new AICoinMiner(
            IAICoinMintable(address(coin)),
            IAIReceiptRootsView(address(roots)),
            ADMIN,
            REWARD,
            IComputeVerifierM(address(0))
        );
        vm.startPrank(ADMIN);
        coin.setMinter(address(miner), true); // authorize the attestation-mining path
        roots.setRelayer(RELAYER, true); // the warp/bridge relay anchors A-Chain roots
        vm.stopPrank();
        // vest a chunk of the halving schedule so there is allowance to mine
        vm.warp(block.timestamp + 63_072_000); // ~2 years into epoch 0 -> ~250M AI vested
    }

    // ---- build a receipt + proof exactly as the A-Chain does -------------------

    function _receipt(bytes32 intentID, address requester, uint8 status, bytes32 output)
        internal
        pure
        returns (bytes memory r)
    {
        r = abi.encodePacked(
            uint16(1), // Version
            intentID, // IntentID
            bytes32(0), // TaskID
            bytes32(0), // CChainID
            bytes32(0), // AChainID
            requester, // Requester (20 bytes)
            bytes32(0), // ModelSpecHash
            bytes32(0), // PromptHash
            output, // CanonicalOutputHash
            status, // Status
            uint16(5), // N
            uint16(3), // Threshold
            bytes32(0), // WinnersRoot
            bytes32(0), // OperatorsRoot
            bytes32(0), // FeePaid
            uint64(777) // SettledAtHeight
        );
        require(r.length == 355, "receipt must be 355 bytes");
    }

    function _leaf(bytes memory receipt) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(keccak256(abi.encodePacked(DOMAIN_RECEIPT, receipt))));
    }

    function _proof(bytes32 root, uint64 index, bytes32[] memory path) internal pure returns (bytes memory p) {
        p = abi.encodePacked(root, index, uint16(path.length));
        for (uint256 i = 0; i < path.length; i++) {
            p = abi.encodePacked(p, path[i]);
        }
    }

    function _hashPair(bytes32 l, bytes32 r) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(l, r));
    }

    /// @dev mine() with the compute-proof gate UNWIRED on this miner: the empty proof + zero
    /// context are ignored (verifier == address(0)), so these tests exercise only the merkle/
    /// replay/clamp path. Keeps the call sites readable while matching the gated signature.
    function _mine(bytes memory receipt, bytes memory proof) internal returns (uint256) {
        ComputeProof memory empty = ComputeProof({proofType: 0, reportData: bytes32(0), evidence: ""});
        return miner.mine(receipt, proof, empty, bytes32(0), bytes32(0));
    }

    /// @dev a bytes32 with every byte equal to `b` (matches the Go test helper h32).
    function _rep(uint8 b) internal pure returns (bytes32) {
        return bytes32(uint256(b) * 0x0101010101010101010101010101010101010101010101010101010101010101);
    }

    // ---- cross-module golden vector: Solidity == A-Chain (Go) byte-for-byte ------

    /// @notice The decisive no-trust check: build the EXACT receipt fixture the A-Chain's
    /// Go wire test uses (precompile/aivmbridge/wire_test.go fixtureReceipt) and assert our
    /// pure-Solidity receipt_hash matches its golden vector. If this passes, the encoding,
    /// the domain separator, and keccak all agree across the module boundary — so a proof
    /// the A-Chain exports verifies here unchanged.
    function test_GoldenReceiptHash_MatchesAChainWireSpec() public pure {
        bytes memory receipt = abi.encodePacked(
            uint16(1), // Version
            bytes32(0x13346f5fe5f8feda7fec68968366fb397cf3854096a07a1528ada9a0c910d758), // IntentID (golden)
            _rep(0x7A), // TaskID
            _rep(0xC0), // CChainID
            _rep(0xA0), // AChainID
            address(0x1111111111111111111111111111111111111111), // Requester
            _rep(0x5E), // ModelSpecHash
            _rep(0x9D), // PromptHash
            _rep(0x0F), // CanonicalOutputHash
            uint8(2), // Status = Completed
            uint16(3), // N
            uint16(2), // Threshold
            _rep(0x44), // WinnersRoot
            _rep(0x55), // OperatorsRoot
            bytes32(uint256(1_000_000)), // FeePaid (feeWord(1_000_000))
            uint64(0x0102030405060708) // SettledAtHeight
        );
        assertEq(receipt.length, 355, "canonical receipt length");
        bytes32 receiptHash = keccak256(abi.encodePacked(DOMAIN_RECEIPT, receipt));
        assertEq(
            receiptHash,
            bytes32(0xc6e07d2b28f8cafa0ccf12a540379eb37afe50cf48567e59d96e386a73ca5b5b),
            "receipt_hash must equal the A-Chain Go golden vector"
        );
    }

    // ---- the core property: verified attestation -> subsidy mint ----------------

    function test_Mine_SingleLeaf_MintsToRequester() public {
        bytes memory receipt = _receipt(keccak256("intent-1"), REQUESTER, 2, keccak256("output"));
        bytes32 leaf = _leaf(receipt);
        bytes32 root = leaf; // single-leaf tree: root == leaf, empty path
        vm.prank(RELAYER);
        roots.anchorRoot(root, 42);

        bytes memory proof = _proof(root, 0, new bytes32[](0));
        uint256 amount = _mine(receipt, proof);

        assertEq(amount, REWARD, "minted the per-receipt reward");
        assertEq(coin.balanceOf(REQUESTER), REWARD, "subsidy minted to the bound requester");
        assertEq(coin.totalSupply(), REWARD, "supply grew by the mint");
        assertTrue(miner.consumed(keccak256("intent-1")), "intent marked consumed");
    }

    function test_Mine_TwoLeafTree_VerifiesInclusionBothSides() public {
        bytes memory r0 = _receipt(keccak256("intent-A"), REQUESTER, 2, keccak256("out-A"));
        bytes memory r1 = _receipt(keccak256("intent-B"), STRANGER, 2, keccak256("out-B"));
        bytes32 l0 = _leaf(r0);
        bytes32 l1 = _leaf(r1);
        bytes32 root = _hashPair(l0, l1); // depth-1 tree
        vm.prank(RELAYER);
        roots.anchorRoot(root, 7);

        // leaf 0 (index 0, sibling l1, leaf is LEFT)
        bytes32[] memory p0 = new bytes32[](1);
        p0[0] = l1;
        _mine(r0, _proof(root, 0, p0));
        assertEq(coin.balanceOf(REQUESTER), REWARD, "leaf-0 receipt mined to its requester");

        // leaf 1 (index 1, sibling l0, leaf is RIGHT)
        bytes32[] memory p1 = new bytes32[](1);
        p1[0] = l0;
        _mine(r1, _proof(root, 1, p1));
        assertEq(coin.balanceOf(STRANGER), REWARD, "leaf-1 receipt mined to its requester");
    }

    /// @notice The mint goes to the receipt's requester, never the tx submitter.
    function test_MintsToRequesterNotSubmitter() public {
        bytes memory receipt = _receipt(keccak256("intent-2"), REQUESTER, 2, keccak256("o"));
        bytes32 root = _leaf(receipt);
        vm.prank(RELAYER);
        roots.anchorRoot(root, 1);
        vm.prank(STRANGER); // a random keeper submits
        _mine(receipt, _proof(root, 0, new bytes32[](0)));
        assertEq(coin.balanceOf(REQUESTER), REWARD, "reward to requester");
        assertEq(coin.balanceOf(STRANGER), 0, "submitter gets nothing");
    }

    // ---- safety: replay, unknown root, non-final, tampered proof ---------------

    function test_Replay_Reverts() public {
        bytes memory receipt = _receipt(keccak256("intent-3"), REQUESTER, 2, keccak256("o"));
        bytes32 root = _leaf(receipt);
        vm.prank(RELAYER);
        roots.anchorRoot(root, 1);
        bytes memory proof = _proof(root, 0, new bytes32[](0));
        _mine(receipt, proof);
        vm.expectRevert(abi.encodeWithSelector(AICoinMiner.AlreadyMined.selector, keccak256("intent-3")));
        _mine(receipt, proof);
    }

    function test_UnknownRoot_Reverts() public {
        bytes memory receipt = _receipt(keccak256("intent-4"), REQUESTER, 2, keccak256("o"));
        bytes32 root = _leaf(receipt); // never anchored
        vm.expectRevert(abi.encodeWithSelector(AICoinMiner.UnknownRoot.selector, root));
        _mine(receipt, _proof(root, 0, new bytes32[](0)));
    }

    function test_NotCompleted_Reverts() public {
        bytes memory receipt = _receipt(keccak256("intent-5"), REQUESTER, 3, keccak256("o")); // Status=Failed
        bytes32 root = _leaf(receipt);
        vm.prank(RELAYER);
        roots.anchorRoot(root, 1);
        vm.expectRevert(AICoinMiner.NotCompleted.selector);
        _mine(receipt, _proof(root, 0, new bytes32[](0)));
    }

    function test_ZeroOutput_Reverts() public {
        bytes memory receipt = _receipt(keccak256("intent-6"), REQUESTER, 2, bytes32(0)); // completed but no output
        bytes32 root = _leaf(receipt);
        vm.prank(RELAYER);
        roots.anchorRoot(root, 1);
        vm.expectRevert(AICoinMiner.ZeroOutput.selector);
        _mine(receipt, _proof(root, 0, new bytes32[](0)));
    }

    function test_TamperedProof_Reverts() public {
        bytes memory receipt = _receipt(keccak256("intent-7"), REQUESTER, 2, keccak256("o"));
        bytes32 leaf = _leaf(receipt);
        // anchor a 2-leaf root but submit a single-leaf proof with the wrong root match
        bytes32 root = _hashPair(leaf, keccak256("sibling"));
        vm.prank(RELAYER);
        roots.anchorRoot(root, 1);
        // claim it's a single leaf (root==leaf) — root is known as the pair, leaf != root
        bytes memory badProof = _proof(root, 0, new bytes32[](0));
        vm.expectRevert(AICoinMiner.BadProof.selector);
        _mine(receipt, badProof);
    }

    function test_BadReceiptLength_Reverts() public {
        vm.expectRevert(AICoinMiner.BadReceiptLength.selector);
        _mine(hex"deadbeef", _proof(bytes32(uint256(1)), 0, new bytes32[](0)));
    }

    // ---- issuance discipline: clamps to the halving allowance ------------------

    function test_RewardClampedToEmissionAllowance() public {
        // set a reward far above what has vested -> mint is clamped to the allowance
        uint256 allowed = coin.emissionAllowance();
        vm.prank(ADMIN);
        miner.setReward(allowed + 1_000_000 ether);
        bytes memory receipt = _receipt(keccak256("intent-8"), REQUESTER, 2, keccak256("o"));
        bytes32 root = _leaf(receipt);
        vm.prank(RELAYER);
        roots.anchorRoot(root, 1);
        uint256 amount = _mine(receipt, _proof(root, 0, new bytes32[](0)));
        assertEq(amount, allowed, "minted exactly the vested allowance, not more");
        assertEq(coin.balanceOf(REQUESTER), allowed, "requester got the clamped amount");
    }
}
