// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.31;

import {Test} from "forge-std/Test.sol";
import {AttestationRootRegistry} from "../contracts/deployables/thinking/AttestationRootRegistry.sol";
import {OptimisticEvidence} from "../contracts/deployables/thinking/evidence/OptimisticEvidence.sol";

/// @title OptimisticEvidenceTest
/// @notice Adversary-grade tests of the optimistic compute-proof state machine — the slash logic
/// Red comes for. Proves: a liar always stakes (zero-bond rejected), fraud flips attestation to
/// false and pays the watcher (slash), the commitment is one-shot (no laundering a slashed
/// claim), challenge respects the window, and reclaim returns the bond exactly once.
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
        registry = new AttestationRootRegistry(ADMIN);
        optimistic = new OptimisticEvidence(MIN_BOND, WINDOW, address(registry));
        vm.prank(ADMIN);
        registry.setModelSpec(MODEL_SPEC, true);
        vm.deal(PROVER, 100 ether);
        vm.deal(WATCHER, 1 ether);
    }

    function _submit() internal {
        vm.prank(PROVER);
        optimistic.submit{value: MIN_BOND}(REPORT, keccak256("trace"), MODEL_SPEC);
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

    // ---- the slash: fraud → attests false → bond to watcher -------------------

    function test_Challenge_MarksFraud_PaysWatcher() public {
        _submit();
        uint256 watcherBefore = WATCHER.balance;

        vm.prank(WATCHER);
        optimistic.challenge(REPORT, hex"deadbeef"); // a non-empty discrepancy witness

        assertFalse(optimistic.attests(REPORT, ""), "fraud flips attestation to false");
        assertEq(uint8(optimistic.commitmentOf(REPORT).state), uint8(OptimisticEvidence.State.Fraudulent), "fraudulent");
        assertEq(WATCHER.balance, watcherBefore + MIN_BOND, "challenger took the bond");
        assertEq(address(optimistic).balance, 0, "bond left the contract");
    }

    function test_Challenge_EmptyResponse_Rejected() public {
        _submit();
        vm.prank(WATCHER);
        vm.expectRevert(OptimisticEvidence.EmptyResponse.selector);
        optimistic.challenge(REPORT, "");
    }

    function test_Challenge_AfterWindow_Rejected() public {
        _submit();
        vm.warp(block.timestamp + WINDOW + 1); // window closed → finalized, no longer slashable
        vm.prank(WATCHER);
        vm.expectRevert(abi.encodeWithSelector(OptimisticEvidence.WindowClosed.selector, REPORT));
        optimistic.challenge(REPORT, hex"01");
    }

    function test_Challenge_Unknown_Rejected() public {
        vm.prank(WATCHER);
        vm.expectRevert(abi.encodeWithSelector(OptimisticEvidence.NotPending.selector, REPORT));
        optimistic.challenge(REPORT, hex"01");
    }

    function test_Challenge_DoubleChallenge_Rejected() public {
        _submit();
        vm.prank(WATCHER);
        optimistic.challenge(REPORT, hex"01");
        // second challenge on a now-fraudulent commitment has nothing to slash.
        vm.prank(WATCHER);
        vm.expectRevert(abi.encodeWithSelector(OptimisticEvidence.NotPending.selector, REPORT));
        optimistic.challenge(REPORT, hex"02");
    }

    // ---- no laundering: one-shot per reportData -------------------------------

    function test_Submit_ZeroBond_Rejected() public {
        // A liar MUST have skin in the game; a zero-bond commitment is refused.
        vm.prank(PROVER);
        vm.expectRevert(abi.encodeWithSelector(OptimisticEvidence.BondTooLow.selector, 0, MIN_BOND));
        optimistic.submit{value: 0}(REPORT, keccak256("trace"), MODEL_SPEC);
    }

    function test_Submit_BelowMinBond_Rejected() public {
        vm.prank(PROVER);
        vm.expectRevert(abi.encodeWithSelector(OptimisticEvidence.BondTooLow.selector, MIN_BOND - 1, MIN_BOND));
        optimistic.submit{value: MIN_BOND - 1}(REPORT, keccak256("trace"), MODEL_SPEC);
    }

    function test_Submit_DoubleSubmit_Rejected() public {
        _submit();
        vm.prank(PROVER);
        vm.expectRevert(abi.encodeWithSelector(OptimisticEvidence.AlreadyCommitted.selector, REPORT));
        optimistic.submit{value: MIN_BOND}(REPORT, keccak256("trace"), MODEL_SPEC);
    }

    function test_Submit_ResubmitAfterFraud_Rejected() public {
        // The decisive no-laundering test: a SLASHED commitment cannot be re-posted to wash the
        // fraud and re-attest. The reportData is dead forever.
        _submit();
        vm.prank(WATCHER);
        optimistic.challenge(REPORT, hex"01");
        vm.prank(PROVER);
        vm.expectRevert(abi.encodeWithSelector(OptimisticEvidence.AlreadyCommitted.selector, REPORT));
        optimistic.submit{value: MIN_BOND}(REPORT, keccak256("trace"), MODEL_SPEC);
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
        vm.prank(WATCHER);
        optimistic.challenge(REPORT, hex"01");
        vm.warp(block.timestamp + WINDOW + 1);
        vm.prank(PROVER);
        vm.expectRevert(abi.encodeWithSelector(OptimisticEvidence.NotPending.selector, REPORT));
        optimistic.reclaim(REPORT);
    }

    // ---- a challenged-before-consume proof can never re-enter -------------------

    function test_FraudDuringWindow_PermanentlyInvalid() public {
        _submit();
        vm.prank(WATCHER);
        optimistic.challenge(REPORT, hex"01");
        // even after the window passes, a fraudulent commitment stays false (terminal).
        vm.warp(block.timestamp + WINDOW + 100);
        assertFalse(optimistic.attests(REPORT, ""), "fraud is terminal");
        assertFalse(optimistic.finalized(REPORT), "fraud never finalizes to valid");
    }
}
