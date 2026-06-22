// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.31;

import "forge-std/Test.sol";

import {ThinkingGovernor} from "../contracts/deployables/thinking/ThinkingGovernor.sol";
import {IThinkingGovernor} from "../contracts/deployables/thinking/interfaces/IThinkingGovernor.sol";
import {KeyValuePairsV1} from "../contracts/singletons/KeyValuePairsV1.sol";

/// @title ThinkingGovernorRed3 — round-3 FINAL re-review PoCs (post round-2 fixes).
/// @notice RED-2 found C1/E1/E4/B1/D2; Blue fixed all four. RED-3 verifies each fix is
/// real AND hunts for regressions introduced BY those fixes. The headline finding:
///
///   R1 [HIGH, NEW REGRESSION]: the C1 fix dropped `op.bond != 0` from _eligible. With
///   a minBond==0 deployment (an accepted, unguarded config), _eligible(neverRegistered)
///   is now TRUE — ANY address can submit a verdict WITHOUT registerOperator and
///   WITHOUT bonding. Pre-fix, the `op.bond != 0` clause blocked exactly this. The
///   committee is no longer gated to registered operators under minBond==0.
///
/// The remaining tests confirm the four fixes hold and probe the other regression
/// surfaces (always-deadline liveness, D2 bypass, uint64 deadline overflow).
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
        pure
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

    // ==================================================================
    // R1 [HIGH, NEW REGRESSION] — minBond==0 makes EVERYONE an operator
    // ==================================================================

    /// @notice FIXED (R1): the regression is closed two ways. (1) minBond==0 is now
    /// rejected at construction (a zero-bond registry is meaningless). (2) Defense in
    /// depth: _bonded now requires `bond != 0` (composed into _eligible), so even if
    /// the floor were ever 0, an unregistered/unbonded address is neither eligible to
    /// submit nor counted at settle. This test proves the minBond==0 deploy reverts.
    function test_R1_FIXED_MinBondZeroDeployRejected() public {
        vm.expectRevert(bytes("minBond must be > 0"));
        new ThinkingGovernor(0, COOLDOWN, REWARD, OPEN_FEE, TREASURY, address(kvp));
    }

    /// @notice FIXED (R1) defense-in-depth: the non-zero floor lives in _bonded, so an
    /// unregistered/unbonded address is rejected at submit AND would be dropped at
    /// settle — independent of the minBond value. Demonstrated on a normal minBond>0
    /// deploy: a phantom (never-registered, zero-bond) address is NOT an operator and
    /// its submission reverts NotBonded.
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

    /// @notice Control: with minBond > 0 (every real deployment in the test-suite),
    /// the SAME phantom-voter attack is correctly rejected — the regression is scoped
    /// to the minBond==0 config. This isolates the bug to the removed `op.bond != 0`.
    function test_R1b_Control_MinBondNonZero_UnregisteredRejected() public {
        ThinkingGovernor g = new ThinkingGovernor(1 ether, COOLDOWN, REWARD, OPEN_FEE, TREASURY, address(kvp));
        Op memory p0 = _op(11);
        assertFalse(g.isOperator(p0.addr), "minBond>0: unregistered is NOT an operator");

        address opener = _op(98).addr;
        vm.prank(opener);
        uint256 task = g.openThought{value: REWARD + OPEN_FEE}(
            MODEL_SPEC, PROMPT_HASH, TASK_EVIDENCE, 3, 2, WINDOW, KNOB_KEY
        );
        bytes memory sig = _sig(g, task, p0, 1, 8000, keccak256("p0"));
        vm.prank(p0.addr);
        vm.expectRevert(abi.encodeWithSelector(IThinkingGovernor.NotBonded.selector, p0.addr));
        g.submitVerdict(task, 1, 8000, keccak256("p0"), sig);
    }

    // ==================================================================
    // E1/E4 regression probe — always-deadline cannot brick settle
    // ==================================================================

    /// @notice The E1/E4 fix makes settle ALWAYS wait for the deadline. Confirm the
    /// far-future deadline (MAX_VOTING_WINDOW = 30d) does NOT brick settle: it just
    /// delays it, and there is no uint64 overflow in deadline = openedAt + window.
    function test_E_NoBrick_MaxWindowSettlesAfter30d() public {
        ThinkingGovernor g = new ThinkingGovernor(1 ether, COOLDOWN, REWARD, OPEN_FEE, TREASURY, address(kvp));
        Op memory a = _op(21);
        Op memory b = _op(22);
        Op memory c = _op(23);
        for (uint256 i; i < 3; ++i) {
            Op memory o = _op(20 + i + 1);
            vm.prank(o.addr);
            g.registerOperator{value: 1 ether}();
        }
        address opener = _op(97).addr;
        uint64 maxW = g.MAX_VOTING_WINDOW();
        vm.prank(opener);
        uint256 task = g.openThought{value: REWARD + OPEN_FEE}(
            MODEL_SPEC, PROMPT_HASH, TASK_EVIDENCE, 3, 2, maxW, KNOB_KEY
        );
        _submit(g, task, a, 1, 8000, keccak256("a"));
        _submit(g, task, b, 1, 8000, keccak256("b"));
        _submit(g, task, c, 1, 8000, keccak256("c"));

        // Pre-deadline: even a full committee waits.
        vm.expectRevert(
            abi.encodeWithSelector(IThinkingGovernor.SettleTooEarly.selector, task, g.getThought(task).deadline)
        );
        g.settle(task);

        // After 30 days, settles cleanly. No overflow, no brick.
        vm.warp(g.getThought(task).deadline + 1);
        g.settle(task);
        (bool settled,,, uint8 agree) = g.getCanonicalVerdict(task);
        assertTrue(settled, "settles after the max window - not bricked");
        assertEq(agree, 3);
    }

    /// @notice deadline = openedAt + votingWindow is uint64+uint64. votingWindow is
    /// capped at 30d, openedAt is block.timestamp. Show no realistic overflow: even at
    /// year ~292e9 (uint64 max seconds) the sum is bounded; here we just assert the
    /// stored deadline equals openedAt+window with a large but legal timestamp.
    function test_E_DeadlineNoOverflow_LargeTimestamp() public {
        ThinkingGovernor g = new ThinkingGovernor(1 ether, COOLDOWN, REWARD, OPEN_FEE, TREASURY, address(kvp));
        Op memory o = _op(31);
        vm.prank(o.addr);
        g.registerOperator{value: 1 ether}();
        address opener = _op(96).addr;

        vm.warp(4_000_000_000); // year ~2096, well within uint64
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

    /// @notice D2 adds `if (msg.sender == _treasury) revert OpenerIsTreasury`. Probe
    /// the degenerate treasury==address(0) (legal when openFee==0): msg.sender can
    /// never be address(0) in a real tx, so the guard does NOT block legitimate
    /// openers. A normal opener succeeds; the no-treasury/no-fee config still works.
    function test_D2_NoFalsePositive_ZeroTreasuryWhenNoFee() public {
        // treasury==0 requires openFee==0 (constructor). Open payment is then just REWARD.
        ThinkingGovernor g = new ThinkingGovernor(1 ether, COOLDOWN, REWARD, 0, address(0), address(kvp));
        address opener = _op(41).addr;
        vm.prank(opener);
        uint256 task = g.openThought{value: REWARD}(MODEL_SPEC, PROMPT_HASH, TASK_EVIDENCE, 3, 2, WINDOW, KNOB_KEY);
        assertEq(uint8(g.getThought(task).status), uint8(IThinkingGovernor.Status.Open), "opener != address(0) ok");
        // No fee accrued anywhere (openFee==0).
        assertEq(g.rewardOf(address(0)), 0, "no fee to the zero treasury");
    }

    /// @notice D2 does NOT break the legitimate case where the treasury is a normal
    /// operator that wants to open a DIFFERENT task. The treasury is blocked from
    /// opening (by design), but a NON-treasury operator opens freely while the
    /// treasury still accrues the fee. (Confirms the guard is on msg.sender==treasury
    /// only, not on the treasury existing.)
    function test_D2_TreasuryCanStillBeAnOperatorAndOthersOpen() public {
        address tre = _op(51).addr;
        ThinkingGovernor g = new ThinkingGovernor(1 ether, COOLDOWN, REWARD, OPEN_FEE, tre, address(kvp));
        // treasury registers as an operator and can VOTE; it just can't OPEN.
        vm.prank(tre);
        g.registerOperator{value: 1 ether}();
        assertTrue(g.isOperator(tre), "treasury is a valid operator");

        // The treasury cannot open.
        vm.prank(tre);
        vm.expectRevert(abi.encodeWithSelector(IThinkingGovernor.OpenerIsTreasury.selector, tre));
        g.openThought{value: REWARD + OPEN_FEE}(MODEL_SPEC, PROMPT_HASH, TASK_EVIDENCE, 3, 2, WINDOW, KNOB_KEY);

        // A different opener opens; treasury accrues the fee and can vote on it.
        address opener = _op(52).addr;
        vm.prank(opener);
        uint256 task = g.openThought{value: REWARD + OPEN_FEE}(
            MODEL_SPEC, PROMPT_HASH, TASK_EVIDENCE, 3, 2, WINDOW, KNOB_KEY
        );
        assertEq(g.rewardOf(tre), OPEN_FEE, "treasury accrued the fee");
        _submit(g, task, _opReg(g, 53), 1, 8000, keccak256("v0")); // a fresh registered voter
        // treasury votes too (it is an eligible operator and not the opener).
        _submit(g, task, Op({pk: 0xBEEF00 + 51, addr: tre}), 1, 8000, keccak256("vt"));
    }

    function _opReg(ThinkingGovernor g, uint256 seed) internal returns (Op memory o) {
        o = _op(seed);
        vm.prank(o.addr);
        g.registerOperator{value: 1 ether}();
    }

    // ==================================================================
    // Economic residual — bare-majority self-suppression via withdraw
    // ==================================================================

    /// @notice Residual (ACKNOWLEDGED, not a regression): under the C1 fix a voter can
    /// still suppress a BARE-majority decision it voted for by FULLY WITHDRAWING its
    /// bond before settle (zero-skin drop). This requires cooldown to have elapsed (or
    /// cooldown==0). It can only collapse Settled->Failed, never flip the winner. Here:
    /// cooldown==0, threshold==2 of n==3, exactly 2 YES; one YES voter withdraws ->
    /// 1 YES < 2 -> Failed. The cost is forfeiting the reward + re-bonding to return.
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

        // b regrets, fully exits before settle (cooldown==0) -> its YES is dropped.
        vm.prank(b.addr);
        g.deregister();
        vm.prank(b.addr);
        g.withdrawBond();

        vm.warp(g.getThought(task).deadline + 1);
        g.settle(task);
        (bool settled,,, uint8 agree) = g.getCanonicalVerdict(task);
        assertFalse(settled, "RESIDUAL: bare-majority decision suppressed by self-withdrawal");
        assertEq(agree, 0, "the withdrawn voter's YES dropped, quorum collapsed");
        // Cost to the suppressor: it forfeits the reward and must re-bond to return.
        assertEq(g.rewardOf(b.addr), 0, "suppressor earns no reward");
        assertEq(g.bondOf(b.addr), 0, "suppressor exited (must re-bond 1 ether to return)");
    }
}
