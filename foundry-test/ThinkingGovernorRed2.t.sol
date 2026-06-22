// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.31;

import "forge-std/Test.sol";

import {ThinkingGovernor} from "../contracts/deployables/thinking/ThinkingGovernor.sol";
import {IThinkingGovernor} from "../contracts/deployables/thinking/interfaces/IThinkingGovernor.sol";
import {KeyValuePairsV1} from "../contracts/singletons/KeyValuePairsV1.sol";

/// @title ThinkingGovernorRed2 — RE-REVIEW PoCs, post round-2 fixes.
/// @notice RED-2 found C1 (HIGH, self-censorship via deregister), E1/E4 (MEDIUM,
/// count==n bypasses the deadline), B1 (MEDIUM, 60s window starves quorum), D2 (LOW,
/// treasury==opener). Blue fixed all four. These tests confirm each fix:
///   - settle-time drop now keys on BOND (_bonded), not the deregister flag (C1)
///   - the count==n shortcut is removed: settle ALWAYS requires the deadline (E1/E4)
///   - MIN_VOTING_WINDOW raised to 1h (B1)
///   - openThought reverts OpenerIsTreasury (D2)
/// *_FIXED_* = a former exploit now blocked; *_OK_* = a defense RED confirmed holds.
contract ThinkingGovernorRed2Test is Test {
    ThinkingGovernor internal gov;
    KeyValuePairsV1 internal kvp;

    uint256 internal constant MIN_BOND = 1 ether;
    uint64 internal constant COOLDOWN = 7 days;
    uint256 internal constant REWARD = 0.5 ether;
    uint256 internal constant OPEN_FEE = 0.1 ether;
    uint64 internal constant WINDOW = 1 hours;
    address internal constant TREASURY = address(0x7EA5);

    bytes32 internal constant MODEL_SPEC = keccak256("zen/thinking-governor/model-spec/v1");
    bytes32 internal constant PROMPT_HASH = keccak256("q");
    bytes32 internal constant TASK_EVIDENCE = keccak256("ev");
    string internal constant KNOB_KEY = "risk.maxLeverage";

    struct Op {
        uint256 pk;
        address addr;
    }

    Op[12] internal ops;

    function setUp() public {
        kvp = new KeyValuePairsV1();
        gov = new ThinkingGovernor(MIN_BOND, COOLDOWN, REWARD, OPEN_FEE, TREASURY, address(kvp));
        for (uint256 i; i < 12; ++i) {
            uint256 pk = 0xD00D + i + 1;
            address a = vm.addr(pk);
            ops[i] = Op({pk: pk, addr: a});
            vm.deal(a, 100 ether);
            vm.prank(a);
            gov.registerOperator{value: MIN_BOND}();
        }
    }

    // ------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------

    function _sig(ThinkingGovernor g, uint256 taskId, Op memory o, bytes32 spec, uint8 vote, uint16 bucket, bytes32 ev)
        internal
        pure
        returns (bytes memory)
    {
        bytes32 digest = g.verdictDigest(taskId, o.addr, spec, vote, bucket, ev);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(o.pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _submit(ThinkingGovernor g, uint256 taskId, Op memory o, uint8 vote, uint16 bucket, bytes32 ev) internal {
        bytes memory sig = _sig(g, taskId, o, MODEL_SPEC, vote, bucket, ev);
        vm.prank(o.addr);
        g.submitVerdict(taskId, vote, bucket, ev, sig);
    }

    function _open(ThinkingGovernor g, address opener, uint8 n, uint8 threshold, uint64 window)
        internal
        returns (uint256 taskId)
    {
        vm.deal(opener, 100 ether);
        vm.prank(opener);
        taskId =
            g.openThought{value: REWARD + OPEN_FEE}(MODEL_SPEC, PROMPT_HASH, TASK_EVIDENCE, n, threshold, window, KNOB_KEY);
    }

    function _close(ThinkingGovernor g, uint256 taskId) internal {
        vm.warp(g.getThought(taskId).deadline + 1);
    }

    // ==================================================================
    // C [HIGH] — deregister-to-suppress-own-vote — FIXED (drop keys on bond)
    // ==================================================================

    /// @notice FIXED (C1): the settle-time drop now keys on BOND (_bonded), not the
    /// deregister flag. A quorum member that merely deregisters (bond still locked)
    /// can NO LONGER erase its own counted vote — the decision it voted for stands.
    function test_C1_FIXED_DeregisterDoesNotSuppressOwnVote() public {
        uint256 task = _open(gov, address(0xC0DE), 3, 2, WINDOW);
        _submit(gov, task, ops[0], 1, 8000, keccak256("a"));
        _submit(gov, task, ops[1], 1, 8000, keccak256("b"));
        assertEq(gov.getThought(task).submissionCount, 2, "two YES stored");

        // ops1 deregisters (cannot cast NEW verdicts) but its bond is still locked.
        vm.prank(ops[1].addr);
        gov.deregister();
        assertFalse(gov.isOperator(ops[1].addr), "ops1 cannot cast NEW verdicts");

        _close(gov, task);
        gov.settle(task);

        // The 2/3 YES quorum SURVIVES: a deregistered-but-bonded vote still counts.
        (bool settled, IThinkingGovernor.Vote vote,, uint8 agree) = gov.getCanonicalVerdict(task);
        assertTrue(settled && vote == IThinkingGovernor.Vote.Yes, "FIXED: decision NOT suppressed");
        assertEq(agree, 2, "both YES counted despite ops1 deregistering");
        assertEq(
            gov.getKnob(MODEL_SPEC, KNOB_KEY),
            bytes32((uint256(2) << 24) | (uint256(8000) << 8) | uint256(1)),
            "knob set: decision stands"
        );
    }

    /// @notice The zero-skin protection is preserved: an operator that fully WITHDRAWS
    /// (bond -> 0) before settle IS still dropped (cooldown=0 instance to exit in-test).
    function test_C1b_OK_WithdrawnOperatorStillDropped() public {
        ThinkingGovernor g2 = new ThinkingGovernor(MIN_BOND, 0, REWARD, OPEN_FEE, TREASURY, address(kvp));
        for (uint256 i; i < 2; ++i) {
            vm.prank(ops[i].addr);
            g2.registerOperator{value: MIN_BOND}();
        }
        uint256 task = _open(g2, address(0xC0DE), 3, 2, WINDOW);
        _submit(g2, task, ops[0], 1, 8000, keccak256("a"));
        _submit(g2, task, ops[1], 1, 8000, keccak256("b"));

        vm.prank(ops[1].addr);
        g2.deregister();
        vm.prank(ops[1].addr);
        g2.withdrawBond();
        assertEq(g2.bondOf(ops[1].addr), 0, "ops1 fully withdrawn");

        _close(g2, task);
        g2.settle(task);
        (bool settled,,, uint8 agree) = g2.getCanonicalVerdict(task);
        assertFalse(settled, "withdrawn (zero-skin) vote dropped -> 1 YES < 2 -> Failed");
        assertEq(agree, 0, "zero-skin operator correctly dropped");
    }

    /// @notice Strict-majority bound: churn can only collapse Settled->Failed, never flip
    /// WHICH group wins (two quorum groups are impossible). Dropping a YES makes YES=2,
    /// NO=2, both < 3 -> Failed; NO never becomes canonical. (Uses full withdrawal so the
    /// vote is actually dropped under the new bond-keyed predicate.)
    function test_C2_OK_CannotFlipWinnerOnlySuppress() public {
        ThinkingGovernor g2 = new ThinkingGovernor(MIN_BOND, 0, REWARD, OPEN_FEE, TREASURY, address(kvp));
        for (uint256 i; i < 5; ++i) {
            vm.prank(ops[i].addr);
            g2.registerOperator{value: MIN_BOND}();
        }
        uint256 task = _open(g2, address(0xC0DE), 5, 3, WINDOW);
        _submit(g2, task, ops[0], 1, 8000, keccak256("y0"));
        _submit(g2, task, ops[1], 1, 8000, keccak256("y1"));
        _submit(g2, task, ops[2], 1, 8000, keccak256("y2")); // YES=3 (quorum)
        _submit(g2, task, ops[3], 2, 2000, keccak256("n0"));
        _submit(g2, task, ops[4], 2, 2000, keccak256("n1")); // NO=2 (never a quorum)

        // ops2 fully exits -> YES=2, NO=2, both < 3 -> Failed (NO does NOT win).
        vm.prank(ops[2].addr);
        g2.deregister();
        vm.prank(ops[2].addr);
        g2.withdrawBond();

        _close(g2, task);
        g2.settle(task);
        (bool settled, IThinkingGovernor.Vote vote,,) = g2.getCanonicalVerdict(task);
        assertFalse(settled, "collapsed to Failed");
        assertEq(uint8(vote), uint8(IThinkingGovernor.Vote.Invalid), "OK: NO group did NOT become canonical");
    }

    /// @notice agreeing.length == bestCount exactly under churn (tally and collect use the
    /// SAME _bonded predicate in one settle, so they cannot disagree).
    function test_C3_OK_AgreeingLengthMatchesBestCountUnderChurn() public {
        ThinkingGovernor g2 = new ThinkingGovernor(MIN_BOND, 0, REWARD, OPEN_FEE, TREASURY, address(kvp));
        for (uint256 i; i < 6; ++i) {
            vm.prank(ops[i].addr);
            g2.registerOperator{value: MIN_BOND}();
        }
        uint256 task = _open(g2, address(0xC0DE), 6, 4, WINDOW);
        for (uint256 i; i < 5; ++i) _submit(g2, task, ops[i], 1, 8000, keccak256(abi.encodePacked("y", i)));
        _submit(g2, task, ops[5], 2, 2000, keccak256("n"));

        // ops4 fully exits -> eligible YES = 4 == threshold, still a quorum.
        vm.prank(ops[4].addr);
        g2.deregister();
        vm.prank(ops[4].addr);
        g2.withdrawBond();

        _close(g2, task);
        g2.settle(task);
        (bool settled,,, uint8 agree) = g2.getCanonicalVerdict(task);
        assertTrue(settled, "still a quorum at 4");
        assertEq(agree, 4, "OK: agree count == eligible YES (no over/under-fill)");
        uint256 sum;
        for (uint256 i; i < 4; ++i) sum += g2.rewardOf(ops[i].addr);
        assertEq(sum, REWARD, "OK: full escrow split among the 4 bonded agreers");
        assertEq(g2.rewardOf(ops[4].addr), 0, "OK: withdrawn voter gets nothing");
    }

    /// @notice bestCount==0 (ALL voters withdrew) -> Failed cleanly: no div-by-zero,
    /// opener refunded.
    function test_C4_OK_AllDroppedFailsCleanly() public {
        ThinkingGovernor g2 = new ThinkingGovernor(MIN_BOND, 0, REWARD, OPEN_FEE, TREASURY, address(kvp));
        for (uint256 i; i < 3; ++i) {
            vm.prank(ops[i].addr);
            g2.registerOperator{value: MIN_BOND}();
        }
        uint256 task = _open(g2, address(0xC0DE), 3, 2, WINDOW);
        for (uint256 i; i < 3; ++i) _submit(g2, task, ops[i], 1, 8000, keccak256(abi.encodePacked("z", i)));

        for (uint256 i; i < 3; ++i) {
            vm.prank(ops[i].addr);
            g2.deregister();
            vm.prank(ops[i].addr);
            g2.withdrawBond();
        }
        _close(g2, task);
        g2.settle(task);
        (bool settled,,, uint8 agree) = g2.getCanonicalVerdict(task);
        assertFalse(settled, "all withdrawn -> Failed");
        assertEq(agree, 0, "no agreeing group");
        assertEq(g2.rewardOf(address(0xC0DE)), REWARD, "OK: opener refunded, no div-by-zero");
    }

    // ==================================================================
    // D — openFee / treasury accounting
    // ==================================================================

    /// @notice D1 (OK): treasury is ALSO an agreeing operator. The open fee AND the reward
    /// share both credit _rewards[treasury]; they ADD (not stomp). Opener is a distinct
    /// party (treasury==opener is now rejected — see D2).
    function test_D1_OK_TreasuryIsAgreeingOperator_FeePlusRewardAdd() public {
        address tre = ops[0].addr;
        ThinkingGovernor g2 = new ThinkingGovernor(MIN_BOND, COOLDOWN, REWARD, OPEN_FEE, tre, address(kvp));
        for (uint256 i; i < 3; ++i) {
            vm.prank(ops[i].addr);
            g2.registerOperator{value: MIN_BOND}();
        }
        uint256 task = _open(g2, address(0xC0DE), 3, 2, WINDOW);
        assertEq(g2.rewardOf(tre), OPEN_FEE, "fee credited to treasury operator");

        for (uint256 i; i < 3; ++i) _submit(g2, task, ops[i], 1, 8000, keccak256(abi.encodePacked("d", i)));
        _close(g2, task);
        g2.settle(task);

        uint256 share = REWARD / 3;
        uint256 remainder = REWARD - share * 3;
        assertEq(g2.rewardOf(tre), OPEN_FEE + share + remainder, "OK: fee + reward ADD, no stomp");
        assertEq(g2.rewardOf(ops[1].addr), share, "ops1 share");
        assertEq(g2.rewardOf(ops[2].addr), share, "ops2 share");

        uint256 total = g2.rewardOf(tre) + g2.rewardOf(ops[1].addr) + g2.rewardOf(ops[2].addr);
        assertEq(total, OPEN_FEE + REWARD, "OK: no value created or destroyed");
    }

    /// @notice FIXED (D2): treasury == opener is now rejected at openThought
    /// (OpenerIsTreasury). The "non-refundable" fee can no longer round-trip to a
    /// self-dealing opener-as-treasury.
    function test_D2_FIXED_TreasuryEqualsOpenerRejected() public {
        address attacker = ops[0].addr; // attacker would be both opener AND treasury
        ThinkingGovernor g2 = new ThinkingGovernor(MIN_BOND, COOLDOWN, REWARD, OPEN_FEE, attacker, address(kvp));
        vm.deal(attacker, 100 ether);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IThinkingGovernor.OpenerIsTreasury.selector, attacker));
        g2.openThought{value: REWARD + OPEN_FEE}(MODEL_SPEC, PROMPT_HASH, TASK_EVIDENCE, 3, 2, WINDOW, KNOB_KEY);
    }

    /// @notice D3 (INFO): _rewards[treasury] is not drainable by a non-treasury caller.
    function test_D3_INFO_TreasuryRewardsNotDrainableByOthers() public {
        _open(gov, address(0xC0DE), 3, 2, WINDOW);
        assertEq(gov.rewardOf(TREASURY), OPEN_FEE, "fee at treasury");
        vm.prank(address(0xBEEF));
        vm.expectRevert(); // NothingToWithdraw
        gov.claimReward();
        assertEq(gov.rewardOf(TREASURY), OPEN_FEE, "OK: _rewards[treasury] not drainable by others");
    }

    // ==================================================================
    // E — count==n bypass — FIXED (settle ALWAYS requires the deadline)
    // ==================================================================

    /// @notice FIXED (E1): a full committee no longer settles pre-deadline. Sybils that
    /// saturate the committee can NOT settle before honest operators get the full window.
    function test_E1_FIXED_FullCommitteeCannotSettlePreDeadline() public {
        uint8 n = 5;
        uint256 task = _open(gov, address(0xC0DE), n, 3, WINDOW);
        assertLt(block.timestamp, gov.getThought(task).deadline, "pre-deadline");

        for (uint256 i; i < n; ++i) _submit(gov, task, ops[i], 1, 8000, keccak256(abi.encodePacked("f", i)));

        // count==n no longer short-circuits: settle reverts until the deadline.
        vm.expectRevert(
            abi.encodeWithSelector(IThinkingGovernor.SettleTooEarly.selector, task, gov.getThought(task).deadline)
        );
        gov.settle(task);

        // After the window, it settles normally.
        _close(gov, task);
        gov.settle(task);
        (bool settled,, , uint8 agree) = gov.getCanonicalVerdict(task);
        assertTrue(settled, "settles after window");
        assertEq(agree, 5, "all agreed");
    }

    /// @notice E2 (OK): partial fill is also gated pre-deadline (unchanged).
    function test_E2_OK_PartialFillStillGatedPreDeadline() public {
        uint256 task = _open(gov, address(0xC0DE), 5, 3, WINDOW);
        for (uint256 i; i < 4; ++i) _submit(gov, task, ops[i], 1, 8000, keccak256(abi.encodePacked("p", i)));
        vm.expectRevert(
            abi.encodeWithSelector(IThinkingGovernor.SettleTooEarly.selector, task, gov.getThought(task).deadline)
        );
        gov.settle(task);
    }

    /// @notice FIXED (E4): a griefer can no longer fill the committee to force an early
    /// settle before honest operators vote — the deadline must elapse regardless of count.
    function test_E4_FIXED_FillCannotForceEarlySettle() public {
        uint256 task = _open(gov, address(0xC0DE), 3, 2, WINDOW);
        _submit(gov, task, ops[0], 1, 8000, keccak256("h0"));
        _submit(gov, task, ops[1], 2, 2000, keccak256("g1"));
        _submit(gov, task, ops[2], 2, 2000, keccak256("g2"));

        // count==n but pre-deadline -> reverts. The griefer cannot lock in the NO early.
        assertLt(block.timestamp, gov.getThought(task).deadline, "pre-deadline");
        vm.expectRevert(
            abi.encodeWithSelector(IThinkingGovernor.SettleTooEarly.selector, task, gov.getThought(task).deadline)
        );
        gov.settle(task);
    }

    // ==================================================================
    // B — short-window starvation — MITIGATED (MIN_VOTING_WINDOW = 1h)
    // ==================================================================

    /// @notice MITIGATED (B1): the window floor is now 1 hour (was 60s). An opener can no
    /// longer pick a sub-minute window to starve a global committee. The floor is enforced;
    /// a 60s window reverts BadVotingWindow.
    function test_B1_MITIGATED_MinWindowRaisedToOneHour() public {
        assertEq(gov.MIN_VOTING_WINDOW(), 1 hours, "min window raised to 1h");

        // The old 60s starvation window is now rejected outright.
        vm.deal(address(0xC0DE), 100 ether);
        vm.prank(address(0xC0DE));
        vm.expectRevert(abi.encodeWithSelector(IThinkingGovernor.BadVotingWindow.selector, uint64(60)));
        gov.openThought{value: REWARD + OPEN_FEE}(MODEL_SPEC, PROMPT_HASH, TASK_EVIDENCE, 3, 2, 60, KNOB_KEY);
    }

    /// @notice B2 (OK): a small validator timestamp warp cannot open a 1h gate early.
    function test_B2_OK_SmallTimestampWarpCannotOpenTheGate() public {
        uint256 task = _open(gov, address(0xC0DE), 5, 3, WINDOW);
        _submit(gov, task, ops[0], 1, 8000, keccak256("t0"));
        vm.warp(block.timestamp + 12);
        vm.expectRevert(
            abi.encodeWithSelector(IThinkingGovernor.SettleTooEarly.selector, task, gov.getThought(task).deadline)
        );
        gov.settle(task);
    }

    // ==================================================================
    // A — verdictDigest operator binding (defenses RED confirmed hold)
    // ==================================================================

    /// @notice A1 (OK): you can only submit a verdict YOU signed. ops1 cannot replay ops0's
    /// signed bytes (contract recomputes the digest with operator=ops1 -> mismatch).
    function test_A1_OK_OperatorBindingPreventsCrossOperatorSubmit() public {
        uint256 task = _open(gov, address(0xC0DE), 3, 2, WINDOW);
        bytes32 ev = keccak256("shared");
        bytes memory sig0 = _sig(gov, task, ops[0], MODEL_SPEC, 1, 8000, ev);

        vm.prank(ops[1].addr);
        vm.expectRevert(); // SignerMismatch
        gov.submitVerdict(task, 1, 8000, ev, sig0);

        vm.prank(ops[0].addr);
        gov.submitVerdict(task, 1, 8000, ev, sig0);
        assertEq(uint8(gov.getVerdict(task, ops[0].addr).vote), 1, "OK: only the signer can submit its verdict");
    }

    /// @notice A2 (OK): per-operator digests differ; no single signature serves two operators.
    function test_A2_OK_NoSharedSignatureAcrossOperators() public view {
        uint256 task = 3;
        bytes32 ev = keccak256("x");
        bytes32 d0 = gov.verdictDigest(task, ops[0].addr, MODEL_SPEC, 1, 8000, ev);
        bytes32 d1 = gov.verdictDigest(task, ops[1].addr, MODEL_SPEC, 1, 8000, ev);
        assertTrue(d0 != d1, "OK: per-operator digests differ");
    }

    /// @notice A3 (OK): high-S malleable counterpart is rejected by OZ ECDSA.
    function test_A3_OK_HighSMalleableSignatureRejected() public {
        uint256 task = _open(gov, address(0xC0DE), 3, 2, WINDOW);
        bytes32 ev = keccak256("m");
        bytes32 digest = gov.verdictDigest(task, ops[0].addr, MODEL_SPEC, 1, 8000, ev);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ops[0].pk, digest);
        uint256 N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes32 sHigh = bytes32(N - uint256(s));
        uint8 vFlip = v == 27 ? 28 : 27;
        bytes memory malleable = abi.encodePacked(r, sHigh, vFlip);
        vm.prank(ops[0].addr);
        vm.expectRevert(); // ECDSAInvalidSignatureS
        gov.submitVerdict(task, 1, 8000, ev, malleable);
    }

    /// @notice A4 (OK): an off-grid bucket is rejected even with a valid signature over it.
    function test_A4_OK_AllSubmitFieldsAreBoundOrValidated() public {
        uint256 task = _open(gov, address(0xC0DE), 3, 2, WINDOW);
        bytes32 ev = keccak256("g");
        bytes memory sig = _sig(gov, task, ops[0], MODEL_SPEC, 1, 8500, ev);
        vm.prank(ops[0].addr);
        vm.expectRevert(abi.encodeWithSelector(IThinkingGovernor.BadConfidenceBucket.selector, uint16(8500)));
        gov.submitVerdict(task, 1, 8500, ev, sig);
    }

    // ==================================================================
    // F — settle re-entrancy / claim CEI (defenses RED confirmed hold)
    // ==================================================================

    /// @notice F1 (OK): claimReward is nonReentrant + zeroes before the call (CEI). Exactly
    /// one reward leaves the contract per claim.
    function test_F1_OK_ClaimRewardCEIAndGuard() public {
        uint256 task = _open(gov, address(0xC0DE), 3, 2, WINDOW);
        _submit(gov, task, ops[0], 1, 8000, keccak256("r0"));
        _submit(gov, task, ops[1], 1, 8000, keccak256("r1"));
        _submit(gov, task, ops[2], 1, 8000, keccak256("r2"));
        _close(gov, task);
        gov.settle(task);

        uint256 reward = gov.rewardOf(ops[0].addr);
        assertGt(reward, 0, "ops0 has reward");
        uint256 govBalBefore = address(gov).balance;
        vm.prank(ops[0].addr);
        gov.claimReward();
        assertEq(address(gov).balance, govBalBefore - reward, "OK: exactly one reward paid");
        assertEq(gov.rewardOf(ops[0].addr), 0, "OK: reward zeroed (CEI)");
    }
}
