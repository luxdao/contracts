// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.31;

import {Test} from "forge-std/Test.sol";
import {ThinkingGovernor} from "../contracts/deployables/thinking/ThinkingGovernor.sol";
import {IThinkingGovernor} from "../contracts/deployables/thinking/interfaces/IThinkingGovernor.sol";

/// @title ThinkingGovernorCommitRevealTest
/// @notice Proves H1 is closed: the Governor's commit-reveal prevents the VALUE-COPY attack the
/// cleartext submit path is open to. The decisive test is {test_H1_PeerCannotCopyCommit}: the
/// only datum public during the commit window is a peer's COMMIT, and it is operator-bound, so a
/// copier who echoes those exact bytes cannot reveal them (the reveal recomputes against the
/// copier's own address → mismatch). Plus: reveal cannot open before the commit window closes,
/// and cleartext submit is barred on a commit-reveal task.
contract ThinkingGovernorCommitRevealTest is Test {
    ThinkingGovernor internal gov;

    uint256 internal constant MIN_BOND = 1 ether;
    uint64 internal constant COOLDOWN = 7 days;
    uint64 internal constant COMMIT_WINDOW = 1 hours;
    uint64 internal constant REVEAL_WINDOW = 1 hours;

    bytes32 internal constant MODEL_SPEC = keccak256("zen/thinking-governor/model-spec/v1");
    bytes32 internal constant PROMPT_HASH = keccak256("should the knob change?");
    string internal constant KNOB_KEY = "risk.maxLeverage";

    struct Op {
        uint256 pk;
        address addr;
    }

    Op[5] internal ops;
    address internal opener;

    function setUp() public {
        gov = new ThinkingGovernor(MIN_BOND, COOLDOWN, 0, 0, address(0), address(0));
        for (uint256 i; i < 5; ++i) {
            uint256 pk = 0xC0FFEE + i + 1;
            address a = vm.addr(pk);
            ops[i] = Op({pk: pk, addr: a});
            vm.deal(a, 10 ether);
            vm.prank(a);
            gov.registerOperator{value: MIN_BOND}();
        }
        opener = address(0xBEEF);
        vm.deal(opener, 100 ether);
    }

    function _openCR(uint8 n, uint8 threshold) internal returns (uint256 taskId) {
        vm.prank(opener);
        taskId = gov.openThoughtCommitReveal(
            MODEL_SPEC, PROMPT_HASH, keccak256("ev"), n, threshold, COMMIT_WINDOW, REVEAL_WINDOW, KNOB_KEY
        );
    }

    function _commit(uint256 taskId, uint256 i, uint8 vote, uint16 bucket, bytes32 nonce)
        internal
        returns (bytes32 ev)
    {
        ev = keccak256(abi.encodePacked("ev", taskId, i));
        bytes32 commit = gov.commitDigest(taskId, ops[i].addr, vote, bucket, ev, nonce);
        vm.prank(ops[i].addr);
        gov.commitVerdict(taskId, commit);
    }

    // ---- the H1 closer: a peer's commit is not copyable ------------------------

    function test_H1_PeerCannotCopyCommit() public {
        uint256 taskId = _openCR(5, 3);

        // Operator 0 commits its real verdict (NO, 80%). The commit bytes become public.
        bytes32 nonce0 = keccak256("op0-secret-nonce");
        bytes32 ev0 = _commit(taskId, 0, 2, 8000, nonce0);
        bytes32 op0Commit = gov.commitDigest(taskId, ops[0].addr, 2, 8000, ev0, nonce0);

        // Operator 1, seeing ONLY op0's commit bytes, copies them verbatim as its own commit.
        vm.prank(ops[1].addr);
        gov.commitVerdict(taskId, op0Commit);

        // Close the commit window; reveal opens.
        vm.warp(block.timestamp + COMMIT_WINDOW + 1);

        // Op0 reveals fine.
        vm.prank(ops[0].addr);
        gov.revealVerdict(taskId, 2, 8000, ev0, nonce0);

        // Op1 CANNOT ride op0's commit: revealing op0's fields recomputes the digest under op1's
        // address → mismatch. The copier has no way to satisfy a commit bound to a DIFFERENT
        // operator, so it cannot copy op0's value to win.
        vm.prank(ops[1].addr);
        vm.expectRevert(abi.encodeWithSelector(IThinkingGovernor.CommitMismatch.selector, taskId, ops[1].addr));
        gov.revealVerdict(taskId, 2, 8000, ev0, nonce0);
    }

    // ---- reveal cannot precede commit-window close -----------------------------

    function test_H1_RevealBeforeCommitWindowCloses_Rejected() public {
        uint256 taskId = _openCR(5, 3);
        bytes32 nonce = keccak256("n");
        bytes32 ev = _commit(taskId, 0, 2, 8000, nonce);
        // still inside the commit window → reveal must be closed (the anti-copy gate).
        vm.prank(ops[0].addr);
        vm.expectRevert(abi.encodeWithSelector(IThinkingGovernor.RevealNotOpen.selector, taskId));
        gov.revealVerdict(taskId, 2, 8000, ev, nonce);
    }

    function test_H1_RevealAfterRevealWindow_Rejected() public {
        uint256 taskId = _openCR(5, 3);
        bytes32 nonce = keccak256("n");
        bytes32 ev = _commit(taskId, 0, 2, 8000, nonce);
        vm.warp(block.timestamp + COMMIT_WINDOW + REVEAL_WINDOW + 1); // both windows closed
        vm.prank(ops[0].addr);
        vm.expectRevert(abi.encodeWithSelector(IThinkingGovernor.RevealClosed.selector, taskId));
        gov.revealVerdict(taskId, 2, 8000, ev, nonce);
    }

    function test_H1_CommitAfterCommitWindow_Rejected() public {
        uint256 taskId = _openCR(5, 3);
        vm.warp(block.timestamp + COMMIT_WINDOW + 1);
        bytes32 ev = keccak256("ev");
        bytes32 commit = gov.commitDigest(taskId, ops[0].addr, 2, 8000, ev, keccak256("n"));
        vm.prank(ops[0].addr);
        vm.expectRevert(abi.encodeWithSelector(IThinkingGovernor.CommitClosed.selector, taskId));
        gov.commitVerdict(taskId, commit);
    }

    // ---- cleartext submit barred on a CR task ----------------------------------

    function test_H1_CleartextSubmitBarred_OnCommitRevealTask() public {
        uint256 taskId = _openCR(5, 3);
        bytes32 ev = keccak256("ev");
        bytes32 digest = gov.verdictDigest(taskId, ops[0].addr, MODEL_SPEC, 2, 8000, ev);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ops[0].pk, digest);
        vm.prank(ops[0].addr);
        vm.expectRevert(abi.encodeWithSelector(IThinkingGovernor.UseCommitReveal.selector, taskId));
        gov.submitVerdict(taskId, 2, 8000, ev, abi.encodePacked(r, s, v));
    }

    function test_H1_CommitRevealCalls_BarredOnCleartextTask() public {
        // The mirror: commit/reveal cannot be called on a plain openThought task.
        vm.prank(opener);
        uint256 taskId = gov.openThought(MODEL_SPEC, PROMPT_HASH, keccak256("ev"), 5, 3, 1 hours, KNOB_KEY);
        vm.prank(ops[0].addr);
        vm.expectRevert(abi.encodeWithSelector(IThinkingGovernor.NotCommitReveal.selector, taskId));
        gov.commitVerdict(taskId, keccak256("c"));
    }

    // ---- happy path: commit → reveal → settle → knob ---------------------------

    function test_H1_FullCommitRevealSettle_SetsKnob() public {
        uint256 taskId = _openCR(5, 3);

        // 3 YES commits (the winning group) + 2 NO. nonces differ per operator.
        bytes32[5] memory ev;
        uint8[5] memory votes = [uint8(1), 1, 1, 2, 2]; // YES, YES, YES, NO, NO
        for (uint256 i; i < 5; ++i) {
            ev[i] = _commit(taskId, i, votes[i], 8000, keccak256(abi.encodePacked("nonce", i)));
        }

        vm.warp(block.timestamp + COMMIT_WINDOW + 1); // reveal opens

        for (uint256 i; i < 5; ++i) {
            vm.prank(ops[i].addr);
            gov.revealVerdict(taskId, votes[i], 8000, ev[i], keccak256(abi.encodePacked("nonce", i)));
        }

        vm.warp(gov.getThought(taskId).deadline + 1); // settle gate (== revealDeadline) passed
        gov.settle(taskId);

        IThinkingGovernor.Thought memory t = gov.getThought(taskId);
        assertEq(uint8(t.status), uint8(IThinkingGovernor.Status.Settled), "settled");
        assertEq(uint8(t.canonicalVote), 1, "YES won");
        assertEq(t.agreeCount, 3, "3 agreed");
        // the knob is set by the YES quorum, scoped to the spec.
        assertTrue(gov.getKnob(MODEL_SPEC, KNOB_KEY) != bytes32(0), "knob set by the CR quorum");
    }

    function test_H1_DoubleReveal_Rejected() public {
        uint256 taskId = _openCR(5, 3);
        bytes32 nonce = keccak256("n");
        bytes32 ev = _commit(taskId, 0, 2, 8000, nonce);
        vm.warp(block.timestamp + COMMIT_WINDOW + 1);
        vm.prank(ops[0].addr);
        gov.revealVerdict(taskId, 2, 8000, ev, nonce);
        vm.prank(ops[0].addr);
        vm.expectRevert(abi.encodeWithSelector(IThinkingGovernor.AlreadyVoted.selector, taskId, ops[0].addr));
        gov.revealVerdict(taskId, 2, 8000, ev, nonce);
    }

    function test_H1_RevealWithoutCommit_Rejected() public {
        uint256 taskId = _openCR(5, 3);
        vm.warp(block.timestamp + COMMIT_WINDOW + 1);
        vm.prank(ops[0].addr);
        vm.expectRevert(abi.encodeWithSelector(IThinkingGovernor.NotCommitted.selector, taskId, ops[0].addr));
        gov.revealVerdict(taskId, 2, 8000, keccak256("ev"), keccak256("n"));
    }

    function test_H1_RevealWrongFields_Rejected() public {
        // Revealing DIFFERENT fields than were committed (e.g. flipping the vote post-hoc) fails:
        // the commit binds the exact verdict, so an operator cannot change its answer at reveal.
        uint256 taskId = _openCR(5, 3);
        bytes32 nonce = keccak256("n");
        bytes32 ev = _commit(taskId, 0, 2, 8000, nonce); // committed NO
        vm.warp(block.timestamp + COMMIT_WINDOW + 1);
        vm.prank(ops[0].addr);
        vm.expectRevert(abi.encodeWithSelector(IThinkingGovernor.CommitMismatch.selector, taskId, ops[0].addr));
        gov.revealVerdict(taskId, 1, 8000, ev, nonce); // try to reveal YES
    }

    function test_H1_DoubleCommit_Rejected() public {
        uint256 taskId = _openCR(5, 3);
        _commit(taskId, 0, 2, 8000, keccak256("n"));
        bytes32 commit2 = gov.commitDigest(taskId, ops[0].addr, 1, 8000, keccak256("ev2"), keccak256("n2"));
        vm.prank(ops[0].addr);
        vm.expectRevert(abi.encodeWithSelector(IThinkingGovernor.AlreadyCommitted.selector, taskId, ops[0].addr));
        gov.commitVerdict(taskId, commit2);
    }

    function test_H1_BadWindow_Rejected() public {
        vm.prank(opener);
        vm.expectRevert(abi.encodeWithSelector(IThinkingGovernor.BadCommitRevealWindow.selector, uint64(1), REVEAL_WINDOW));
        gov.openThoughtCommitReveal(MODEL_SPEC, PROMPT_HASH, keccak256("ev"), 5, 3, 1, REVEAL_WINDOW, KNOB_KEY);
    }
}
