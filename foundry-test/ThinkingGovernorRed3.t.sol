// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.31;

import "forge-std/Test.sol";

import {ThinkingGovernor} from "../contracts/deployables/thinking/ThinkingGovernor.sol";
import {IThinkingGovernor} from "../contracts/deployables/thinking/interfaces/IThinkingGovernor.sol";
import {KeyValuePairsV1} from "../contracts/singletons/KeyValuePairsV1.sol";

/// @title ThinkingGovernorRed3 — round-3 FINAL re-review PoCs (post round-2 fixes).
/// @notice RED-3 found R1 [HIGH]: the C1 fix had dropped `op.bond != 0` from _eligible,
/// so a minBond==0 deployment let unregistered/unbonded addresses vote. Blue fixed it
/// two ways: (1) constructor require(minBond_ > 0); (2) the non-zero floor now lives in
/// _bonded, composed into _eligible. These tests confirm the fix and re-probe the other
/// round-2 fixes' regression surfaces (always-deadline liveness, D2, uint64 overflow).
contract ThinkingGovernorRed3Test is Test {
    KeyValuePairsV1 internal kvp;

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

    function setUp() public {
        kvp = new KeyValuePairsV1();
    }

    function _sig(ThinkingGovernor g, uint256 taskId, Op memory o, uint8 vote, uint16 bucket, bytes32 ev)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest = g.verdictDigest(taskId, o.addr, MODEL_SPEC, vote, bucket, ev);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(o.pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _submit(ThinkingGovernor g, uint256 taskId, Op memory o, uint8 vote, uint16 bucket, bytes32 ev) internal {
        bytes memory sig = _sig(g, taskId, o, vote, bucket, ev);
        vm.prank(o.addr);
        g.submitVerdict(taskId, vote, bucket, ev, sig);
    }

    function _op(uint256 seed) internal returns (Op memory o) {
        uint256 pk = 0xBEEF00 + seed;
        o = Op({pk: pk, addr: vm.addr(pk)});
        vm.deal(o.addr, 100 ether);
    }

    function _opReg(ThinkingGovernor g, uint256 seed) internal returns (Op memory o) {
        o = _op(seed);
        vm.prank(o.addr);
        g.registerOperator{value: 1 ether}();
    }

    // ==================================================================
    // R1 [HIGH] — minBond==0 makes EVERYONE an operator — FIXED
    // ==================================================================

    /// @notice FIXED (R1): minBond==0 is now rejected at construction (a zero-bond
    /// registry is meaningless — registerOperator with value:0 would leave bond==0
    /// indistinguishable from unregistered).
    function test_R1_FIXED_MinBondZeroDeployRejected() public {
        vm.expectRevert(bytes("minBond must be > 0"));
        new ThinkingGovernor(0, COOLDOWN, REWARD, OPEN_FEE, TREASURY, address(kvp));
    }

    /// @notice FIXED (R1) defense-in-depth: the non-zero floor lives in _bonded
    /// (composed into _eligible), so an unregistered/unbonded address is neither
    /// eligible to submit nor counted at settle — independent of the minBond value.
    function test_R1_FIXED_UnbondedNeverCountsRegardlessOfFloor() public {
        ThinkingGovernor g = new ThinkingGovernor(1 ether, COOLDOWN, REWARD, OPEN_FEE, TREASURY, address(kvp));
        Op memory phantom = _op(1);
        assertEq(g.bondOf(phantom.addr), 0, "phantom never bonded");
        assertFalse(g.isOperator(phantom.addr), "FIXED: unregistered address is NOT an operator");

        address opener = _op(99).addr;
        vm.prank(opener);
        uint256 task = g.openThought{value: REWARD + OPEN_FEE}(
            MODEL_SPEC, PROMPT_HASH, TASK_EVIDENCE, 3, 2, WINDOW, KNOB_KEY
        );
        bytes memory sig = _sig(g, task, phantom, 1, 8000, keccak256("p"));
        vm.prank(phantom.addr);
        vm.expectRevert(abi.encodeWithSelector(IThinkingGovernor.NotBonded.selector, phantom.addr));
        g.submitVerdict(task, 1, 8000, keccak256("p"), sig);
    }

    // ==================================================================
    // E1/E4 regression probe — always-deadline cannot brick settle
    // ==================================================================

    /// @notice The always-deadline gate does NOT brick settle: a far-future deadline
    /// (MAX_VOTING_WINDOW = 30d) just delays it, and there is no uint64 overflow.
    function test_E_NoBrick_MaxWindowSettlesAfter30d() public {
        ThinkingGovernor g = new ThinkingGovernor(1 ether, COOLDOWN, REWARD, OPEN_FEE, TREASURY, address(kvp));
        Op memory a = _opReg(g, 21);
        Op memory b = _opReg(g, 22);
        Op memory c = _opReg(g, 23);
        address opener = _op(97).addr;
        uint64 maxW = g.MAX_VOTING_WINDOW();
        vm.prank(opener);
        uint256 task = g.openThought{value: REWARD + OPEN_FEE}(
            MODEL_SPEC, PROMPT_HASH, TASK_EVIDENCE, 3, 2, maxW, KNOB_KEY
        );
        _submit(g, task, a, 1, 8000, keccak256("a"));
        _submit(g, task, b, 1, 8000, keccak256("b"));
        _submit(g, task, c, 1, 8000, keccak256("c"));

        vm.expectRevert(
            abi.encodeWithSelector(IThinkingGovernor.SettleTooEarly.selector, task, g.getThought(task).deadline)
        );
        g.settle(task);

        vm.warp(g.getThought(task).deadline + 1);
        g.settle(task);
        (bool settled,,, uint8 agree) = g.getCanonicalVerdict(task);
        assertTrue(settled, "settles after the max window - not bricked");
        assertEq(agree, 3);
    }

    /// @notice deadline = openedAt + votingWindow is uint64+uint64, window capped at
    /// 30d; no realistic overflow at a large but legal timestamp.
    function test_E_DeadlineNoOverflow_LargeTimestamp() public {
        ThinkingGovernor g = new ThinkingGovernor(1 ether, COOLDOWN, REWARD, OPEN_FEE, TREASURY, address(kvp));
        _opReg(g, 31);
        address opener = _op(96).addr;

        vm.warp(4_000_000_000); // year ~2096, within uint64
        vm.prank(opener);
        uint256 task = g.openThought{value: REWARD + OPEN_FEE}(
            MODEL_SPEC, PROMPT_HASH, TASK_EVIDENCE, 1, 1, WINDOW, KNOB_KEY
        );
        IThinkingGovernor.Thought memory t = g.getThought(task);
        assertEq(t.deadline, t.openedAt + WINDOW, "deadline = openedAt + window, no overflow");
        assertEq(t.openedAt, 4_000_000_000, "openedAt is the warped timestamp");
    }

    // ==================================================================
    // D2 regression probe — treasury==address(0) when openFee==0
    // ==================================================================

    /// @notice D2's `msg.sender == _treasury` guard does NOT false-positive on the
    /// degenerate treasury==address(0) (legal when openFee==0): msg.sender is never
    /// address(0) in a real tx, so a normal opener succeeds.
    function test_D2_NoFalsePositive_ZeroTreasuryWhenNoFee() public {
        ThinkingGovernor g = new ThinkingGovernor(1 ether, COOLDOWN, REWARD, 0, address(0), address(kvp));
        address opener = _op(41).addr;
        vm.prank(opener);
        uint256 task = g.openThought{value: REWARD}(MODEL_SPEC, PROMPT_HASH, TASK_EVIDENCE, 3, 2, WINDOW, KNOB_KEY);
        assertEq(uint8(g.getThought(task).status), uint8(IThinkingGovernor.Status.Open), "opener != address(0) ok");
        assertEq(g.rewardOf(address(0)), 0, "no fee to the zero treasury");
    }

    /// @notice D2 does NOT break the legitimate case where the treasury is a normal
    /// operator: it is blocked from OPENING but can still register and VOTE; a
    /// non-treasury opener opens freely while the treasury accrues the fee.
    function test_D2_TreasuryCanStillBeAnOperatorAndOthersOpen() public {
        address tre = _op(51).addr;
        ThinkingGovernor g = new ThinkingGovernor(1 ether, COOLDOWN, REWARD, OPEN_FEE, tre, address(kvp));
        vm.prank(tre);
        g.registerOperator{value: 1 ether}();
        assertTrue(g.isOperator(tre), "treasury is a valid operator");

        vm.prank(tre);
        vm.expectRevert(abi.encodeWithSelector(IThinkingGovernor.OpenerIsTreasury.selector, tre));
        g.openThought{value: REWARD + OPEN_FEE}(MODEL_SPEC, PROMPT_HASH, TASK_EVIDENCE, 3, 2, WINDOW, KNOB_KEY);

        address opener = _op(52).addr;
        vm.prank(opener);
        uint256 task = g.openThought{value: REWARD + OPEN_FEE}(
            MODEL_SPEC, PROMPT_HASH, TASK_EVIDENCE, 3, 2, WINDOW, KNOB_KEY
        );
        assertEq(g.rewardOf(tre), OPEN_FEE, "treasury accrued the fee");
        _submit(g, task, _opReg(g, 53), 1, 8000, keccak256("v0"));
        _submit(g, task, Op({pk: 0xBEEF00 + 51, addr: tre}), 1, 8000, keccak256("vt"));
    }

    // ==================================================================
    // Economic residual — bare-majority self-suppression via withdraw
    // ==================================================================

    /// @notice Residual (ACKNOWLEDGED, not a regression): under the C1 fix a voter can
    /// still suppress a BARE-majority decision it voted for by FULLY WITHDRAWING its
    /// bond before settle (zero-skin drop, requires cooldown elapsed / cooldown==0). It
    /// can only collapse Settled->Failed, never flip the winner. Cost: forfeit reward +
    /// re-bond to return.
    function test_RES_BareMajoritySelfSuppressViaWithdraw() public {
        ThinkingGovernor g = new ThinkingGovernor(1 ether, 0, REWARD, OPEN_FEE, TREASURY, address(kvp));
        Op memory a = _opReg(g, 61);
        Op memory b = _opReg(g, 62);
        address opener = _op(95).addr;
        vm.prank(opener);
        uint256 task = g.openThought{value: REWARD + OPEN_FEE}(
            MODEL_SPEC, PROMPT_HASH, TASK_EVIDENCE, 3, 2, WINDOW, KNOB_KEY
        );
        _submit(g, task, a, 1, 8000, keccak256("a"));
        _submit(g, task, b, 1, 8000, keccak256("b")); // bare 2/3 majority formed

        vm.prank(b.addr);
        g.deregister();
        vm.prank(b.addr);
        g.withdrawBond();

        vm.warp(g.getThought(task).deadline + 1);
        g.settle(task);
        (bool settled,,, uint8 agree) = g.getCanonicalVerdict(task);
        assertFalse(settled, "RESIDUAL: bare-majority decision suppressed by self-withdrawal");
        assertEq(agree, 0, "the withdrawn voter's YES dropped, quorum collapsed");
        assertEq(g.rewardOf(b.addr), 0, "suppressor earns no reward");
        assertEq(g.bondOf(b.addr), 0, "suppressor exited (must re-bond 1 ether to return)");
    }
}
