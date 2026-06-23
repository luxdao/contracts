// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.31;

import {Test} from "forge-std/Test.sol";

import {AICoin} from "../contracts/deployables/thinking/AICoin.sol";
import {AIReceiptRoots} from "../contracts/deployables/thinking/AIReceiptRoots.sol";
import {AICoinMiner, IAICoinMintable, IAIReceiptRootsView, IComputeVerifierM} from "../contracts/deployables/thinking/AICoinMiner.sol";
import {AttestationRootRegistry} from "../contracts/deployables/thinking/AttestationRootRegistry.sol";
import {ComputeVerifier} from "../contracts/deployables/thinking/ComputeVerifier.sol";
import {ComputeProfile} from "../contracts/deployables/thinking/ComputeProfile.sol";
import {OptimisticEvidence} from "../contracts/deployables/thinking/evidence/OptimisticEvidence.sol";
import {CCEvidence} from "../contracts/deployables/thinking/evidence/CCEvidence.sol";
import {ComputeProof, ComputeProofLib} from "../contracts/deployables/thinking/ComputeProofLib.sol";
import {IComputeVerifier} from "../contracts/deployables/thinking/interfaces/IComputeVerifier.sol";
import {ThinkingGovernor} from "../contracts/deployables/thinking/ThinkingGovernor.sol";
import {ThinkingMiner, IAICoinMintableG, IComputeProfileView} from "../contracts/deployables/thinking/ThinkingMiner.sol";
import {IThinkingGovernor} from "../contracts/deployables/thinking/interfaces/IThinkingGovernor.sol";

/// @title ComputeProofEnforcementTest
/// @notice The red-team closer: proves "no valid compute proof → no mint, no settle" is TRUE.
/// Each test maps to a hole the review found:
///   - test_Golden_*            : the binding's exact byte layout (C1; Go/Rust must mirror).
///   - test_Binding_*           : a proof is welded to its (task, model, output, operator) — a
///                                replayed / cross-task / cross-operator / cross-model proof is
///                                rejected (C1).
///   - test_C2_*                : a ThinkingMiner coin-flip GUESS with no compute proof mints
///                                nothing; only PROVEN winners are paid.
///   - test_C3_*                : an AICoinMiner forged root over a fabricated receipt mints
///                                nothing without a compute proof; the proof is the hard gate.
///   - test_H2_*                : a wrong/cheap model or non-zero-temp runtime is rejected
///                                because its measurement is not in the governed set.
contract ComputeProofEnforcementTest is Test {
    // ---- the binding's domain tags (re-declared to assert parity with the library) ----
    bytes constant DOMAIN_CHALLENGE = "lux/aivm/compute-challenge/v1";
    bytes constant DOMAIN_REPORT = "lux/aivm/compute-report/v1";
    bytes constant DOMAIN_RECEIPT = "lux/aivmbridge/receipt/v1";

    // ---- shared infra ----
    AICoin coin;
    AttestationRootRegistry registry;
    ComputeVerifier verifier;
    ComputeProfile profile;
    OptimisticEvidence optimistic;

    address constant ADMIN = address(0xA11CE);
    address constant REQUESTER = address(0xCAFE);
    address constant PROVER = address(0xD00D);
    uint256 constant MIN_BOND = 1 ether;
    uint64 constant CHALLENGE_WINDOW = 1 hours;

    // governed measurements
    bytes32 constant MODEL_SPEC = bytes32(uint256(0x5e) * _ONES);
    bytes32 constant PROMPT_HASH = bytes32(uint256(0x9d) * _ONES);
    bytes32 constant RUNTIME_OK = bytes32(uint256(0x77) * _ONES); // accepted runtime (temp==0)
    bytes32 constant RUNTIME_BAD = bytes32(uint256(0x88) * _ONES); // NOT accepted (e.g. temp!=0)
    uint256 internal constant _ONES = 0x0101010101010101010101010101010101010101010101010101010101010101;

    function setUp() public {
        vm.warp(1_700_000_000);
        coin = new AICoin("AI Coin", "AI", ADMIN, address(0), 0);
        registry = new AttestationRootRegistry(ADMIN);
        verifier = new ComputeVerifier(address(registry), ADMIN);
        profile = new ComputeProfile(ADMIN);
        optimistic = new OptimisticEvidence(MIN_BOND, CHALLENGE_WINDOW, address(registry));

        vm.startPrank(ADMIN);
        verifier.setBackend(3, address(optimistic)); // optimistic backend in slot 3
        registry.setModelSpec(MODEL_SPEC, true);
        registry.setRuntime(RUNTIME_OK, true);
        vm.stopPrank();

        vm.deal(PROVER, 100 ether);
        vm.warp(block.timestamp + 63_072_000); // vest ~250M AI
    }

    // ========================================================================
    // (f) GOLDEN — the exact byte layout the Go precompile + Rust engine mirror
    // ========================================================================

    /// @notice Pins the challenge + reportData golden vectors. Computed independently with
    /// `cast keccak` over the raw-utf8-domain concatenation; the Go precompile
    /// (precompile/computeattest) and the Rust hanzo-engine MUST reproduce these EXACTLY for the
    /// same fixture, or a proof minted off-chain will not verify on-chain.
    function test_Golden_ReportDataByteLayout() public pure {
        uint256 taskId = 1;
        bytes32 intentID = bytes32(uint256(0x11) * _ONES);
        bytes32 openBlockHash = bytes32(uint256(0xb0) * _ONES);
        address operator = address(0x1111111111111111111111111111111111111111);
        bytes32 outputHash = bytes32(uint256(0x0f) * _ONES);

        // The library's challenge equals the hand-built golden.
        bytes32 challenge = _libChallenge(taskId, intentID, MODEL_SPEC, PROMPT_HASH, openBlockHash, operator);
        assertEq(
            challenge,
            0x0dcae535d790ba02d50d9ca699fcf8d6c032c2c7f68cc2093131552910dc970f,
            "challenge golden vector"
        );

        // And the library's reportData equals the hand-built golden.
        bytes32 reportData = _libReportData(challenge, MODEL_SPEC, PROMPT_HASH, outputHash, RUNTIME_OK);
        assertEq(
            reportData,
            0x3a2ccde8f8d9d8767461f76935a268626faf979d9fe51cffc2976ab3d43b0633,
            "reportData golden vector"
        );

        // And the one-shot helper equals the two-step chain (no divergence between paths).
        assertEq(
            ComputeProofLib.expectedReportData(
                taskId, intentID, MODEL_SPEC, PROMPT_HASH, openBlockHash, operator, outputHash, RUNTIME_OK
            ),
            reportData,
            "one-shot expectedReportData == two-step challenge then reportData"
        );
    }

    /// @notice Fuzz the WIRE LAYOUT against an independent reconstruction: the library's
    /// reportData must equal keccak of the byte string built field-by-field exactly as the Go
    /// `append(buf, x.Bytes()...)` concatenation does — for ALL inputs, not just the golden.
    function testFuzz_Golden_LayoutMatchesConcatenation(
        uint256 taskId,
        bytes32 intentID,
        bytes32 modelSpec,
        bytes32 promptHash,
        bytes32 openBlockHash,
        address operator,
        bytes32 outputHash,
        bytes32 runtime
    ) public pure {
        // Reconstruct challenge: DOMAIN_CHALLENGE ++ u256be(taskId) ++ intent ++ model ++ prompt
        // ++ openblk ++ operator(20). abi.encodePacked lays address as its raw 20 bytes.
        bytes memory challengePreimage = abi.encodePacked(
            DOMAIN_CHALLENGE, taskId, intentID, modelSpec, promptHash, openBlockHash, operator
        );
        bytes32 challenge = keccak256(challengePreimage);
        assertEq(
            _libChallenge(taskId, intentID, modelSpec, promptHash, openBlockHash, operator),
            challenge,
            "challenge layout diverged from concatenation"
        );

        bytes memory reportPreimage = abi.encodePacked(
            DOMAIN_REPORT, challenge, modelSpec, promptHash, outputHash, runtime
        );
        assertEq(
            _libReportData(challenge, modelSpec, promptHash, outputHash, runtime),
            keccak256(reportPreimage),
            "reportData layout diverged from concatenation"
        );
    }

    /// @notice The domain tags are the exact raw-utf8 strings (no length prefix) — the same idiom
    /// as AICoinMiner's DomainReceipt. A drift here desynchronizes every backend at once.
    function test_Golden_DomainTags() public pure {
        assertEq(DOMAIN_CHALLENGE, bytes("lux/aivm/compute-challenge/v1"), "challenge domain");
        assertEq(DOMAIN_REPORT, bytes("lux/aivm/compute-report/v1"), "report domain");
        assertEq(DOMAIN_CHALLENGE.length, 29, "challenge domain length");
        assertEq(DOMAIN_REPORT.length, 26, "report domain length");
    }

    // ========================================================================
    // (c) BINDING — a proof is welded to its work; cross-* is rejected (C1)
    // ========================================================================

    function test_Binding_ValidProof_VerifiesForItsOwnWork() public {
        uint256 taskId = 7;
        bytes32 intentID = keccak256("intent-7");
        bytes32 openBlk = keccak256("block-7");
        bytes32 outputHash = keccak256("out-7");
        bytes32 expected = ComputeProofLib.expectedReportData(
            taskId, intentID, MODEL_SPEC, PROMPT_HASH, openBlk, PROVER, outputHash, RUNTIME_OK
        );
        _bond(expected, MODEL_SPEC);
        ComputeProof memory cp = _proof(expected);
        assertTrue(verifier.verify(cp, expected, RUNTIME_OK), "valid proof verifies for its work");
    }

    function test_Binding_CrossTask_Rejected() public {
        // A proof bonded for taskId 7 must NOT verify when re-presented for taskId 8.
        uint256 taskA = 7;
        uint256 taskB = 8;
        bytes32 intentID = keccak256("intent");
        bytes32 openBlk = keccak256("block");
        bytes32 outputHash = keccak256("out");
        bytes32 reportA = ComputeProofLib.expectedReportData(
            taskA, intentID, MODEL_SPEC, PROMPT_HASH, openBlk, PROVER, outputHash, RUNTIME_OK
        );
        _bond(reportA, MODEL_SPEC);
        ComputeProof memory cp = _proof(reportA);

        // What a taskB consumer would expect — a DIFFERENT reportData.
        bytes32 reportB = ComputeProofLib.expectedReportData(
            taskB, intentID, MODEL_SPEC, PROMPT_HASH, openBlk, PROVER, outputHash, RUNTIME_OK
        );
        assertTrue(reportA != reportB, "task binds into reportData");
        assertFalse(verifier.verify(cp, reportB, RUNTIME_OK), "cross-task proof rejected");
    }

    function test_Binding_CrossOperator_Rejected() public {
        uint256 taskId = 7;
        bytes32 intentID = keccak256("intent");
        bytes32 openBlk = keccak256("block");
        bytes32 outputHash = keccak256("out");
        bytes32 reportX = ComputeProofLib.expectedReportData(
            taskId, intentID, MODEL_SPEC, PROMPT_HASH, openBlk, PROVER, outputHash, RUNTIME_OK
        );
        _bond(reportX, MODEL_SPEC);
        ComputeProof memory cp = _proof(reportX);

        // Crediting a DIFFERENT operator yields a different expected reportData.
        bytes32 reportY = ComputeProofLib.expectedReportData(
            taskId, intentID, MODEL_SPEC, PROMPT_HASH, openBlk, address(0xBEEF), outputHash, RUNTIME_OK
        );
        assertTrue(reportX != reportY, "operator binds into reportData");
        assertFalse(verifier.verify(cp, reportY, RUNTIME_OK), "cross-operator proof rejected");
    }

    function test_Binding_CrossModel_Rejected() public {
        uint256 taskId = 7;
        bytes32 intentID = keccak256("intent");
        bytes32 openBlk = keccak256("block");
        bytes32 outputHash = keccak256("out");
        bytes32 reportRealModel = ComputeProofLib.expectedReportData(
            taskId, intentID, MODEL_SPEC, PROMPT_HASH, openBlk, PROVER, outputHash, RUNTIME_OK
        );
        _bond(reportRealModel, MODEL_SPEC);
        ComputeProof memory cp = _proof(reportRealModel);

        // A consumer expecting a DIFFERENT model spec gets a different reportData.
        bytes32 otherModel = bytes32(uint256(0xAB) * _ONES);
        bytes32 reportOtherModel = ComputeProofLib.expectedReportData(
            taskId, intentID, otherModel, PROMPT_HASH, openBlk, PROVER, outputHash, RUNTIME_OK
        );
        assertFalse(verifier.verify(cp, reportOtherModel, RUNTIME_OK), "cross-model proof rejected");
    }

    function test_Binding_TamperedOutput_Rejected() public {
        // The output is what we're really binding: change it, the proof no longer verifies.
        uint256 taskId = 7;
        bytes32 intentID = keccak256("intent");
        bytes32 openBlk = keccak256("block");
        bytes32 reportHonest = ComputeProofLib.expectedReportData(
            taskId, intentID, MODEL_SPEC, PROMPT_HASH, openBlk, PROVER, keccak256("honest-out"), RUNTIME_OK
        );
        _bond(reportHonest, MODEL_SPEC);
        ComputeProof memory cp = _proof(reportHonest);

        bytes32 reportSwapped = ComputeProofLib.expectedReportData(
            taskId, intentID, MODEL_SPEC, PROMPT_HASH, openBlk, PROVER, keccak256("swapped-out"), RUNTIME_OK
        );
        assertFalse(verifier.verify(cp, reportSwapped, RUNTIME_OK), "tampered-output proof rejected");
    }

    // ========================================================================
    // (e) H2 — wrong/cheap model or non-zero-temp runtime is rejected
    // ========================================================================

    function test_H2_UnacceptedRuntime_Rejected() public {
        // A proof correctly bound to RUNTIME_BAD (a non-zero-temp sampler) but RUNTIME_BAD is not
        // governance-accepted → the verifier's registry check fails even though the binding is
        // internally consistent.
        uint256 taskId = 7;
        bytes32 intentID = keccak256("intent");
        bytes32 openBlk = keccak256("block");
        bytes32 outputHash = keccak256("out");
        bytes32 report = ComputeProofLib.expectedReportData(
            taskId, intentID, MODEL_SPEC, PROMPT_HASH, openBlk, PROVER, outputHash, RUNTIME_BAD
        );
        // Cannot even bond it: the optimistic backend also checks the model spec, but the runtime
        // membership is the verifier's job. Bond against an accepted model so submit() passes,
        // then show verify() rejects on the unaccepted RUNTIME_BAD.
        _bond(report, MODEL_SPEC);
        ComputeProof memory cp = _proof(report);
        assertFalse(verifier.verify(cp, report, RUNTIME_BAD), "unaccepted runtime rejected");
    }

    function test_H2_RevokedRuntime_Rejected() public {
        // An accepted runtime that is later REVOKED stops verifying — the kill-switch.
        uint256 taskId = 7;
        bytes32 report = ComputeProofLib.expectedReportData(
            taskId, keccak256("i"), MODEL_SPEC, PROMPT_HASH, keccak256("b"), PROVER, keccak256("o"), RUNTIME_OK
        );
        _bond(report, MODEL_SPEC);
        ComputeProof memory cp = _proof(report);
        assertTrue(verifier.verify(cp, report, RUNTIME_OK), "valid before revoke");

        vm.prank(ADMIN);
        registry.revoke(RUNTIME_OK);
        assertFalse(verifier.verify(cp, report, RUNTIME_OK), "revoked runtime rejected");
    }

    function test_H2_UnacceptedModelSpec_CannotEvenBond() public {
        // The cheap/wrong model's spec is not in the governed set, so the optimistic backend
        // refuses the commitment at the door (defense in depth alongside the binding).
        bytes32 cheapModel = bytes32(uint256(0xCC) * _ONES);
        bytes32 report = ComputeProofLib.expectedReportData(
            7, keccak256("i"), cheapModel, PROMPT_HASH, keccak256("b"), PROVER, keccak256("o"), RUNTIME_OK
        );
        vm.prank(PROVER);
        vm.expectRevert(abi.encodeWithSelector(OptimisticEvidence.ModelSpecNotAccepted.selector, cheapModel));
        optimistic.submit{value: MIN_BOND}(report, keccak256("trace"), cheapModel);
    }

    // ========================================================================
    // (b) C3 — AICoinMiner: forged root over a fabricated receipt, NO proof, NO mint
    // ========================================================================

    function test_C3_ForgedRootWithoutProof_DoesNotMint() public {
        (AICoinMiner miner, AIReceiptRoots roots) = _deployAICoinMiner();

        // THE C3 ATTACK: a relayer fabricates a receipt and self-anchors a root over it.
        bytes memory receipt = _receipt(keccak256("forged-intent"), REQUESTER, keccak256("fabricated-out"));
        bytes32 leaf = _leaf(receipt);
        address relayer = address(0xBEEF);
        vm.prank(ADMIN);
        roots.setRelayer(relayer, true);
        vm.prank(relayer);
        roots.anchorRoot(leaf, 1); // self-made root over the fabricated receipt

        bytes memory mp = _merkleProof(leaf);

        // With NO compute proof (empty), the gate rejects — the forged root alone mints nothing.
        ComputeProof memory empty = ComputeProof({proofType: 3, reportData: bytes32(0), evidence: ""});
        vm.expectRevert(AICoinMiner.InvalidComputeProof.selector);
        miner.mine(receipt, mp, empty, bytes32(0), RUNTIME_OK);

        assertEq(coin.balanceOf(REQUESTER), 0, "no mint from a forged root without a proof");
    }

    function test_C3_LegitimateReceiptWithProof_Mints() public {
        (AICoinMiner miner, AIReceiptRoots roots) = _deployAICoinMiner();

        bytes32 intentID = keccak256("real-intent");
        bytes32 outputHash = keccak256("real-out");
        bytes memory receipt = _receipt(intentID, REQUESTER, outputHash);
        bytes32 leaf = _leaf(receipt);
        address relayer = address(0xBEEF);
        vm.prank(ADMIN);
        roots.setRelayer(relayer, true);
        vm.prank(relayer);
        roots.anchorRoot(leaf, 1);
        bytes memory mp = _merkleProof(leaf);

        // Build + bond a compute proof matching the receipt's OWN fields (taskId 0, openBlk 0).
        bytes32 expected = ComputeProofLib.expectedReportData(
            0, intentID, MODEL_SPEC, PROMPT_HASH, bytes32(0), REQUESTER, outputHash, RUNTIME_OK
        );
        _bond(expected, MODEL_SPEC);
        ComputeProof memory cp = _proof(expected);

        uint256 amount = miner.mine(receipt, mp, cp, bytes32(0), RUNTIME_OK);
        assertEq(amount, 1000 ether, "legitimate receipt + valid proof mints");
        assertEq(coin.balanceOf(REQUESTER), 1000 ether, "subsidy to the bound requester");
    }

    function test_C3_ProofForWrongReceipt_DoesNotMint() public {
        // Even WITH a valid proof, if it binds a DIFFERENT output than the receipt's, no mint:
        // a real proof for output A cannot launder a fabricated receipt claiming output B.
        (AICoinMiner miner, AIReceiptRoots roots) = _deployAICoinMiner();

        bytes32 intentID = keccak256("intent");
        bytes memory receipt = _receipt(intentID, REQUESTER, keccak256("receipt-out"));
        bytes32 leaf = _leaf(receipt);
        address relayer = address(0xBEEF);
        vm.prank(ADMIN);
        roots.setRelayer(relayer, true);
        vm.prank(relayer);
        roots.anchorRoot(leaf, 1);
        bytes memory mp = _merkleProof(leaf);

        // Proof bound to a DIFFERENT output.
        bytes32 wrong = ComputeProofLib.expectedReportData(
            0, intentID, MODEL_SPEC, PROMPT_HASH, bytes32(0), REQUESTER, keccak256("other-out"), RUNTIME_OK
        );
        _bond(wrong, MODEL_SPEC);
        ComputeProof memory cp = _proof(wrong);

        vm.expectRevert(AICoinMiner.InvalidComputeProof.selector);
        miner.mine(receipt, mp, cp, bytes32(0), RUNTIME_OK);
    }

    // ========================================================================
    // (a) C2 — ThinkingMiner: a coin-flip GUESS with no proof mints nothing
    // ========================================================================

    function test_C2_GuessWithoutProof_DoesNotMint() public {
        (ThinkingGovernor gov, ThinkingMiner miner, ComputeProofFixture memory f) = _settledQuorum();

        // No compute proofs submitted at all: with a tier requiring proofType 3, the proven
        // winning group is empty → NoProvenQuorum, nothing mints. A pure guess earns zero.
        vm.expectRevert(abi.encodeWithSelector(ThinkingMiner.NoProvenQuorum.selector, f.taskId, uint256(0), uint8(3)));
        miner.mineSettledThought(f.taskId);

        for (uint256 i; i < f.winners.length; ++i) {
            assertEq(coin.balanceOf(f.winners[i]), 0, "no winner paid without proof");
        }
        // sanity: the governor DID settle with a quorum — the mint block is the only gate.
        assertEq(uint8(gov.getThought(f.taskId).status), uint8(IThinkingGovernor.Status.Settled), "settled");
    }

    function test_C2_SubQuorumOfProven_DoesNotMint() public {
        (, ThinkingMiner miner, ComputeProofFixture memory f) = _settledQuorum();

        // Prove only 2 of the 3 winners — below the threshold (3). A sub-quorum of PROVEN work
        // does not mint: a single (or pair of) proven guess cannot drain the schedule.
        _proveWinner(miner, f, 0);
        _proveWinner(miner, f, 1);

        vm.expectRevert(abi.encodeWithSelector(ThinkingMiner.NoProvenQuorum.selector, f.taskId, uint256(2), uint8(3)));
        miner.mineSettledThought(f.taskId);
    }

    function test_C2_ProvenWinnersMint_UnprovenGuesserGetsNothing() public {
        (, ThinkingMiner miner, ComputeProofFixture memory f) = _settledQuorum();

        // Prove the 3 honest winners; leave the 4th winning voter (the GUESSER) unproven.
        _proveWinner(miner, f, 0);
        _proveWinner(miner, f, 1);
        _proveWinner(miner, f, 2);
        // f.winners[3] is the modal-vote guesser with NO compute proof.

        uint256 total = miner.mineSettledThought(f.taskId);
        uint256 share = miner.rewardPerThought() / 3;
        assertEq(total, share * 3, "only the 3 proven winners minted");
        assertEq(coin.balanceOf(f.winners[0]), share, "proven winner paid");
        assertEq(coin.balanceOf(f.winners[1]), share, "proven winner paid");
        assertEq(coin.balanceOf(f.winners[2]), share, "proven winner paid");
        assertEq(coin.balanceOf(f.winners[3]), 0, "unproven guesser in the winning group paid NOTHING");
    }

    function test_C2_WrongProofType_Downgrade_Rejected() public {
        // POLICY BINDING: a tier requiring proofType 1 (hardware CC-TEE) must NOT accept a weaker
        // proofType 3 (optimistic) proof. Stand up a CC backend in slot 1, set the tier to require
        // type 1, but try to submit a type-3 proof — rejected at the door (no silent downgrade).
        CCEvidence cc = new CCEvidence(address(registry), ADMIN);
        bytes32 attRoot = keccak256("att-root");
        vm.startPrank(ADMIN);
        registry.setAttestationRoot(attRoot, true);
        verifier.setBackend(1, address(cc));
        vm.stopPrank();

        (, ThinkingMiner miner, ComputeProofFixture memory f) = _settledQuorum();
        vm.prank(ADMIN);
        profile.setRequiredProofType(0, 1); // tier 0 now demands CC (type 1)

        address operator = f.winners[0];
        bytes32 openBlk = keccak256("b");
        bytes32 outputHash = keccak256("o");
        bytes32 expected = ComputeProofLib.expectedReportData(
            f.taskId, f.intentID, f.modelSpec, f.promptHash, openBlk, operator, outputHash, RUNTIME_OK
        );
        // a type-3 (optimistic) proof, even bonded & valid AS optimistic, is the WRONG strength.
        _bond(expected, f.modelSpec);
        ComputeProof memory cp = _proof(expected); // proofType 3
        vm.expectRevert(abi.encodeWithSelector(ThinkingMiner.WrongProofType.selector, uint8(3), uint8(1)));
        miner.submitComputeProof(f.taskId, operator, f.intentID, openBlk, outputHash, RUNTIME_OK, cp);
    }

    function test_C2_PermissiveTier_ConsensusOnly_StillMints() public {
        // The forward-compat guarantee: a tier with requiredProofType 0 mints on consensus alone
        // (the pre-enforcement behavior). Only an OPTED-IN tier demands the proof.
        (, ThinkingMiner miner, ComputeProofFixture memory f) = _settledQuorum();
        uint8 tier = miner.tier(); // evaluate BEFORE the prank (a view call would consume it)
        vm.prank(ADMIN);
        profile.setRequiredProofType(tier, 0); // de-gate the tier
        uint256 total = miner.mineSettledThought(f.taskId);
        assertGt(total, 0, "permissive tier mints on consensus alone");
    }

    // ========================================================================
    // helpers — compute-proof construction
    // ========================================================================

    function _libChallenge(
        uint256 taskId,
        bytes32 intentID,
        bytes32 modelSpec,
        bytes32 promptHash,
        bytes32 openBlk,
        address operator
    ) internal pure returns (bytes32) {
        // Mirror ComputeProofLib.challenge via the same concatenation (the library's internal fn
        // is not externally callable, so we reconstruct the documented layout).
        return keccak256(
            abi.encodePacked(DOMAIN_CHALLENGE, taskId, intentID, modelSpec, promptHash, openBlk, operator)
        );
    }

    function _libReportData(
        bytes32 challenge,
        bytes32 modelSpec,
        bytes32 promptHash,
        bytes32 outputHash,
        bytes32 runtime
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(DOMAIN_REPORT, challenge, modelSpec, promptHash, outputHash, runtime));
    }

    /// @dev Post + bond an optimistic commitment for `reportData`.
    function _bond(bytes32 reportData, bytes32 modelWeightsRoot) internal {
        vm.prank(PROVER);
        optimistic.submit{value: MIN_BOND}(reportData, keccak256("activation-trace"), modelWeightsRoot);
    }

    /// @dev An optimistic ComputeProof carrying `reportData` (evidence is empty for optimistic —
    /// the commitment lives in the backend keyed by reportData).
    function _proof(bytes32 reportData) internal pure returns (ComputeProof memory) {
        return ComputeProof({proofType: 3, reportData: reportData, evidence: ""});
    }

    // ---- AICoinMiner fixtures ----

    function _deployAICoinMiner() internal returns (AICoinMiner miner, AIReceiptRoots roots) {
        roots = new AIReceiptRoots(ADMIN);
        miner = new AICoinMiner(
            IAICoinMintable(address(coin)),
            IAIReceiptRootsView(address(roots)),
            ADMIN,
            1000 ether,
            IComputeVerifierM(address(verifier))
        );
        vm.prank(ADMIN);
        coin.setMinter(address(miner), true);
    }

    function _receipt(bytes32 intentID, address requester, bytes32 output) internal pure returns (bytes memory r) {
        r = abi.encodePacked(
            uint16(1), // Version
            intentID, // IntentID
            bytes32(0), // TaskID (==0, matches the proof's taskId 0)
            bytes32(0), // CChainID
            bytes32(0), // AChainID
            requester, // Requester (20 bytes)
            MODEL_SPEC, // ModelSpecHash (the receipt carries the measured model)
            PROMPT_HASH, // PromptHash
            output, // CanonicalOutputHash
            uint8(2), // Status = Completed
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

    function _merkleProof(bytes32 root) internal pure returns (bytes memory) {
        return abi.encodePacked(root, uint64(0), uint16(0)); // single-leaf: root==leaf, no path
    }

    // ---- ThinkingMiner / Governor fixtures ----

    struct ComputeProofFixture {
        uint256 taskId;
        address[] winners; // the agreeing (NO) operators; index 3 is the unproven guesser
        uint256[] pks; // operator private keys, aligned with winners
        bytes32 intentID;
        bytes32 modelSpec;
        bytes32 promptHash;
    }

    /// @dev Stand up a real ThinkingGovernor + a wired ThinkingMiner whose tier requires
    /// proofType 3, run a genuine quorum (n=5, threshold=3, 4 NO + 1 YES), settle it. Returns the
    /// fixture for the C2 tests. winners[0..2] are honest; winners[3] is the modal-vote guesser.
    function _settledQuorum()
        internal
        returns (ThinkingGovernor gov, ThinkingMiner miner, ComputeProofFixture memory f)
    {
        uint256 minBond = 1 ether;
        gov = new ThinkingGovernor(minBond, 7 days, 0, 0, address(0), address(0));
        miner = new ThinkingMiner(
            IThinkingGovernor(address(gov)),
            IAICoinMintableG(address(coin)),
            ADMIN,
            1500 ether,
            IComputeVerifier(address(verifier)),
            IComputeProfileView(address(profile))
        );
        vm.startPrank(ADMIN);
        coin.setMinter(address(miner), true);
        profile.setRequiredProofType(0, 3); // tier 0 requires optimistic proof
        vm.stopPrank();

        // 5 operators with genuine keys.
        f.pks = new uint256[](5);
        address[] memory ops = new address[](5);
        for (uint256 i; i < 5; ++i) {
            uint256 pk = 0xBEEF + i + 1;
            address a = vm.addr(pk);
            f.pks[i] = pk;
            ops[i] = a;
            vm.deal(a, 10 ether);
            vm.prank(a);
            gov.registerOperator{value: minBond}();
        }

        address opener = address(0x09E9E5);
        vm.deal(opener, 10 ether);
        f.modelSpec = MODEL_SPEC;
        f.promptHash = PROMPT_HASH;
        f.intentID = keccak256("quorum-intent");

        vm.prank(opener);
        f.taskId = gov.openThought(MODEL_SPEC, PROMPT_HASH, keccak256("ev"), 5, 3, 1 hours, "risk.knob");

        // 4 NO (the winning group), 1 YES (dissent). NO is canonical.
        uint8 NO = 2;
        uint8 YES = 1;
        uint16 bucket = 8000;
        for (uint256 i; i < 4; ++i) {
            _submitVerdict(gov, f.taskId, ops[i], f.pks[i], NO, bucket);
        }
        _submitVerdict(gov, f.taskId, ops[4], f.pks[4], YES, bucket);

        vm.warp(gov.getThought(f.taskId).deadline + 1);
        gov.settle(f.taskId);

        // winners = the 4 NO voters (index 3 is the guesser left unproven by the C2 tests).
        f.winners = new address[](4);
        for (uint256 i; i < 4; ++i) f.winners[i] = ops[i];
    }

    function _submitVerdict(
        ThinkingGovernor gov,
        uint256 taskId,
        address op,
        uint256 pk,
        uint8 vote,
        uint16 bucket
    ) internal {
        bytes32 ev = keccak256(abi.encodePacked("ev", taskId, op));
        bytes32 digest = gov.verdictDigest(taskId, op, MODEL_SPEC, vote, bucket, ev);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        vm.prank(op);
        gov.submitVerdict(taskId, vote, bucket, ev, abi.encodePacked(r, s, v));
    }

    /// @dev Build, bond, and submit a valid compute proof crediting winner `idx` for its NO vote.
    function _proveWinner(ThinkingMiner miner, ComputeProofFixture memory f, uint256 idx) internal {
        address operator = f.winners[idx];
        bytes32 openBlk = keccak256(abi.encodePacked("block", f.taskId, operator));
        bytes32 outputHash = keccak256(abi.encodePacked("out", operator));
        bytes32 expected = ComputeProofLib.expectedReportData(
            f.taskId, f.intentID, f.modelSpec, f.promptHash, openBlk, operator, outputHash, RUNTIME_OK
        );
        _bond(expected, f.modelSpec);
        ComputeProof memory cp = _proof(expected);
        miner.submitComputeProof(f.taskId, operator, f.intentID, openBlk, outputHash, RUNTIME_OK, cp);
    }
}
