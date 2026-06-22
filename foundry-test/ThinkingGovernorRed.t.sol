// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.31;

import "forge-std/Test.sol";

import {ThinkingGovernor} from "../contracts/deployables/thinking/ThinkingGovernor.sol";
import {ThinkingGate} from "../contracts/deployables/thinking/ThinkingGate.sol";
import {IThinkingGovernor} from "../contracts/deployables/thinking/interfaces/IThinkingGovernor.sol";
import {KeyValuePairsV1} from "../contracts/singletons/KeyValuePairsV1.sol";
import {IKeyValuePairsV1} from "../contracts/interfaces/dao/singletons/IKeyValuePairsV1.sol";

/// @title ThinkingGovernorRed — adversarial PoCs (RED TEAM, re-review after BLUE hardening)
/// @notice Each test either DEMONSTRATES that an attack is now CONTAINED by a BLUE
/// defense (named *_CONTAINED_*) or measures a worst-case bound (gas DoS). The
/// vulnerable design these PoCs originally targeted has been hardened:
///
///   * Option B verdict digest — the operator signs a DOMAIN-SEPARATED digest that
///     BINDS (taskId, operator, modelSpecHash, vote, confidenceBucket, evidenceHash).
///     The old free-floating consensusHash signature (spec+vote+bucket only) is gone,
///     so verdicts are non-transferable across tasks and evidence is authenticated.
///   * Spec-scoped knobs — getKnob(modelSpecHash, key); a decision under one spec can
///     NEVER overwrite a knob a consumer reads under another spec.
///   * Liveness gate — settle() is blocked until the window closes OR all n slots
///     fill, killing empty/premature/front-run grief.
///   * Settle-time eligibility — a verdict from an operator that exited after voting
///     is DROPPED, so a zero-skin address cannot tip the quorum.
///   * Non-refundable open fee — forging an on-chain quorum always costs real value
///     (the fee leaves the opener permanently, accruing to the treasury).
///
/// Run: forge test --match-contract ThinkingGovernorRed -vvv
contract ThinkingGovernorRedTest is Test {
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

    Op[64] internal ops;

    function setUp() public {
        kvp = new KeyValuePairsV1();
        gov = new ThinkingGovernor(MIN_BOND, COOLDOWN, REWARD, OPEN_FEE, TREASURY, address(kvp));
        for (uint256 i; i < 64; ++i) {
            uint256 pk = 0xA11CE + i + 1;
            address a = vm.addr(pk);
            ops[i] = Op({pk: pk, addr: a});
            vm.deal(a, 100 ether);
            vm.prank(a);
            gov.registerOperator{value: MIN_BOND}();
        }
    }

    // ======================================================================
    // helpers (Option B — sign the domain-separated verdict digest)
    // ======================================================================

    /// @dev GENUINE signature over the DOMAIN-SEPARATED verdict digest on `gov`,
    /// binding (taskId, operator, MODEL_SPEC, vote, bucket, evidence). The evidence
    /// passed here MUST be the SAME evidence later handed to submitVerdict, or the
    /// recovered signer differs and the contract rejects with SignerMismatch.
    function _signVerdict(uint256 taskId, address operator, uint256 pk, uint8 vote, uint16 bucket, bytes32 evidence)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest = gov.verdictDigest(taskId, operator, MODEL_SPEC, vote, bucket, evidence);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Same, but bound to an EXPLICIT spec (for the spec-isolation PoCs where the
    /// attacker opens under a different modelSpecHash).
    function _signVerdictSpec(
        uint256 taskId,
        address operator,
        uint256 pk,
        bytes32 spec,
        uint8 vote,
        uint16 bucket,
        bytes32 evidence
    ) internal view returns (bytes memory) {
        bytes32 digest = gov.verdictDigest(taskId, operator, spec, vote, bucket, evidence);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Deterministic evidence hash for operator index `i` on a task.
    function _ev(uint256 taskId, uint256 i) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("ev", taskId, i));
    }

    /// @dev Sign + submit a coherent verdict for operator `i` (default spec/evidence).
    function _submit(uint256 taskId, uint256 i, uint8 vote, uint16 bucket) internal {
        bytes32 ev = _ev(taskId, i);
        bytes memory sig = _signVerdict(taskId, ops[i].addr, ops[i].pk, vote, bucket, ev);
        vm.prank(ops[i].addr);
        gov.submitVerdict(taskId, vote, bucket, ev, sig);
    }

    /// @dev Sign + submit on an ARBITRARY governor instance `g` (multi-instance PoCs).
    function _submitOn(ThinkingGovernor g, uint256 taskId, Op memory o, uint8 vote, uint16 bucket, bytes32 ev)
        internal
    {
        bytes32 digest = g.verdictDigest(taskId, o.addr, MODEL_SPEC, vote, bucket, ev);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(o.pk, digest);
        vm.prank(o.addr);
        g.submitVerdict(taskId, vote, bucket, ev, abi.encodePacked(r, s, v));
    }

    function _open(address opener, bytes32 spec, uint8 n, uint8 threshold, string memory key)
        internal
        returns (uint256 taskId)
    {
        vm.deal(opener, 10 ether);
        vm.prank(opener);
        taskId = gov.openThought{value: REWARD + OPEN_FEE}(spec, PROMPT_HASH, TASK_EVIDENCE, n, threshold, WINDOW, key);
    }

    function _closeWindow(uint256 taskId) internal {
        vm.warp(gov.getThought(taskId).deadline + 1);
    }

    function _closeWindowOn(ThinkingGovernor g, uint256 taskId) internal {
        vm.warp(g.getThought(taskId).deadline + 1);
    }

    // ====================================================================
    // VECTOR 6 — CROSS-SPEC KNOB HIJACK (BLUE fix: knobs are spec-scoped)
    // ====================================================================

    /// @notice ATTACK ATTEMPT: an attacker who is NOT the original opener tries to
    /// overwrite a governed knob by opening a SECOND task that re-uses the same
    /// knobKey under a DIFFERENT modelSpecHash and driving a quorum.
    /// CONTAINED: getKnob(spec, key) is spec-scoped — the consumer reads under its OWN
    /// spec, so the attacker's decision lands in a disjoint (attackerSpec, key) slot
    /// and is invisible to the consumer. The legit value is NOT clobbered.
    function test_KnobHijack_CONTAINED_SpecScopedNoCrossWrite() public {
        // --- Legit decision: task A under MODEL_SPEC sets the consumer's knob.
        uint256 taskA = _open(address(0xA11CE), MODEL_SPEC, 5, 3, KNOB_KEY);
        for (uint256 i; i < 3; ++i) _submit(taskA, i, 1, 8000);
        _closeWindow(taskA);
        gov.settle(taskA);
        bytes32 legitKnob = bytes32((uint256(3) << 24) | (uint256(8000) << 8) | uint256(1));
        assertEq(gov.getKnob(MODEL_SPEC, KNOB_KEY), legitKnob, "legit knob set by task A under its spec");

        // --- Attacker opens task B with a TOTALLY DIFFERENT spec, SAME knobKey,
        //     drives YES@1000 with agree=3, and tries to overwrite the consumer's knob.
        bytes32 attackerSpec = keccak256("attacker/evil-spec");
        address attacker = address(0xBADBAD);
        uint256 taskB = _open(attacker, attackerSpec, 5, 3, KNOB_KEY);
        for (uint256 i = 3; i < 6; ++i) {
            bytes32 ev = keccak256(abi.encodePacked("b", i));
            bytes memory sig = _signVerdictSpec(taskB, ops[i].addr, ops[i].pk, attackerSpec, 1, 1000, ev);
            vm.prank(ops[i].addr);
            gov.submitVerdict(taskB, 1, 1000, ev, sig);
        }
        _closeWindow(taskB);
        gov.settle(taskB);

        // CONTAINED: the consumer's knob (read under MODEL_SPEC) is UNCHANGED.
        assertEq(gov.getKnob(MODEL_SPEC, KNOB_KEY), legitKnob, "CONTAINED: consumer knob NOT hijacked");
        // The attacker's decision is isolated to its own spec namespace.
        bytes32 attackerKnob = bytes32((uint256(3) << 24) | (uint256(1000) << 8) | uint256(1));
        assertEq(gov.getKnob(attackerSpec, KNOB_KEY), attackerKnob, "attacker knob isolated to its spec");
    }

    /// @notice ATTACK ATTEMPT: arbitrary spec writes the victim's key.
    /// CONTAINED: there IS an on-chain link from a knob to its spec (the slot is
    /// keccak(spec,key)), so a decision under an unrelated spec writes a DIFFERENT
    /// slot. The victim's (MODEL_SPEC, key) slot stays zero.
    function test_KnobHijack_CONTAINED_SpecBindingOnKnob() public {
        bytes32 attackerSpec = keccak256("unrelated");
        uint256 task = _open(address(0xBEEF), attackerSpec, 3, 2, KNOB_KEY);
        for (uint256 i; i < 2; ++i) {
            bytes32 ev = keccak256(abi.encodePacked("k", i));
            bytes memory sig = _signVerdictSpec(task, ops[i].addr, ops[i].pk, attackerSpec, 1, 5000, ev);
            vm.prank(ops[i].addr);
            gov.submitVerdict(task, 1, 5000, ev, sig);
        }
        _closeWindow(task);
        gov.settle(task);
        // The attacker's spec wrote its OWN slot...
        assertTrue(gov.getKnob(attackerSpec, KNOB_KEY) != bytes32(0), "attacker wrote its own spec slot");
        // ...but the victim, reading under MODEL_SPEC, sees nothing.
        assertEq(gov.getKnob(MODEL_SPEC, KNOB_KEY), bytes32(0), "CONTAINED: victim's spec slot untouched");
    }

    // ====================================================================
    // VECTOR 4 — SYBIL SELF-DEAL (BLUE fix: non-refundable open fee)
    // ====================================================================

    /// @notice ATTACK ATTEMPT: one actor controls the opener AND the committee, opens
    /// a task, has its own sybil operators agree, and tries to recover the FULL escrow
    /// so forging an on-chain "operator-LLM consensus" decision is free.
    /// CONTAINED: the refundable REWARD can round-trip to the agreeing sybils, but the
    /// NON-REFUNDABLE open fee leaves the opener permanently (accrues to the treasury,
    /// who is NOT the attacker). Forging a quorum therefore always costs OPEN_FEE of
    /// real value — the consolidated attacker side is down exactly the fee.
    function test_SybilSelfDeal_CONTAINED_OpenFeeIsNonRefundable() public {
        address attacker = address(0x5B11);
        uint256 attackerBalBefore = 10 ether; // _open deals exactly 10 ether to the opener
        uint256 task = _open(attacker, MODEL_SPEC, 5, 3, KNOB_KEY);

        uint256 sybilRewardBefore;
        for (uint256 i; i < 3; ++i) sybilRewardBefore += gov.rewardOf(ops[i].addr);

        for (uint256 i; i < 3; ++i) _submit(task, i, 1, 8000);
        _closeWindow(task);
        gov.settle(task);

        uint256 sybilRewardAfter;
        for (uint256 i; i < 3; ++i) sybilRewardAfter += gov.rewardOf(ops[i].addr);

        // The refundable reward escrow round-trips to the sybil committee...
        assertEq(sybilRewardAfter - sybilRewardBefore, REWARD, "reward escrow recovered by sybils (refundable part)");
        // ...but the open fee is GONE from the attacker and credited to the treasury.
        assertEq(gov.rewardOf(TREASURY), OPEN_FEE, "CONTAINED: open fee accrued to treasury, not the attacker");

        // Net cost accounting: attacker spent REWARD+OPEN_FEE to open out of its own
        // balance; the sybil committee reclaims REWARD; the treasury keeps OPEN_FEE.
        // Even crediting EVERY sybil reward back to the attacker, the consolidated
        // attacker side is down exactly OPEN_FEE.
        uint256 attackerControlledAfter = attacker.balance + sybilRewardAfter;
        assertEq(
            attackerBalBefore - attackerControlledAfter,
            OPEN_FEE,
            "CONTAINED: forging an on-chain quorum costs exactly the non-refundable open fee"
        );

        // The forged YES quorum IS recorded — but it was NOT free.
        (bool settled, IThinkingGovernor.Vote vote,,) = gov.getCanonicalVerdict(task);
        assertTrue(settled && vote == IThinkingGovernor.Vote.Yes, "quorum recorded (at the cost of the open fee)");
    }

    // ====================================================================
    // VECTOR 5 — EXITED OPERATOR (BLUE fix: eligibility re-checked at settle)
    // ====================================================================

    /// @notice ATTACK ATTEMPT: with a SHORT cooldown an operator submits, deregisters,
    /// withdraws its ENTIRE bond, and tries to still count toward the canonical quorum.
    /// CONTAINED: settle() re-checks eligibility and DROPS the zero-skin verdict, so
    /// only the still-bonded operator counts -> 1 YES < threshold=2 -> Failed.
    function test_ExitedOperator_CONTAINED_DroppedAtSettle() public {
        // Deploy a governor with cooldown=0 (the contract permits it).
        ThinkingGovernor g2 = new ThinkingGovernor(MIN_BOND, 0, REWARD, OPEN_FEE, TREASURY, address(kvp));
        Op memory o0 = ops[0];
        Op memory o1 = ops[1];
        for (uint256 i; i < 2; ++i) {
            vm.prank(ops[i].addr);
            g2.registerOperator{value: MIN_BOND}();
        }

        vm.deal(address(0xC0DE), 10 ether);
        vm.prank(address(0xC0DE));
        uint256 task =
            g2.openThought{value: REWARD + OPEN_FEE}(MODEL_SPEC, PROMPT_HASH, TASK_EVIDENCE, 3, 2, WINDOW, KNOB_KEY);

        // o0 submits a valid verdict, then fully exits (bond -> 0) before settle.
        bytes32 ev0 = keccak256("x0");
        _submitOn(g2, task, o0, 1, 8000, ev0);
        vm.prank(o0.addr);
        g2.deregister();
        vm.prank(o0.addr);
        g2.withdrawBond(); // cooldown=0 -> immediate full exit
        assertEq(g2.bondOf(o0.addr), 0, "o0 fully exited, zero bond");
        assertFalse(g2.isOperator(o0.addr), "o0 no longer eligible");

        // o1 agrees -> stored verdicts = 2 YES, but only o1 is eligible at settle.
        bytes32 ev1 = keccak256("x1");
        _submitOn(g2, task, o1, 1, 8000, ev1);

        _closeWindowOn(g2, task);
        g2.settle(task);
        (bool settled,,, uint8 agree) = g2.getCanonicalVerdict(task);
        assertFalse(settled, "CONTAINED: exited operator dropped -> 1 eligible YES < 2 -> Failed");
        assertEq(agree, 0, "CONTAINED: exited operator NOT counted in any agreeing group");
    }

    // ====================================================================
    // VECTOR 1 — evidenceHash (BLUE fix: evidence is bound by the signature)
    // ====================================================================

    /// @notice ATTACK ATTEMPT: attach an ARBITRARY evidenceHash to a valid vote so the
    /// on-chain evidenceRoot anchors attacker-chosen bytes rather than real evidence.
    /// CONTAINED: under Option B the signed digest BINDS evidenceHash. A signature
    /// minted for the real evidence does NOT validate for forged evidence (the
    /// recovered signer differs) -> SignerMismatch. The audit root is authenticated.
    function test_EvidenceHash_CONTAINED_BoundBySignature() public {
        uint256 task = _open(address(0xA11CE), MODEL_SPEC, 3, 2, KNOB_KEY);

        // ops[0] signs (yes, 8000) over the REAL evidence.
        bytes32 realEvidence = keccak256("real-llm-evidence");
        bytes memory sig = _signVerdict(task, ops[0].addr, ops[0].pk, 1, 8000, realEvidence);

        // Submitting a DIFFERENT (forged) evidence hash with that signature reverts:
        // the digest over forged evidence recovers a different address than ops[0].
        bytes32 forgedEvidence = keccak256("totally-fabricated-evidence");
        vm.prank(ops[0].addr);
        vm.expectRevert(); // SignerMismatch (recovered signer != ops[0])
        gov.submitVerdict(task, 1, 8000, forgedEvidence, sig);

        // The GENUINE evidence the operator actually signed is accepted verbatim.
        vm.prank(ops[0].addr);
        gov.submitVerdict(task, 1, 8000, realEvidence, sig);
        IThinkingGovernor.Verdict memory rec = gov.getVerdict(task, ops[0].addr);
        assertEq(rec.evidenceHash, realEvidence, "CONTAINED: only the signed evidence is accepted");
        assertEq(uint8(rec.vote), 1, "vote intact");
    }

    // ====================================================================
    // LIVENESS GRIEF — premature/empty/front-run settle (BLUE fix: liveness gate)
    // ====================================================================

    /// @notice ATTACK ATTEMPT: ANY address calls settle() the instant a task opens
    /// (zero verdicts) to force it to Failed before a single operator votes.
    /// CONTAINED: the liveness gate reverts SettleTooEarly until the window closes
    /// (or all n slots fill). The empty task cannot be force-failed.
    function test_PrematureSettle_CONTAINED_EmptyTaskBlocked() public {
        uint256 task = _open(address(0xA11CE), MODEL_SPEC, 5, 3, KNOB_KEY);

        address griefer = address(0x6111E5);
        vm.prank(griefer);
        vm.expectRevert(
            abi.encodeWithSelector(IThinkingGovernor.SettleTooEarly.selector, task, gov.getThought(task).deadline)
        );
        gov.settle(task);

        // The task remains OPEN and operators can still submit.
        assertEq(uint8(gov.getThought(task).status), uint8(IThinkingGovernor.Status.Open), "task still open");
        _submit(task, 0, 1, 8000);
        assertEq(gov.getThought(task).submissionCount, 1, "CONTAINED: operator vote still lands after grief attempt");
    }

    /// @notice ATTACK ATTEMPT: a griefer lets threshold-1 honest votes land, then
    /// settles BEFORE the threshold-th vote to force Failed and suppress the quorum.
    /// CONTAINED: settle is blocked pre-deadline while count<n; by the time the window
    /// closes the honest threshold-th vote has landed and the quorum forms. The
    /// governed decision is NOT suppressed and the knob IS set.
    function test_PrematureSettle_CONTAINED_FrontRunQuorumStillForms() public {
        uint256 task = _open(address(0xA11CE), MODEL_SPEC, 5, 3, KNOB_KEY);

        // 2 honest YES land (threshold is 3).
        _submit(task, 0, 1, 8000);
        _submit(task, 1, 1, 8000);

        // Griefer tries to front-run the 3rd YES with settle() -> blocked (count<n, pre-deadline).
        vm.prank(address(0x6111E5));
        vm.expectRevert(
            abi.encodeWithSelector(IThinkingGovernor.SettleTooEarly.selector, task, gov.getThought(task).deadline)
        );
        gov.settle(task);

        // The 3rd honest vote lands while the task is still open.
        _submit(task, 2, 1, 8000);
        _closeWindow(task);
        gov.settle(task);

        IThinkingGovernor.Thought memory t = gov.getThought(task);
        assertEq(uint8(t.status), uint8(IThinkingGovernor.Status.Settled), "CONTAINED: quorum formed despite front-run");
        bytes32 expectedKnob = bytes32((uint256(3) << 24) | (uint256(8000) << 8) | uint256(1));
        assertEq(gov.getKnob(MODEL_SPEC, KNOB_KEY), expectedKnob, "CONTAINED: governed decision NOT suppressed");
    }

    // ====================================================================
    // SIGNATURE EDGE CASES — v not in {27,28}, ERC-2098 (CONTAINED by OZ ECDSA)
    // ====================================================================

    /// @notice A raw Go-style signature with v in {0,1} (crypto.Sign convention) is
    /// REJECTED on-chain: ecrecover yields address(0) for v not in {27,28}, OZ ECDSA
    /// throws ECDSAInvalidSignature. The relay MUST normalize v += 27.
    function test_SigV01_CONTAINED_RejectedByEcrecover() public {
        uint256 task = _open(address(0xA11CE), MODEL_SPEC, 5, 3, KNOB_KEY);

        bytes32 ev = keccak256("x");
        bytes32 digest = gov.verdictDigest(task, ops[0].addr, MODEL_SPEC, 1, 8000, ev);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ops[0].pk, digest);
        // De-normalize v back to the Go {0,1} convention (27/28 -> 0/1).
        uint8 vRaw = v - 27;
        bytes memory rawSig = abi.encodePacked(r, s, vRaw);

        vm.prank(ops[0].addr);
        vm.expectRevert(); // ECDSAInvalidSignature (signer recovers to address(0))
        gov.submitVerdict(task, 1, 8000, ev, rawSig);
    }

    /// @notice A 64-byte ERC-2098 compact signature is REJECTED on the bytes path
    /// (OZ ECDSA.recover(bytes) only accepts 65-byte sigs; 64 -> InvalidSignatureLength).
    function test_Sig2098Compact_CONTAINED_RejectedLength() public {
        uint256 task = _open(address(0xA11CE), MODEL_SPEC, 5, 3, KNOB_KEY);

        bytes32 ev = keccak256("x");
        bytes32 digest = gov.verdictDigest(task, ops[0].addr, MODEL_SPEC, 1, 8000, ev);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ops[0].pk, digest);
        // Build ERC-2098 vs = s | (yParity << 255).
        bytes32 vs = bytes32((uint256(v - 27) << 255) | uint256(s));
        bytes memory compact = abi.encodePacked(r, vs); // 64 bytes

        vm.prank(ops[0].addr);
        vm.expectRevert(); // ECDSAInvalidSignatureLength(64)
        gov.submitVerdict(task, 1, 8000, ev, compact);
    }

    /// @notice ATTACK ATTEMPT: relay a genuine verdict signature minted for task A
    /// onto task B (same spec). CONTAINED: the digest binds taskId, so on task B the
    /// signature recovers a different address than the submitter -> rejected. Verdicts
    /// are non-transferable across tasks (strictly stronger than spec-binding).
    function test_CrossTaskReplay_CONTAINED_TaskBoundDigest() public {
        uint256 taskA = _open(address(0xA11CE), MODEL_SPEC, 5, 3, KNOB_KEY);
        uint256 taskB = _open(address(0xB0B), MODEL_SPEC, 5, 3, KNOB_KEY); // same spec

        bytes32 ev = keccak256("replay");
        bytes memory sigForA = _signVerdict(taskA, ops[0].addr, ops[0].pk, 1, 8000, ev);

        // Valid on A.
        vm.prank(ops[0].addr);
        gov.submitVerdict(taskA, 1, 8000, ev, sigForA);

        // The SAME bytes on B recover a different signer (digest binds taskB) -> reject.
        vm.prank(ops[0].addr);
        vm.expectRevert(); // SignerMismatch
        gov.submitVerdict(taskB, 1, 8000, ev, sigForA);

        assertEq(gov.getThought(taskA).submissionCount, 1, "A: one verdict");
        assertEq(gov.getThought(taskB).submissionCount, 0, "B: replayed sig rejected");
    }

    // ====================================================================
    // ESCROW LOCK — settle cannot be made to revert (CONTAINED)
    // ====================================================================

    /// @notice No submitted data can make settle() revert (all fields validated at
    /// submit; the KVP mirror is try/catch-isolated; reward math has no div-by-zero),
    /// so a task's escrow can never be permanently locked — settle always terminates.
    function test_SettleNeverReverts_CONTAINED_EscrowAlwaysReclaimable() public {
        uint256 task = _open(address(0xA11CE), MODEL_SPEC, 5, 3, KNOB_KEY);
        // Mixed votes across all enum values + grid extremes; settle must succeed.
        uint8[5] memory votes = [uint8(1), 2, 3, 4, 5];
        uint16[5] memory buckets = [uint16(0), 1000, 5000, 9000, 10000];
        for (uint256 i; i < 5; ++i) {
            bytes32 ev = keccak256(abi.encodePacked("m", i));
            bytes memory sig = _signVerdict(task, ops[i].addr, ops[i].pk, votes[i], buckets[i], ev);
            vm.prank(ops[i].addr);
            gov.submitVerdict(task, votes[i], buckets[i], ev, sig);
        }
        gov.settle(task); // count==n short-circuits the deadline gate; must not revert
        // Opener escrow refunded (no quorum among 5 distinct keys).
        assertEq(gov.rewardOf(address(0xA11CE)), REWARD, "escrow reclaimable on Failed");
    }

    // ====================================================================
    // VECTOR 2 — settle tie ordering (CONTAINED by strict-majority math)
    // ====================================================================

    /// @notice Two groups can never BOTH reach threshold (>= n/2 + 1), so the
    /// first-seen tie-break in settle can never pick the wrong WINNER among
    /// quorum-reaching groups. Below threshold both fail and the knob is untouched.
    function test_TieOrdering_CONTAINED_NoTwoGroupsReachThreshold() public {
        // n=4 => threshold>=3. Build the worst tie: 2 YES vs 2 NO (both = 2 < 3).
        uint256 task = _open(address(0xA11CE), MODEL_SPEC, 4, 3, KNOB_KEY);
        _submit(task, 0, 1, 8000);
        _submit(task, 1, 1, 8000);
        _submit(task, 2, 2, 2000);
        _submit(task, 3, 2, 2000);

        gov.settle(task); // count==n, immediate
        IThinkingGovernor.Thought memory t = gov.getThought(task);
        assertEq(uint8(t.status), uint8(IThinkingGovernor.Status.Failed), "tie below threshold -> Failed");
        assertEq(gov.getKnob(MODEL_SPEC, KNOB_KEY), bytes32(0), "no knob change on tie");
    }

    // For all n in [1,64], two distinct groups each of size >= floor(n/2)+1 would
    // need >= 2*(floor(n/2)+1) > n submitters, which exceeds the committee. Prove it.
    function testFuzz_TwoQuorumsImpossible(uint8 n) public pure {
        vm.assume(n >= 1 && n <= 64);
        uint16 threshold = uint16(n) / 2 + 1;
        assertGt(uint256(threshold) * 2, uint256(n), "two quorum groups cannot coexist");
    }

    // ====================================================================
    // VECTOR 3 — reentrancy via malicious keyValuePairs into settle (CONTAINED)
    // ====================================================================

    /// @notice A malicious KeyValuePairs re-enters settle(sameTask) inside the
    /// updateValues callback. The status guard (set to Settled BEFORE the external
    /// call) makes the reentrant settle revert with AlreadySettled; the try/catch
    /// swallows it; rewards are credited exactly once. No double-distribution.
    function test_ReentrantKVP_CONTAINED_NoDoubleSettle() public {
        ReentrantKVP evil = new ReentrantKVP();
        ThinkingGovernor g2 = new ThinkingGovernor(MIN_BOND, COOLDOWN, REWARD, OPEN_FEE, TREASURY, address(evil));
        evil.arm(g2);

        for (uint256 i; i < 3; ++i) {
            vm.prank(ops[i].addr);
            g2.registerOperator{value: MIN_BOND}();
        }
        vm.deal(address(0xC0DE), 10 ether);
        vm.prank(address(0xC0DE));
        uint256 task =
            g2.openThought{value: REWARD + OPEN_FEE}(MODEL_SPEC, PROMPT_HASH, TASK_EVIDENCE, 3, 2, WINDOW, KNOB_KEY);

        for (uint256 i; i < 3; ++i) {
            _submitOn(g2, task, ops[i], 1, 8000, keccak256(abi.encodePacked("e", i)));
        }

        evil.setTarget(task);
        g2.settle(task); // count==n, immediate

        // Each agreeing op got exactly REWARD/3 (+remainder to first). Sum == REWARD.
        uint256 total;
        for (uint256 i; i < 3; ++i) total += g2.rewardOf(ops[i].addr);
        assertEq(total, REWARD, "CONTAINED: rewards credited exactly once despite reentrancy");
        assertTrue(evil.reentered(), "sanity: the reentrant settle WAS attempted");
        assertTrue(evil.reentrantReverted(), "CONTAINED: reentrant settle reverted (AlreadySettled)");
    }

    // ====================================================================
    // VECTOR 7 — knob encoding aliasing at max values (CONTAINED)
    // ====================================================================

    /// @notice At the extremes (agree=64, bucket=10000, vote=5) the three packed
    /// fields occupy disjoint byte ranges: vote[0:8], bucket<<8 (<= bit 21),
    /// agree<<24 (bits 24+). No overlap, no overflow in the bytes32 word.
    function test_KnobEncoding_CONTAINED_NoAliasingAtMax() public pure {
        uint8 agree = 64;
        uint16 bucket = 10000; // MAX_CONFIDENCE_BPS
        uint8 vote = 5; // Unsafe (max enum)
        bytes32 packed = bytes32((uint256(agree) << 24) | (uint256(bucket) << 8) | uint256(vote));
        // Decode each field back and assert no bleed.
        uint256 k = uint256(packed);
        assertEq(uint8(k), vote, "vote field intact");
        assertEq(uint16(k >> 8), bucket, "bucket field intact (no overlap with agree)");
        assertEq(uint8(k >> 24), agree, "agree field intact");
        // Exact expected word.
        assertEq(packed, bytes32(uint256(0x40271005)), "exact packed value");
    }

    // ====================================================================
    // settle() GAS at the maximum committee (DoS measurement)
    // ====================================================================

    /// @notice Worst case for the O(n^2) tally. NOTE (RED finding INFO): the schema
    /// caps DISTINCT consensus keys at 5 votes * 11 buckets = 55, so a 64-member
    /// committee can yield at most 55 groups, not 64. We fill all 64 submitters
    /// across the 55 max-distinct keys (9 keys get a second member), which still
    /// drives the full inner-loop scan. No group reaches threshold=33 -> Failed.
    function test_Settle_GAS_MaxCommittee_MaxDistinctKeys() public {
        uint256 task = _open(address(0xA11CE), MODEL_SPEC, 64, 33, KNOB_KEY);
        uint256 placed;
        // First pass: lay down all 55 distinct (vote,bucket) keys.
        for (uint16 b = 0; b <= 10000 && placed < 64; b += 1000) {
            for (uint8 vt = 1; vt <= 5 && placed < 64; ++vt) {
                _submit(task, placed, vt, b);
                ++placed;
            }
        }
        // Second pass: fill the remaining 9 slots reusing low buckets/votes.
        for (uint16 b = 0; b <= 10000 && placed < 64; b += 1000) {
            for (uint8 vt = 1; vt <= 5 && placed < 64; ++vt) {
                _submit(task, placed, vt, b);
                ++placed;
            }
        }
        assertEq(placed, 64, "filled committee");

        uint256 g0 = gasleft();
        gov.settle(task); // count==n, immediate
        uint256 used = g0 - gasleft();
        emit log_named_uint("settle gas (n=64, 55 distinct)", used);
        // Sanity: must be well under a 30M block gas limit to not be a DoS.
        assertLt(used, 30_000_000, "settle must fit comfortably in a block");
    }

    /// @notice Worst case for the AGREEING-collection pass: n=64 all in ONE group
    /// (64 YES at bucket 8000), threshold=33 -> Settled, 64 agreers, 64 evidence
    /// folds, 64 reward credits. Measures settle+reward+knob path at max width.
    function test_Settle_GAS_MaxCommittee64Unanimous() public {
        uint256 task = _open(address(0xA11CE), MODEL_SPEC, 64, 33, KNOB_KEY);
        for (uint256 i; i < 64; ++i) _submit(task, i, 1, 8000);
        uint256 g0 = gasleft();
        gov.settle(task); // count==n, immediate
        uint256 used = g0 - gasleft();
        emit log_named_uint("settle gas (n=64, unanimous YES)", used);
        assertLt(used, 30_000_000, "settle must fit comfortably in a block");
    }
}

/// @dev Malicious KeyValuePairs that re-enters settle() inside updateValues.
contract ReentrantKVP is IKeyValuePairsV1 {
    ThinkingGovernor internal gov;
    uint256 internal target;
    bool public reentered;
    bool public reentrantReverted;

    function arm(ThinkingGovernor g) external {
        gov = g;
    }

    function setTarget(uint256 t) external {
        target = t;
    }

    function updateValues(KeyValuePair[] memory) external override {
        // Re-enter the SAME settle. Must fail (status already Settled) and be
        // swallowed by ThinkingGovernor's try/catch.
        reentered = true;
        try gov.settle(target) {
            reentrantReverted = false; // would mean a double-settle slipped through
        } catch {
            reentrantReverted = true;
        }
    }
}
