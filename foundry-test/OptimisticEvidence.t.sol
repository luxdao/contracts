// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.31;

import {Test} from "forge-std/Test.sol";
import {AttestationRootRegistry} from "../contracts/deployables/thinking/AttestationRootRegistry.sol";
import {OptimisticEvidence} from "../contracts/deployables/thinking/evidence/OptimisticEvidence.sol";
import {ComputeWitnessLib} from "../contracts/deployables/thinking/ComputeWitnessLib.sol";

/// @title OptimisticEvidenceTest
/// @notice Adversary-grade tests of the optimistic compute-proof state machine — the slash logic
/// Red comes for. Post-audit (G6): a challenge no longer slashes on "any non-empty bytes". It must
/// EXHIBIT a fabricated matmul that the contract re-checks ON-CHAIN (Merkle inclusion under the
/// committed activationTraceRoot + Freivalds over F_p). So this suite now proves: a real
/// fabrication slashes and pays the watcher; an HONEST commitment CANNOT be slashed; a griefer
/// cannot frame an honest prover with a made-up opening; plus one-shot, window, and reclaim.
contract OptimisticEvidenceTest is Test {
    AttestationRootRegistry registry;
    OptimisticEvidence optimistic;

    address constant ADMIN = address(0xA11CE);
    address constant PROVER = address(0xD00D);
    address constant WATCHER = address(0x404);
    uint256 constant MIN_BOND = 1 ether;
    uint64 constant WINDOW = 1 hours;

    bytes32 constant MODEL_SPEC = bytes32(uint256(0x5e) * _ONES);
    uint256 internal constant _ONES = 0x0101010101010101010101010101010101010101010101010101010101010101;
    bytes32 constant REPORT = keccak256("report-data-fixture");

    function setUp() public {
        vm.warp(1_700_000_000);
        vm.roll(1000); // sit well past genesis so blockhash(commitBlock) is a valid beacon
        registry = new AttestationRootRegistry(ADMIN);
        optimistic = new OptimisticEvidence(MIN_BOND, WINDOW, address(registry));
        vm.prank(ADMIN);
        registry.setModelSpec(MODEL_SPEC, true);
        vm.deal(PROVER, 100 ether);
        vm.deal(WATCHER, 1 ether);
    }

    // ---- the proof-bearing matmul fixture: A·B with one fabricated output -------
    // A=[[1,2],[3,4]] B=[[5,6],[7,8]] → honest C=[[19,22],[43,50]]; fake flips 50→51.

    function _A() internal pure returns (ComputeWitnessLib.Matrix memory) {
        return ComputeWitnessLib.Matrix(2, 2, _d4(1, 2, 3, 4));
    }

    function _B() internal pure returns (ComputeWitnessLib.Matrix memory) {
        return ComputeWitnessLib.Matrix(2, 2, _d4(5, 6, 7, 8));
    }

    function _honestC() internal pure returns (ComputeWitnessLib.Matrix memory) {
        return ComputeWitnessLib.Matrix(2, 2, _d4(19, 22, 43, 50));
    }

    function _fakeC() internal pure returns (ComputeWitnessLib.Matrix memory) {
        return ComputeWitnessLib.Matrix(2, 2, _d4(19, 22, 43, 51));
    }

    function _d4(int64 a, int64 b, int64 c, int64 d) internal pure returns (int64[] memory o) {
        o = new int64[](4);
        (o[0], o[1], o[2], o[3]) = (a, b, c, d);
    }

    // a 1-matmul transcript: root == the single leaf, so the inclusion proof is empty.
    function _fraudRoot() internal pure returns (bytes32) {
        return ComputeWitnessLib.matmulLeaf(_A(), _B(), _fakeC());
    }

    function _honestRoot() internal pure returns (bytes32) {
        return ComputeWitnessLib.matmulLeaf(_A(), _B(), _honestC());
    }

    function _emptyProof() internal pure returns (bytes32[] memory) {
        return new bytes32[](0);
    }

    // submit a commitment whose committed trace root is a FABRICATED matmul (so a fraud proof
    // exists), and advance one block so blockhash(commitBlock) is available as the beacon.
    function _submit() internal {
        vm.prank(PROVER);
        optimistic.submit{value: MIN_BOND}(REPORT, _fraudRoot(), MODEL_SPEC);
        vm.roll(block.number + 1);
    }

    function _challengeFraud(address who) internal {
        vm.prank(who);
        optimistic.challenge(REPORT, 0, _A(), _B(), _fakeC(), _emptyProof());
    }

    // ---- happy path + the optimistic guarantee --------------------------------

    function test_Submit_RecordsAndAttests() public {
        _submit();
        assertTrue(optimistic.attests(REPORT, ""), "a fresh bonded commitment attests");
        OptimisticEvidence.Commitment memory c = optimistic.commitmentOf(REPORT);
        assertEq(uint8(c.state), uint8(OptimisticEvidence.State.Pending), "pending");
        assertEq(c.prover, PROVER, "prover bound");
        assertEq(c.bond, MIN_BOND, "bond escrowed");
        assertEq(address(optimistic).balance, MIN_BOND, "contract holds the bond");
    }

    // ---- the slash: a VERIFIED fraud → attests false → bond to watcher ---------

    function test_Challenge_VerifiedFraud_MarksFraud_PaysWatcher() public {
        _submit();
        uint256 watcherBefore = WATCHER.balance;

        _challengeFraud(WATCHER); // exhibits the fabricated matmul; the EVM re-checks it

        assertFalse(optimistic.attests(REPORT, ""), "fraud flips attestation to false");
        assertEq(uint8(optimistic.commitmentOf(REPORT).state), uint8(OptimisticEvidence.State.Fraudulent), "fraudulent");
        assertEq(WATCHER.balance, watcherBefore + MIN_BOND, "challenger took the bond");
        assertEq(address(optimistic).balance, 0, "bond left the contract");
    }

    // THE AUDIT FLIP: an HONEST commitment cannot be slashed. A challenger opening the genuine
    // matmul gets NotFraudulent — the gate no longer slashes on a bare claim.
    function test_Challenge_HonestCommitment_CannotBeSlashed() public {
        vm.prank(PROVER);
        optimistic.submit{value: MIN_BOND}(REPORT, _honestRoot(), MODEL_SPEC);
        vm.roll(block.number + 1);
        vm.prank(WATCHER);
        vm.expectRevert(abi.encodeWithSelector(OptimisticEvidence.NotFraudulent.selector, REPORT));
        optimistic.challenge(REPORT, 0, _A(), _B(), _honestC(), _emptyProof());
        assertTrue(optimistic.attests(REPORT, ""), "an honest prover stays attested");
    }

    // A griefer cannot frame an honest prover by submitting a fabricated opening that was never
    // committed: Merkle inclusion under the honest root fails, so the fraud proof is rejected.
    function test_Challenge_FabricatedOpeningNotCommitted_Rejected() public {
        vm.prank(PROVER);
        optimistic.submit{value: MIN_BOND}(REPORT, _honestRoot(), MODEL_SPEC);
        vm.roll(block.number + 1);
        vm.prank(WATCHER);
        vm.expectRevert(abi.encodeWithSelector(OptimisticEvidence.NotFraudulent.selector, REPORT));
        optimistic.challenge(REPORT, 0, _A(), _B(), _fakeC(), _emptyProof()); // fakeC not in honest root
    }

    function test_Challenge_AfterWindow_Rejected() public {
        _submit();
        vm.warp(block.timestamp + WINDOW + 1); // window closed → finalized, no longer slashable
        vm.prank(WATCHER);
        vm.expectRevert(abi.encodeWithSelector(OptimisticEvidence.WindowClosed.selector, REPORT));
        optimistic.challenge(REPORT, 0, _A(), _B(), _fakeC(), _emptyProof());
    }

    function test_Challenge_Unknown_Rejected() public {
        vm.prank(WATCHER);
        vm.expectRevert(abi.encodeWithSelector(OptimisticEvidence.NotPending.selector, REPORT));
        optimistic.challenge(REPORT, 0, _A(), _B(), _fakeC(), _emptyProof());
    }

    function test_Challenge_DoubleChallenge_Rejected() public {
        _submit();
        _challengeFraud(WATCHER);
        // second challenge on a now-fraudulent commitment has nothing to slash.
        vm.prank(WATCHER);
        vm.expectRevert(abi.encodeWithSelector(OptimisticEvidence.NotPending.selector, REPORT));
        optimistic.challenge(REPORT, 0, _A(), _B(), _fakeC(), _emptyProof());
    }

    // ---- no laundering: one-shot per reportData -------------------------------

    function test_Submit_ZeroBond_Rejected() public {
        // A liar MUST have skin in the game; a zero-bond commitment is refused.
        vm.prank(PROVER);
        vm.expectRevert(abi.encodeWithSelector(OptimisticEvidence.BondTooLow.selector, 0, MIN_BOND));
        optimistic.submit{value: 0}(REPORT, _fraudRoot(), MODEL_SPEC);
    }

    function test_Submit_BelowMinBond_Rejected() public {
        vm.prank(PROVER);
        vm.expectRevert(abi.encodeWithSelector(OptimisticEvidence.BondTooLow.selector, MIN_BOND - 1, MIN_BOND));
        optimistic.submit{value: MIN_BOND - 1}(REPORT, _fraudRoot(), MODEL_SPEC);
    }

    function test_Submit_DoubleSubmit_Rejected() public {
        _submit();
        vm.prank(PROVER);
        vm.expectRevert(abi.encodeWithSelector(OptimisticEvidence.AlreadyCommitted.selector, REPORT));
        optimistic.submit{value: MIN_BOND}(REPORT, _fraudRoot(), MODEL_SPEC);
    }

    function test_Submit_ResubmitAfterFraud_Rejected() public {
        // The decisive no-laundering test: a SLASHED commitment cannot be re-posted to wash the
        // fraud and re-attest. The reportData is dead forever.
        _submit();
        _challengeFraud(WATCHER);
        vm.prank(PROVER);
        vm.expectRevert(abi.encodeWithSelector(OptimisticEvidence.AlreadyCommitted.selector, REPORT));
        optimistic.submit{value: MIN_BOND}(REPORT, _fraudRoot(), MODEL_SPEC);
    }

    function test_Submit_ZeroActivationTrace_Rejected() public {
        vm.prank(PROVER);
        vm.expectRevert(OptimisticEvidence.ZeroActivationTrace.selector);
        optimistic.submit{value: MIN_BOND}(REPORT, bytes32(0), MODEL_SPEC);
    }

    // ---- reclaim: bond back after an un-challenged window ----------------------

    function test_Reclaim_AfterWindow_ReturnsBond_GuaranteeLapses() public {
        _submit();
        assertTrue(optimistic.finalized(REPORT) == false, "not finalized during window");
        vm.warp(block.timestamp + WINDOW + 1);
        assertTrue(optimistic.finalized(REPORT), "finalized after the window with no fraud");

        uint256 proverBefore = PROVER.balance;
        vm.prank(PROVER);
        optimistic.reclaim(REPORT);
        assertEq(PROVER.balance, proverBefore + MIN_BOND, "bond returned");
        assertEq(uint8(optimistic.commitmentOf(REPORT).state), uint8(OptimisticEvidence.State.Reclaimed), "reclaimed");
        // Once reclaimed, the optimistic guarantee has lapsed — attests() is false.
        assertFalse(optimistic.attests(REPORT, ""), "reclaimed commitment no longer attests");
    }

    function test_Reclaim_BeforeWindow_Rejected() public {
        _submit();
        vm.prank(PROVER);
        vm.expectRevert(abi.encodeWithSelector(OptimisticEvidence.WindowOpen.selector, REPORT));
        optimistic.reclaim(REPORT);
    }

    function test_Reclaim_NotProver_Rejected() public {
        _submit();
        vm.warp(block.timestamp + WINDOW + 1);
        vm.prank(WATCHER);
        vm.expectRevert(abi.encodeWithSelector(OptimisticEvidence.NotProver.selector, WATCHER));
        optimistic.reclaim(REPORT);
    }

    function test_Reclaim_DoubleReclaim_Rejected() public {
        _submit();
        vm.warp(block.timestamp + WINDOW + 1);
        vm.prank(PROVER);
        optimistic.reclaim(REPORT);
        vm.prank(PROVER);
        vm.expectRevert(abi.encodeWithSelector(OptimisticEvidence.NotPending.selector, REPORT));
        optimistic.reclaim(REPORT);
    }

    function test_Reclaim_AfterFraud_Rejected() public {
        // A slashed prover cannot also reclaim — the bond already went to the watcher.
        _submit();
        _challengeFraud(WATCHER);
        vm.warp(block.timestamp + WINDOW + 1);
        vm.prank(PROVER);
        vm.expectRevert(abi.encodeWithSelector(OptimisticEvidence.NotPending.selector, REPORT));
        optimistic.reclaim(REPORT);
    }

    // ---- a challenged-before-consume proof can never re-enter -------------------

    function test_FraudDuringWindow_PermanentlyInvalid() public {
        _submit();
        _challengeFraud(WATCHER);
        // even after the window passes, a fraudulent commitment stays false (terminal).
        vm.warp(block.timestamp + WINDOW + 100);
        assertFalse(optimistic.attests(REPORT, ""), "fraud is terminal");
        assertFalse(optimistic.finalized(REPORT), "fraud never finalizes to valid");
    }
}
