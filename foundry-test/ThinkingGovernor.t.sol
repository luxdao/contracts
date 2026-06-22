// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.31;

import "forge-std/Test.sol";

import {ThinkingGovernor} from "../contracts/deployables/thinking/ThinkingGovernor.sol";
import {ThinkingGate} from "../contracts/deployables/thinking/ThinkingGate.sol";
import {IThinkingGovernor} from "../contracts/deployables/thinking/interfaces/IThinkingGovernor.sol";
import {KeyValuePairsV1} from "../contracts/singletons/KeyValuePairsV1.sol";
import {IKeyValuePairsV1} from "../contracts/interfaces/dao/singletons/IKeyValuePairsV1.sol";

/// @title ThinkingGovernorTest
/// @notice Proves the on-chain Thinking Governor on a real EVM with GENUINE
/// secp256k1 signatures (vm.sign over real private keys). Every governance rule is
/// exercised end-to-end: registry/stake, task open, signed verdict submission
/// (recompute-preimage + ecrecover), quorum settlement, on-chain knob effect,
/// dissent visibility, idempotency, and cross-language preimage parity with the Go
/// operator (hanzo-evm/operator/canonical/governance.go).
contract ThinkingGovernorTest is Test {
    ThinkingGovernor internal gov;
    KeyValuePairsV1 internal kvp;

    // ---- protocol config under test ----
    uint256 internal constant MIN_BOND = 1 ether;
    uint64 internal constant COOLDOWN = 7 days;
    uint256 internal constant REWARD = 0.5 ether;
    uint256 internal constant OPEN_FEE = 0.1 ether;
    uint64 internal constant WINDOW = 1 hours;
    address internal constant TREASURY = address(0x7EA5);

    // ---- the canonical model spec all verdicts bind to ----
    // keccak256("zen/thinking-governor/model-spec/v1") — identical to the Go golden.
    bytes32 internal constant MODEL_SPEC = keccak256("zen/thinking-governor/model-spec/v1");
    bytes32 internal constant PROMPT_HASH = keccak256("should knob risk.maxLeverage change to 0x05?");
    bytes32 internal constant TASK_EVIDENCE = keccak256("evidence-bundle://thought-0");

    string internal constant KNOB_KEY = "risk.maxLeverage";

    // ---- operator keys (genuine private keys -> genuine signatures) ----
    struct Op {
        uint256 pk;
        address addr;
    }

    Op[5] internal ops;
    address internal opener;

    // Re-declared events for vm.expectEmit matching.
    event ThoughtSettled(
        uint256 indexed taskId,
        uint8 indexed vote,
        uint16 confidenceBucket,
        uint8 agreeCount,
        uint8 submissionCount,
        bytes32 evidenceRoot,
        address[] agreeingOperators
    );
    event KnobSet(bytes32 indexed modelSpecHash, string key, bytes32 value, uint256 indexed taskId);
    event ValueUpdated(address indexed sender, string key, string value);

    function setUp() public {
        kvp = new KeyValuePairsV1();
        gov = new ThinkingGovernor(MIN_BOND, COOLDOWN, REWARD, OPEN_FEE, TREASURY, address(kvp));

        // Five operators with deterministic, genuine keys.
        for (uint256 i; i < 5; ++i) {
            uint256 pk = 0xA11CE + i + 1;
            address a = vm.addr(pk);
            ops[i] = Op({pk: pk, addr: a});
            vm.deal(a, 10 ether);
            vm.prank(a);
            gov.registerOperator{value: MIN_BOND}();
        }

        opener = address(0xBEEF);
        vm.deal(opener, 100 ether);
    }

    // ======================================================================
    // helpers
    // ======================================================================

    /// @dev Default evidence hash for operator i on a task (deterministic).
    function _ev(uint256 taskId, uint256 i) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("ev", taskId, i));
    }

    /// @dev GENUINE signature over the DOMAIN-SEPARATED verdict digest (binds taskId,
    /// operator, consensus fields, evidence). vm.sign returns v∈{27,28}, which OZ
    /// ECDSA accepts. This is what an operator actually signs at submission.
    function _signVerdict(
        uint256 taskId,
        address operator,
        uint256 pk,
        uint8 vote,
        uint16 bucket,
        bytes32 evidence
    ) internal view returns (bytes memory) {
        bytes32 digest = gov.verdictDigest(taskId, operator, MODEL_SPEC, vote, bucket, evidence);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Sign + submit a verdict for operator index `i` with the default evidence.
    function _submit(uint256 taskId, uint256 i, uint8 vote, uint16 bucket) internal {
        bytes32 ev = _ev(taskId, i);
        bytes memory sig = _signVerdict(taskId, ops[i].addr, ops[i].pk, vote, bucket, ev);
        vm.prank(ops[i].addr);
        gov.submitVerdict(taskId, vote, bucket, ev, sig);
    }

    function _openThought(uint8 n, uint8 threshold) internal returns (uint256 taskId) {
        vm.prank(opener);
        taskId = gov.openThought{value: REWARD + OPEN_FEE}(
            MODEL_SPEC, PROMPT_HASH, TASK_EVIDENCE, n, threshold, WINDOW, KNOB_KEY
        );
    }

    /// @dev Warp past the voting window so settle() is permitted (window-closed path).
    function _closeWindow(uint256 taskId) internal {
        vm.warp(gov.getThought(taskId).deadline + 1);
    }

    // ======================================================================
    // 1. CROSS-LANGUAGE PARITY — the load-bearing Go<->Solidity assertion
    // ======================================================================

    /// @notice The Solidity canonical preimage hash MUST equal the Go operator's.
    /// Golden computed by the Go canonical package (luxfi/crypto.Keccak256, which
    /// is sha3.NewLegacyKeccak256 — identical to Solidity keccak256) for the fixed
    /// vector (MODEL_SPEC, vote=1 yes, bucket=8000). See report for the generator.
    function test_GoldenPreimageParity() public view {
        uint8 vote = 1; // yes
        uint16 bucket = 8000; // 80.00%

        // Golden model spec hash from the Go side.
        bytes32 goldenSpec = 0xe48ded87386a1be78fd0407f658f49b15bd4e27773758004db1236537ba2ac70;
        assertEq(MODEL_SPEC, goldenSpec, "model spec hash diverged from Go");

        // Golden 35-byte preimage: spec(32) || 0x01 || 0x1f40 (8000 big-endian).
        bytes memory goldenPreimage =
            hex"e48ded87386a1be78fd0407f658f49b15bd4e27773758004db1236537ba2ac70011f40";
        assertEq(gov.consensusPreimage(MODEL_SPEC, vote, bucket), goldenPreimage, "preimage layout diverged");
        assertEq(gov.consensusPreimage(MODEL_SPEC, vote, bucket).length, 35, "preimage must be 35 bytes");

        // Golden consensus hash = keccak256(preimage), from canonical.OutputHashGovernance.
        bytes32 golden = 0xdd43f1ec0082fb4e93128362785605a036e583c9d9d29dd0e1493cd83a5660b1;
        assertEq(gov.consensusHash(MODEL_SPEC, vote, bucket), golden, "consensus hash diverged from Go");

        // And the on-chain recompute equals abi.encodePacked path directly.
        assertEq(keccak256(abi.encodePacked(MODEL_SPEC, vote, bucket)), golden, "abi.encodePacked layout wrong");
    }

    /// @notice Fuzz the canonical layout for ALL inputs: the on-chain preimage must
    /// always be exactly spec(32) || vote(1) || u16be(bucket)(2) = 35 bytes, with
    /// bytes reconstructed the same way the Go side concatenates them. This proves
    /// the byte-for-byte layout (not just the single golden) matches binary.BigEndian.
    function testFuzz_PreimageLayoutMatchesGoConcatenation(
        bytes32 spec,
        uint8 vote,
        uint16 bucket
    ) public view {
        bytes memory got = gov.consensusPreimage(spec, vote, bucket);
        assertEq(got.length, 35, "preimage length");

        // Reconstruct exactly as Go does: spec bytes, then the vote byte, then the
        // big-endian uint16 of bucket (high byte first).
        bytes memory want = new bytes(35);
        for (uint256 i; i < 32; ++i) want[i] = spec[i];
        want[32] = bytes1(vote);
        want[33] = bytes1(uint8(bucket >> 8)); // big-endian high byte
        want[34] = bytes1(uint8(bucket & 0xff)); // big-endian low byte
        assertEq(got, want, "layout diverges from Go big-endian concatenation");

        // And the hash equals keccak of that reconstruction.
        assertEq(gov.consensusHash(spec, vote, bucket), keccak256(want), "hash != keccak(preimage)");
    }

    /// @notice The SUBMISSION digest (verdictDigest) golden, pinned identically on
    /// the Go side (canonical.TestThinkingGovernorVerdictDigestParity). Proves the
    /// full off-chain→on-chain submission path is byte-parity: an operator signing
    /// this digest produces a signature submitVerdict will ecrecover to that operator.
    function test_GoldenVerdictDigestParity() public view {
        bytes32 spec = 0xe48ded87386a1be78fd0407f658f49b15bd4e27773758004db1236537ba2ac70;
        address op = address(0x0000000000000000000000000000000000000001);
        bytes32 ev = keccak256("ev-golden");
        assertEq(ev, 0xa92417646bbc9ecd4c96a0e815b20ca7d7ab5a50dbad6d56d2c5c8c09500829d, "evidence golden");
        assertEq(
            gov.VERDICT_DOMAIN(),
            0x0c578d46b25c72738e526644e19909fc3e5561532154c246fb4876115bf47a8d,
            "VERDICT_DOMAIN golden"
        );
        bytes32 vd = gov.verdictDigest(7, op, spec, 1, 8000, ev);
        assertEq(vd, 0x2ddbb48e0b829a7f762fb1d23757a15404e4ab64a6f95d149518bd2c59935d59, "verdictDigest golden (Go parity)");
    }

    // ======================================================================
    // 2. REGISTRY / STAKE / ELIGIBILITY
    // ======================================================================

    function test_RegisterAndEligibility() public view {
        assertTrue(gov.isOperator(ops[0].addr), "bonded op should be eligible");
        assertEq(gov.bondOf(ops[0].addr), MIN_BOND);
        assertFalse(gov.isOperator(address(0xDEAD)), "unbonded should be ineligible");
    }

    function test_RegisterRejectsLowBond() public {
        address newOp = address(0xC0FFEE);
        vm.deal(newOp, 10 ether);
        vm.prank(newOp);
        vm.expectRevert(abi.encodeWithSelector(IThinkingGovernor.BondTooLow.selector, 0.5 ether, MIN_BOND));
        gov.registerOperator{value: 0.5 ether}();
    }

    function test_RegisterRejectsDouble() public {
        vm.prank(ops[0].addr);
        vm.expectRevert(abi.encodeWithSelector(IThinkingGovernor.AlreadyRegistered.selector, ops[0].addr));
        gov.registerOperator{value: MIN_BOND}();
    }

    function test_DeregisterCooldownThenWithdraw() public {
        address a = ops[0].addr;
        vm.prank(a);
        gov.deregister();
        assertFalse(gov.isOperator(a), "deregistering op must be ineligible");

        vm.prank(a);
        vm.expectRevert();
        gov.withdrawBond();

        vm.warp(block.timestamp + COOLDOWN + 1);
        uint256 balBefore = a.balance;
        vm.prank(a);
        gov.withdrawBond();
        assertEq(a.balance, balBefore + MIN_BOND, "bond returned");
        assertEq(gov.bondOf(a), 0, "bond zeroed");
    }

    // ======================================================================
    // 3. openThought VALIDATION (threshold, window, payment, fee accrual)
    // ======================================================================

    function test_OpenThoughtValid() public {
        uint256 taskId = _openThought(5, 3);
        IThinkingGovernor.Thought memory t = gov.getThought(taskId);
        assertEq(t.n, 5);
        assertEq(t.threshold, 3);
        assertEq(uint8(t.status), uint8(IThinkingGovernor.Status.Open));
        assertEq(t.knobKey, KNOB_KEY);
        assertEq(t.modelSpecHash, MODEL_SPEC);
        assertEq(t.deadline, t.openedAt + WINDOW, "deadline = openedAt + window");
        assertEq(gov.taskCount(), 1);
        // The non-refundable open fee accrued to the treasury immediately.
        assertEq(gov.rewardOf(TREASURY), OPEN_FEE, "open fee accrued to treasury");
    }

    function test_OpenThoughtRejectsWeakThreshold() public {
        vm.prank(opener);
        vm.expectRevert(abi.encodeWithSelector(IThinkingGovernor.BadThreshold.selector, uint8(5), uint8(2)));
        gov.openThought{value: REWARD + OPEN_FEE}(MODEL_SPEC, PROMPT_HASH, TASK_EVIDENCE, 5, 2, WINDOW, KNOB_KEY);
    }

    function test_OpenThoughtRejectsThresholdAboveN() public {
        vm.prank(opener);
        vm.expectRevert(abi.encodeWithSelector(IThinkingGovernor.BadThreshold.selector, uint8(5), uint8(6)));
        gov.openThought{value: REWARD + OPEN_FEE}(MODEL_SPEC, PROMPT_HASH, TASK_EVIDENCE, 5, 6, WINDOW, KNOB_KEY);
    }

    function test_OpenThoughtRejectsZeroSpec() public {
        vm.prank(opener);
        vm.expectRevert(IThinkingGovernor.ZeroModelSpec.selector);
        gov.openThought{value: REWARD + OPEN_FEE}(bytes32(0), PROMPT_HASH, TASK_EVIDENCE, 5, 3, WINDOW, KNOB_KEY);
    }

    function test_OpenThoughtRejectsEmptyKnob() public {
        vm.prank(opener);
        vm.expectRevert(IThinkingGovernor.EmptyKnobKey.selector);
        gov.openThought{value: REWARD + OPEN_FEE}(MODEL_SPEC, PROMPT_HASH, TASK_EVIDENCE, 5, 3, WINDOW, "");
    }

    function test_OpenThoughtRejectsBadWindow() public {
        vm.prank(opener);
        vm.expectRevert(abi.encodeWithSelector(IThinkingGovernor.BadVotingWindow.selector, uint64(1)));
        gov.openThought{value: REWARD + OPEN_FEE}(MODEL_SPEC, PROMPT_HASH, TASK_EVIDENCE, 5, 3, 1, KNOB_KEY);

        uint64 tooLong = gov.MAX_VOTING_WINDOW() + 1;
        vm.prank(opener);
        vm.expectRevert(abi.encodeWithSelector(IThinkingGovernor.BadVotingWindow.selector, tooLong));
        gov.openThought{value: REWARD + OPEN_FEE}(MODEL_SPEC, PROMPT_HASH, TASK_EVIDENCE, 5, 3, tooLong, KNOB_KEY);
    }

    function test_OpenThoughtRequiresExactPayment() public {
        // must pay reward + openFee exactly.
        vm.prank(opener);
        vm.expectRevert(
            abi.encodeWithSelector(IThinkingGovernor.WrongOpenPayment.selector, REWARD, REWARD + OPEN_FEE)
        );
        gov.openThought{value: REWARD}(MODEL_SPEC, PROMPT_HASH, TASK_EVIDENCE, 5, 3, WINDOW, KNOB_KEY);
    }

    // ======================================================================
    // 4. submitVerdict — signature recovery, operator-bound, anti-replay
    // ======================================================================

    /// @notice Happy path: 5 ops, 4 sign YES@ 8000, 1 signs NO@ 2000. Each verdict's
    /// domain-separated signature is recovered (ecrecover) and accepted.
    function test_SubmitVerdict_HappyPath() public {
        uint256 taskId = _openThought(5, 3);
        for (uint256 i; i < 4; ++i) _submit(taskId, i, 1, 8000);
        _submit(taskId, 4, 2, 2000);

        IThinkingGovernor.Thought memory t = gov.getThought(taskId);
        assertEq(t.submissionCount, 5, "all 5 verdicts recorded");

        IThinkingGovernor.Verdict memory v0 = gov.getVerdict(taskId, ops[0].addr);
        assertEq(uint8(v0.vote), 1);
        assertEq(v0.confidenceBucket, 8000);
        assertEq(v0.operator, ops[0].addr);
    }

    /// @notice A signature from a non-registered key is rejected at eligibility
    /// (recovers to msg.sender, but that address is not bonded).
    function test_SubmitVerdict_RejectsNonOperator() public {
        uint256 taskId = _openThought(5, 3);
        uint256 strangerPk = 0xBADBAD;
        address stranger = vm.addr(strangerPk);
        vm.deal(stranger, 1 ether);

        bytes32 ev = keccak256("x");
        bytes memory sig = _signVerdict(taskId, stranger, strangerPk, 1, 8000, ev);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IThinkingGovernor.NotBonded.selector, stranger));
        gov.submitVerdict(taskId, 1, 8000, ev, sig);
    }

    /// @notice A relayed/detached signature (signer != msg.sender) is rejected. The
    /// digest binds operator = msg.sender, so when ops[1] relays ops[0]'s signature
    /// the contract recomputes the digest with operator=ops[1], recovers an address
    /// that is neither ops[0] nor ops[1], and reverts SignerMismatch. (Recovered addr
    /// is unpredictable by construction, so we assert a generic revert.)
    function test_SubmitVerdict_RejectsSignerMismatch() public {
        uint256 taskId = _openThought(5, 3);
        bytes32 ev = keccak256("x");
        bytes memory sigBy0 = _signVerdict(taskId, ops[0].addr, ops[0].pk, 1, 8000, ev);
        vm.prank(ops[1].addr);
        vm.expectRevert(); // SignerMismatch with an unpredictable recovered address
        gov.submitVerdict(taskId, 1, 8000, ev, sigBy0);
    }

    /// @notice The verdict digest binds taskId: a signature minted for task A is
    /// NOT valid on task B (even same spec). ops[0] signs for taskA, replay on taskB
    /// recovers a different address than ops[0] -> SignerMismatch. This is STRONGER
    /// than the old spec-bound behavior: verdicts are now per-task non-transferable.
    function test_SubmitVerdict_TaskBoundSig_NotReplayableAcrossTasks() public {
        uint256 taskA = _openThought(5, 3);
        uint256 taskB = _openThought(5, 3); // same MODEL_SPEC

        bytes32 ev = keccak256("a");
        bytes memory sigForA = _signVerdict(taskA, ops[0].addr, ops[0].pk, 1, 8000, ev);

        // Valid on A.
        vm.prank(ops[0].addr);
        gov.submitVerdict(taskA, 1, 8000, ev, sigForA);

        // The SAME bytes replayed on B recover a different signer (digest binds
        // taskB != taskA) -> rejected. Verdict is non-transferable across tasks.
        vm.prank(ops[0].addr);
        vm.expectRevert(); // SignerMismatch (recovered addr unpredictable)
        gov.submitVerdict(taskB, 1, 8000, ev, sigForA);

        // And it cannot be replayed on A either (one-per-operator-per-task).
        vm.prank(ops[0].addr);
        vm.expectRevert(abi.encodeWithSelector(IThinkingGovernor.AlreadyVoted.selector, taskA, ops[0].addr));
        gov.submitVerdict(taskA, 1, 8000, ev, sigForA);

        assertEq(gov.getThought(taskA).submissionCount, 1, "A: exactly one verdict");
        assertEq(gov.getThought(taskB).submissionCount, 0, "B: no verdict from replayed sig");
    }

    /// @notice Double-submit by the same operator on one task is rejected.
    function test_SubmitVerdict_RejectsDoubleSubmit() public {
        uint256 taskId = _openThought(5, 3);
        _submit(taskId, 0, 1, 8000);

        bytes32 ev2 = keccak256("e2");
        bytes memory sig2 = _signVerdict(taskId, ops[0].addr, ops[0].pk, 2, 2000, ev2);
        vm.prank(ops[0].addr);
        vm.expectRevert(abi.encodeWithSelector(IThinkingGovernor.AlreadyVoted.selector, taskId, ops[0].addr));
        gov.submitVerdict(taskId, 2, 2000, ev2, sig2);
    }

    /// @notice The opener cannot vote on its own task (anti self-deal). The opener is
    /// a real keyed operator so the signature is genuine — proving the OpenerCannotVote
    /// guard fires on its own merit, not because of a malformed signature.
    function test_SubmitVerdict_RejectsOpenerVoting() public {
        uint256 oPk = 0x0FE2;
        address o = vm.addr(oPk);
        vm.deal(o, 10 ether);
        vm.prank(o);
        gov.registerOperator{value: MIN_BOND}();
        vm.prank(o);
        uint256 taskId = gov.openThought{value: REWARD + OPEN_FEE}(
            MODEL_SPEC, PROMPT_HASH, TASK_EVIDENCE, 5, 3, WINDOW, KNOB_KEY
        );

        bytes32 ev = keccak256("self");
        bytes memory sig = _signVerdict(taskId, o, oPk, 1, 8000, ev); // genuine signature by the opener
        vm.prank(o);
        vm.expectRevert(abi.encodeWithSelector(IThinkingGovernor.OpenerCannotVote.selector, taskId, o));
        gov.submitVerdict(taskId, 1, 8000, ev, sig);
    }

    /// @notice Tampering ANY signed field (here: bucket) breaks recovery -> mismatch.
    function test_SubmitVerdict_RejectsTamperedFields() public {
        uint256 taskId = _openThought(5, 3);
        bytes32 ev = keccak256("e");
        bytes memory sig = _signVerdict(taskId, ops[0].addr, ops[0].pk, 1, 8000, ev); // signed 8000
        vm.prank(ops[0].addr);
        vm.expectRevert(); // submit bucket=7000 -> different digest -> SignerMismatch
        gov.submitVerdict(taskId, 1, 7000, ev, sig);
    }

    /// @notice Tampering the evidenceHash (now signed) breaks recovery -> mismatch.
    /// Closes the RED finding that evidenceHash was unsigned.
    function test_SubmitVerdict_EvidenceBoundBySignature() public {
        uint256 taskId = _openThought(5, 3);
        bytes32 signedEv = keccak256("real-evidence");
        bytes memory sig = _signVerdict(taskId, ops[0].addr, ops[0].pk, 1, 8000, signedEv);

        // Submit a DIFFERENT evidence hash than was signed -> digest differs -> reject.
        vm.prank(ops[0].addr);
        vm.expectRevert(); // SignerMismatch
        gov.submitVerdict(taskId, 1, 8000, keccak256("forged-evidence"), sig);

        // The genuine evidence is accepted.
        vm.prank(ops[0].addr);
        gov.submitVerdict(taskId, 1, 8000, signedEv, sig);
        assertEq(gov.getVerdict(taskId, ops[0].addr).evidenceHash, signedEv, "signed evidence stored");
    }

    function test_SubmitVerdict_RejectsInvalidVote() public {
        uint256 taskId = _openThought(5, 3);
        bytes32 ev = keccak256("e");
        bytes memory sig = _signVerdict(taskId, ops[0].addr, ops[0].pk, 0, 8000, ev);
        vm.prank(ops[0].addr);
        vm.expectRevert(abi.encodeWithSelector(IThinkingGovernor.InvalidVote.selector, uint8(0)));
        gov.submitVerdict(taskId, 0, 8000, ev, sig);
    }

    function test_SubmitVerdict_RejectsOffGridBucket() public {
        uint256 taskId = _openThought(5, 3);
        bytes32 ev = keccak256("e");
        bytes memory sig = _signVerdict(taskId, ops[0].addr, ops[0].pk, 1, 8500, ev);
        vm.prank(ops[0].addr);
        vm.expectRevert(abi.encodeWithSelector(IThinkingGovernor.BadConfidenceBucket.selector, uint16(8500)));
        gov.submitVerdict(taskId, 1, 8500, ev, sig);
    }

    // ======================================================================
    // 5. settle — quorum, canonical decision, knob, dissent, idempotency
    // ======================================================================

    /// @notice Full YES-quorum: 4/5 agree YES@ 8000 -> canonical = YES@ 8000, knob
    /// set on-chain (spec-scoped), ThoughtSettled carries the 4 agreeing operators.
    function test_Settle_YesQuorum_SetsKnobAndRecordsDecision() public {
        uint256 taskId = _openThought(5, 3);
        address[] memory expectAgree = new address[](4);
        for (uint256 i; i < 4; ++i) {
            _submit(taskId, i, 1, 8000);
            expectAgree[i] = ops[i].addr;
        }
        _submit(taskId, 4, 2, 2000);

        // All 5 slots filled (count==n) so settle is permitted immediately.
        assertEq(gov.getKnob(MODEL_SPEC, KNOB_KEY), bytes32(0), "knob unset pre-settle");

        vm.recordLogs();
        gov.settle(taskId);

        (bool settled, IThinkingGovernor.Vote vote, uint16 bucket, uint8 agree) = gov.getCanonicalVerdict(taskId);
        assertTrue(settled, "task settled");
        assertEq(uint8(vote), 1, "canonical vote = YES");
        assertEq(bucket, 8000, "canonical bucket = 8000");
        assertEq(agree, 4, "agree count = 4");

        bytes32 expectedKnob = bytes32((uint256(4) << 24) | (uint256(8000) << 8) | uint256(1));
        assertEq(gov.getKnob(MODEL_SPEC, KNOB_KEY), expectedKnob, "knob set to encoded decision");
        // A DIFFERENT spec's knob is untouched (scoping).
        assertEq(gov.getKnob(keccak256("other-spec"), KNOB_KEY), bytes32(0), "other spec knob untouched");

        bytes32 root;
        for (uint256 i; i < 4; ++i) root = keccak256(abi.encodePacked(root, _ev(taskId, i)));
        assertEq(gov.getThought(taskId).evidenceRoot, root, "evidence root folds agreeing evidence");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool sawSettled;
        bool sawKnob;
        bool sawKvp;
        for (uint256 i; i < logs.length; ++i) {
            bytes32 topic0 = logs[i].topics[0];
            if (topic0 == keccak256("ThoughtSettled(uint256,uint8,uint16,uint8,uint8,bytes32,address[])")) {
                sawSettled = true;
                assertEq(uint256(logs[i].topics[1]), taskId, "settled taskId");
                assertEq(uint256(logs[i].topics[2]), 1, "settled vote=YES indexed");
                (uint16 b, uint8 ac, uint8 sc, bytes32 er, address[] memory ag) =
                    abi.decode(logs[i].data, (uint16, uint8, uint8, bytes32, address[]));
                assertEq(b, 8000);
                assertEq(ac, 4);
                assertEq(sc, 5);
                assertEq(er, root);
                assertEq(ag.length, 4, "4 agreeing operators in event");
                for (uint256 j; j < 4; ++j) assertEq(ag[j], expectAgree[j]);
            } else if (topic0 == keccak256("KnobSet(bytes32,string,bytes32,uint256)")) {
                sawKnob = true;
                assertEq(logs[i].topics[1], MODEL_SPEC, "KnobSet indexed by spec");
            } else if (topic0 == keccak256("ValueUpdated(address,string,string)")) {
                sawKvp = true;
            }
        }
        assertTrue(sawSettled, "ThoughtSettled emitted");
        assertTrue(sawKnob, "KnobSet emitted");
        assertTrue(sawKvp, "KeyValuePairs ValueUpdated mirror emitted");
    }

    /// @notice Rewards: agreeing operators each accrue REWARD/agreeCount; dissenter
    /// accrues nothing; claimable via pull-payment.
    function test_Settle_RewardsAgreeingOperators() public {
        uint256 taskId = _openThought(5, 3);
        for (uint256 i; i < 4; ++i) _submit(taskId, i, 1, 8000);
        _submit(taskId, 4, 2, 2000);
        gov.settle(taskId);

        uint256 share = REWARD / 4;
        assertEq(gov.rewardOf(ops[0].addr), share, "agreeing op accrues share");
        assertEq(gov.rewardOf(ops[4].addr), 0, "dissenter accrues nothing");

        uint256 balBefore = ops[0].addr.balance;
        vm.prank(ops[0].addr);
        gov.claimReward();
        assertEq(ops[0].addr.balance, balBefore + share, "reward claimed");
        assertEq(gov.rewardOf(ops[0].addr), 0, "reward zeroed after claim");
    }

    /// @notice Value conservation: contract holds exactly sum(bonds) + sum(unclaimed
    /// rewards incl. opener fee). No wei locked/created. Odd split (3 share 0.5 eth).
    function test_Settle_ValueConservation_NoLockedWei() public {
        uint256 taskId = _openThought(5, 3);
        for (uint256 i; i < 3; ++i) _submit(taskId, i, 1, 8000); // odd split
        for (uint256 i = 3; i < 5; ++i) _submit(taskId, i, 2, 2000);
        gov.settle(taskId);

        // Sum of agreeing rewards == full reward escrow (fee is separate, to treasury).
        uint256 totalAgree;
        for (uint256 i; i < 5; ++i) totalAgree += gov.rewardOf(ops[i].addr);
        assertEq(totalAgree, REWARD, "full reward escrow distributed, zero dust");

        // Contract balance == 5 bonds + reward escrow + open fee (all unclaimed).
        assertEq(address(gov).balance, 5 * MIN_BOND + REWARD + OPEN_FEE, "balance == bonds + escrow + fee");

        // Drain agreeing rewards + treasury fee; only bonds remain.
        for (uint256 i; i < 3; ++i) {
            if (gov.rewardOf(ops[i].addr) != 0) {
                vm.prank(ops[i].addr);
                gov.claimReward();
            }
        }
        vm.prank(TREASURY);
        gov.claimReward();
        assertEq(address(gov).balance, 5 * MIN_BOND, "after claims, only bonds remain");
    }

    /// @notice No-quorum: 2 YES@ 8000, 2 NO@ 2000, 1 ABSTAIN@ 0, threshold=3. Largest
    /// group is 2 < 3 => Failed, knob unchanged, opener refunded the reward escrow.
    function test_Settle_NoQuorum_Fails_KnobUnchanged() public {
        uint256 taskId = _openThought(5, 3);
        _submit(taskId, 0, 1, 8000);
        _submit(taskId, 1, 1, 8000);
        _submit(taskId, 2, 2, 2000);
        _submit(taskId, 3, 2, 2000);
        _submit(taskId, 4, 3, 0);

        uint256 openerBalBefore = opener.balance;
        gov.settle(taskId);

        (bool settled,,, uint8 agree) = gov.getCanonicalVerdict(taskId);
        assertFalse(settled, "no quorum => not settled");
        assertEq(agree, 0, "no agreeing group recorded");

        assertEq(uint8(gov.getThought(taskId).status), uint8(IThinkingGovernor.Status.Failed), "status Failed");
        assertEq(gov.getKnob(MODEL_SPEC, KNOB_KEY), bytes32(0), "knob unchanged on no-quorum");

        assertEq(gov.rewardOf(opener), REWARD, "opener refunded reward escrow");
        vm.prank(opener);
        gov.claimReward();
        assertEq(opener.balance, openerBalBefore + REWARD, "opener withdrew refund");
    }

    /// @notice settle is idempotent: a second settle reverts; post-settle submission rejected.
    function test_Settle_IdempotentAndRejectsReplay() public {
        uint256 taskId = _openThought(5, 3);
        for (uint256 i; i < 4; ++i) _submit(taskId, i, 1, 8000);
        _closeWindow(taskId); // 4 of 5 in -> need the window to close to settle
        gov.settle(taskId);

        vm.expectRevert(abi.encodeWithSelector(IThinkingGovernor.AlreadySettled.selector, taskId));
        gov.settle(taskId);

        bytes32 ev = keccak256("late");
        bytes memory lateSig = _signVerdict(taskId, ops[4].addr, ops[4].pk, 1, 8000, ev);
        vm.prank(ops[4].addr);
        vm.expectRevert(abi.encodeWithSelector(IThinkingGovernor.TaskNotOpen.selector, taskId));
        gov.submitVerdict(taskId, 1, 8000, ev, lateSig);

        (bool settled, IThinkingGovernor.Vote vote, uint16 bucket, uint8 agree) = gov.getCanonicalVerdict(taskId);
        assertTrue(settled);
        assertEq(uint8(vote), 1);
        assertEq(bucket, 8000);
        assertEq(agree, 4);
    }

    /// @notice Confidence bucket is part of the consensus key: 2 YES@ 8000 + 2 YES@
    /// 7000 + 1 NO@ 2000, threshold=3 => no group hits 3 => Failed.
    function test_Settle_ConfidenceBucketSplitsQuorum() public {
        uint256 taskId = _openThought(5, 3);
        _submit(taskId, 0, 1, 8000);
        _submit(taskId, 1, 1, 8000);
        _submit(taskId, 2, 1, 7000);
        _submit(taskId, 3, 1, 7000);
        _submit(taskId, 4, 2, 2000);

        gov.settle(taskId);
        assertEq(uint8(gov.getThought(taskId).status), uint8(IThinkingGovernor.Status.Failed), "split -> no quorum");
        assertEq(gov.getKnob(MODEL_SPEC, KNOB_KEY), bytes32(0), "knob unchanged");
    }

    /// @notice A NO-quorum settles canonically but does NOT set the knob.
    function test_Settle_NoQuorum_RecordsButDoesNotSetKnob() public {
        uint256 taskId = _openThought(5, 3);
        for (uint256 i; i < 4; ++i) _submit(taskId, i, 2, 4000);
        _submit(taskId, 4, 1, 8000);
        gov.settle(taskId);

        (bool settled, IThinkingGovernor.Vote vote, uint16 bucket, uint8 agree) = gov.getCanonicalVerdict(taskId);
        assertTrue(settled, "NO quorum still settles");
        assertEq(uint8(vote), 2, "canonical vote = NO");
        assertEq(bucket, 4000);
        assertEq(agree, 4);
        assertEq(gov.getKnob(MODEL_SPEC, KNOB_KEY), bytes32(0), "NO decision must not set knob");
    }

    // ======================================================================
    // 5b. settle LIVENESS GATE — premature/empty/front-run blocked (RED fixes)
    // ======================================================================

    /// @notice An empty task cannot be force-failed before its window closes.
    function test_Settle_RejectsEmptyBeforeDeadline() public {
        uint256 taskId = _openThought(5, 3);
        address griefer = address(0x6111E5);
        vm.prank(griefer);
        vm.expectRevert(
            abi.encodeWithSelector(IThinkingGovernor.SettleTooEarly.selector, taskId, gov.getThought(taskId).deadline)
        );
        gov.settle(taskId);
    }

    /// @notice A griefer cannot front-run the threshold-th vote: settle is blocked
    /// until the window closes, by which time the honest 3rd vote has landed and the
    /// quorum forms. The decision is NOT suppressed.
    function test_Settle_FrontRunBlocked_QuorumStillForms() public {
        uint256 taskId = _openThought(5, 3);
        _submit(taskId, 0, 1, 8000);
        _submit(taskId, 1, 1, 8000);

        // Griefer tries to settle before the 3rd vote -> blocked (count<n, pre-deadline).
        vm.prank(address(0x6111E5));
        vm.expectRevert(
            abi.encodeWithSelector(IThinkingGovernor.SettleTooEarly.selector, taskId, gov.getThought(taskId).deadline)
        );
        gov.settle(taskId);

        // The 3rd honest vote lands while the task is still open.
        _submit(taskId, 2, 1, 8000);
        _closeWindow(taskId);
        gov.settle(taskId);

        (bool settled, IThinkingGovernor.Vote vote,, uint8 agree) = gov.getCanonicalVerdict(taskId);
        assertTrue(settled && vote == IThinkingGovernor.Vote.Yes, "quorum formed despite front-run attempt");
        assertEq(agree, 3);
        assertEq(gov.getKnob(MODEL_SPEC, KNOB_KEY), bytes32((uint256(3) << 24) | (uint256(8000) << 8) | uint256(1)));
    }

    /// @notice A full committee (count==n) settles immediately, no window wait needed.
    function test_Settle_FullCommittee_SettlesImmediately() public {
        uint256 taskId = _openThought(3, 2);
        for (uint256 i; i < 3; ++i) _submit(taskId, i, 1, 8000);
        // No warp: count==n short-circuits the deadline gate.
        gov.settle(taskId);
        (bool settled,,,) = gov.getCanonicalVerdict(taskId);
        assertTrue(settled, "full committee settles before deadline");
    }

    // ======================================================================
    // 5c. ELIGIBILITY RE-CHECKED AT SETTLE — exited operator dropped (RED fix)
    // ======================================================================

    /// @notice An operator that fully exits (bond->0) after submitting is DROPPED at
    /// settle: its stale verdict cannot tip the quorum. With cooldown=0, o0 exits,
    /// leaving only 1 eligible YES < threshold=2 => Failed.
    function test_Settle_ExitedOperatorDropped() public {
        ThinkingGovernor g2 = new ThinkingGovernor(MIN_BOND, 0, REWARD, OPEN_FEE, TREASURY, address(kvp));
        for (uint256 i; i < 2; ++i) {
            vm.prank(ops[i].addr);
            g2.registerOperator{value: MIN_BOND}();
        }
        vm.deal(address(0xC0DE), 10 ether);
        vm.prank(address(0xC0DE));
        uint256 task = g2.openThought{value: REWARD + OPEN_FEE}(
            MODEL_SPEC, PROMPT_HASH, TASK_EVIDENCE, 3, 2, WINDOW, KNOB_KEY
        );

        // o0 submits, then fully exits (cooldown=0).
        bytes32 ev0 = keccak256("x0");
        bytes memory s0 = _vd(g2, task, ops[0].addr, ops[0].pk, 1, 8000, ev0);
        vm.prank(ops[0].addr);
        g2.submitVerdict(task, 1, 8000, ev0, s0);
        vm.prank(ops[0].addr);
        g2.deregister();
        vm.prank(ops[0].addr);
        g2.withdrawBond();
        assertEq(g2.bondOf(ops[0].addr), 0, "o0 fully exited");

        // o1 agrees -> stored verdicts = 2 YES, but only o1 is eligible at settle.
        bytes32 ev1 = keccak256("x1");
        bytes memory s1 = _vd(g2, task, ops[1].addr, ops[1].pk, 1, 8000, ev1);
        vm.prank(ops[1].addr);
        g2.submitVerdict(task, 1, 8000, ev1, s1);

        _closeWindowOn(g2, task);
        g2.settle(task);
        (bool settled,,, uint8 agree) = g2.getCanonicalVerdict(task);
        assertFalse(settled, "exited operator dropped -> only 1 eligible YES < 2 -> Failed");
        assertEq(agree, 0, "no quorum");
    }

    /// @notice Treasury fee accounting is orthogonal to bonds: the treasury accrues
    /// open fees in _rewards and claims them via claimReward; even if the treasury is
    /// ALSO a registered operator, its bond (_operators) and fees (_rewards) never mix.
    function test_Treasury_ClaimsFees_OrthogonalToBond() public {
        // Two tasks opened -> treasury accrued 2 * OPEN_FEE.
        _openThought(5, 3);
        _openThought(5, 3);
        assertEq(gov.rewardOf(TREASURY), 2 * OPEN_FEE, "treasury accrued both fees");

        // Treasury also registers as an operator (separate bond accounting).
        vm.deal(TREASURY, 10 ether);
        vm.prank(TREASURY);
        gov.registerOperator{value: MIN_BOND}();
        assertEq(gov.bondOf(TREASURY), MIN_BOND, "treasury bond tracked separately");
        assertEq(gov.rewardOf(TREASURY), 2 * OPEN_FEE, "treasury fees untouched by bonding");

        // Claim fees: only the reward balance moves; the bond stays locked.
        uint256 balBefore = TREASURY.balance;
        vm.prank(TREASURY);
        gov.claimReward();
        assertEq(TREASURY.balance, balBefore + 2 * OPEN_FEE, "treasury claimed fees");
        assertEq(gov.rewardOf(TREASURY), 0, "fees zeroed");
        assertEq(gov.bondOf(TREASURY), MIN_BOND, "bond still locked after fee claim");
    }

    /// @notice A deregistered operator cannot re-activate without a full withdraw +
    /// re-register (re-bonding real capital). It can't "instant re-register" to dodge
    /// the eligibility-at-settle drop while keeping a withdrawn bond. registerOperator
    /// reverts AlreadyRegistered while the bond is still locked.
    function test_Deregister_CannotReactivateWithoutRebonding() public {
        address a = ops[0].addr;
        vm.prank(a);
        gov.deregister();
        assertFalse(gov.isOperator(a), "ineligible after deregister");

        // Re-register blocked: bond still locked (non-zero).
        vm.prank(a);
        vm.expectRevert(abi.encodeWithSelector(IThinkingGovernor.AlreadyRegistered.selector, a));
        gov.registerOperator{value: MIN_BOND}();

        // Only after cooldown + withdraw (bond->0) can it re-register (re-bond).
        vm.warp(block.timestamp + COOLDOWN + 1);
        vm.prank(a);
        gov.withdrawBond();
        vm.prank(a);
        gov.registerOperator{value: MIN_BOND}();
        assertTrue(gov.isOperator(a), "eligible again only after re-bonding fresh capital");
    }

    // ======================================================================
    // 6. TASK CAP + unknown task + cross-spec knob isolation (RED CRITICAL fix)
    // ======================================================================

    function test_SubmitVerdict_RejectsWhenFull() public {
        uint256 taskId = _openThought(3, 2);
        for (uint256 i; i < 3; ++i) _submit(taskId, i, 1, 8000);
        bytes32 ev = keccak256("overflow");
        bytes memory sig4 = _signVerdict(taskId, ops[3].addr, ops[3].pk, 1, 8000, ev);
        vm.prank(ops[3].addr);
        vm.expectRevert(abi.encodeWithSelector(IThinkingGovernor.TaskFull.selector, taskId));
        gov.submitVerdict(taskId, 1, 8000, ev, sig4);
    }

    function test_Views_RevertOnUnknownTask() public {
        vm.expectRevert(abi.encodeWithSelector(IThinkingGovernor.UnknownTask.selector, uint256(99)));
        gov.getThought(99);
    }

    /// @notice CRITICAL FIX (RED): a task under one spec cannot overwrite a knob
    /// governed by another spec, even with the SAME knobKey. A consumer reads
    /// getKnob(itsSpec, key) and an attacker opening under a different spec is
    /// invisible to it.
    function test_Knob_SpecScoped_NoCrossSpecHijack() public {
        // Legit decision under MODEL_SPEC sets the consumer's knob.
        uint256 taskA = _openThought(5, 3);
        for (uint256 i; i < 3; ++i) _submit(taskA, i, 1, 8000);
        _closeWindow(taskA);
        gov.settle(taskA);
        bytes32 legit = bytes32((uint256(3) << 24) | (uint256(8000) << 8) | uint256(1));
        assertEq(gov.getKnob(MODEL_SPEC, KNOB_KEY), legit, "consumer knob set");

        // Attacker opens under a DIFFERENT spec, SAME knobKey, drives a YES quorum.
        bytes32 attackerSpec = keccak256("attacker/evil-spec");
        address attacker = address(0xBADBAD);
        vm.deal(attacker, 10 ether);
        vm.prank(attacker);
        uint256 taskB = gov.openThought{value: REWARD + OPEN_FEE}(
            attackerSpec, PROMPT_HASH, TASK_EVIDENCE, 5, 3, WINDOW, KNOB_KEY
        );
        for (uint256 i; i < 3; ++i) {
            bytes32 ev = keccak256(abi.encodePacked("b", i));
            // Sign under the ATTACKER's spec (the task's actual spec), not MODEL_SPEC.
            bytes32 digest = gov.verdictDigest(taskB, ops[i].addr, attackerSpec, 1, 1000, ev);
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(ops[i].pk, digest);
            vm.prank(ops[i].addr);
            gov.submitVerdict(taskB, 1, 1000, ev, abi.encodePacked(r, s, v));
        }
        _closeWindow(taskB);
        gov.settle(taskB);

        // The consumer's knob (read under MODEL_SPEC) is UNCHANGED.
        assertEq(gov.getKnob(MODEL_SPEC, KNOB_KEY), legit, "consumer knob NOT hijacked");
        // The attacker's knob lives in its own spec namespace.
        bytes32 attackerKnob = bytes32((uint256(3) << 24) | (uint256(1000) << 8) | uint256(1));
        assertEq(gov.getKnob(attackerSpec, KNOB_KEY), attackerKnob, "attacker knob isolated to its spec");
    }

    // ======================================================================
    // 7. COMPOSITION — ThinkingGate gates/advises a downstream action
    // ======================================================================

    function test_Compose_ThinkingGate_GatesDownstreamAction() public {
        ThinkingGate gate = new ThinkingGate(address(gov));

        uint256 yesTask = _openThought(5, 3);
        assertFalse(gate.isYesQuorum(yesTask), "gate closed before settle");
        vm.expectRevert(abi.encodeWithSelector(ThinkingGate.NoYesQuorum.selector, yesTask));
        gate.requireYes(yesTask);

        for (uint256 i; i < 4; ++i) _submit(yesTask, i, 1, 8000);
        _closeWindow(yesTask); // 4 of 5 in -> window must close to settle
        gov.settle(yesTask);

        assertTrue(gate.isYesQuorum(yesTask), "gate open after YES quorum");
        gate.requireYes(yesTask);

        (bool settled, IThinkingGovernor.Vote vote, uint16 bucket, uint8 agree) = gate.advise(yesTask);
        assertTrue(settled);
        assertEq(uint8(vote), 1);
        assertEq(bucket, 8000);
        assertEq(agree, 4);

        uint256 noTask = _openThought(5, 3);
        for (uint256 i; i < 4; ++i) _submit(noTask, i, 2, 4000);
        _closeWindow(noTask);
        gov.settle(noTask);
        assertFalse(gate.isYesQuorum(noTask), "gate closed on NO quorum");
        vm.expectRevert(abi.encodeWithSelector(ThinkingGate.NoYesQuorum.selector, noTask));
        gate.requireYes(noTask);
    }

    // ======================================================================
    // 8. THE HEADLINE — a DAO parameter set ON-CHAIN by operator-LLM quorum
    // ======================================================================

    /// @notice END-TO-END PROOF of the Thinking Chains governance layer: a governance
    /// knob ("aivm.quorum.threshold") is decided by a QUORUM of bonded operator-LLMs
    /// and recorded ON-CHAIN, visible to the DAO. The full loop:
    ///   1. open a thought whose knobKey is the AIVM quorum-threshold parameter;
    ///   2. 5 bonded operators are registered (setUp); >= threshold (4) submit a YES
    ///      verdict at the SAME confidence bucket via genuine domain-separated sigs;
    ///   3. settle() tallies the consensus key {YES, 8000} and, because it is a YES
    ///      quorum, SETS the governed knob on-chain;
    ///   4. assert ON-CHAIN: getKnob(spec, "aivm.quorum.threshold") returns the decided
    ///      value; getCanonicalVerdict shows (settled, YES, bucket, agree>=threshold);
    ///      the {KnobSet} + {ThoughtSettled} events fired (vm.expectEmit); and the DAO
    ///      KeyValuePairsV1 mirror emitted {ValueUpdated} so the existing DAO subgraph
    ///      indexes "the value the thinking validators decided".
    /// This is "a DAO parameter set by operator-LLM consensus, visible on-chain."
    function test_Headline_KnobSetOnChainByOperatorLLMQuorum() public {
        // --- 1. Open the governance question: should "aivm.quorum.threshold" change? ---
        string memory aivmKnob = "aivm.quorum.threshold";
        uint8 n = 5;
        uint8 threshold = 3; // strict majority of 5

        vm.prank(opener);
        uint256 taskId = gov.openThought{value: REWARD + OPEN_FEE}(
            MODEL_SPEC, PROMPT_HASH, TASK_EVIDENCE, n, threshold, WINDOW, aivmKnob
        );

        // Knob is unset before the validators think.
        assertEq(gov.getKnob(MODEL_SPEC, aivmKnob), bytes32(0), "knob unset before quorum");
        (bool settled0,,,) = gov.getCanonicalVerdict(taskId);
        assertFalse(settled0, "not settled before quorum");

        // --- 2. >= threshold operator-LLMs submit a YES verdict at bucket 8000 ---
        // 4 of 5 agree YES@8000 (one dissents NO@2000), so the agreeing group is 4 >= 3.
        uint8 yesVote = 1; // Vote.Yes
        uint16 bucket = 8000; // 80.00% confidence, on the canonical grid
        uint8 agreeCount = 4;

        address[] memory agreeing = new address[](agreeCount);
        bytes32 expectedRoot;
        for (uint256 i; i < agreeCount; ++i) {
            _submit(taskId, i, yesVote, bucket);
            agreeing[i] = ops[i].addr;
            expectedRoot = keccak256(abi.encodePacked(expectedRoot, _ev(taskId, i)));
        }
        _submit(taskId, 4, 2, 2000); // a dissent, to prove the quorum is a real majority

        // The decided knob value self-describes {vote, bucket, agreeCount} in 32 bytes.
        bytes32 decidedValue = bytes32((uint256(agreeCount) << 24) | (uint256(bucket) << 8) | uint256(yesVote));

        // --- 3. settle() — expect the on-chain KnobSet + ThoughtSettled events ---
        // Emission order in settle(): KnobSet (the governed parameter is set) THEN
        // ThoughtSettled (the canonical decision record). expectEmit queues them in
        // that order; the interleaved RewardAccrued/ValueUpdated are skipped by the
        // matcher and the KVP mirror is asserted separately below.
        vm.expectEmit(true, true, true, true, address(gov));
        emit KnobSet(MODEL_SPEC, aivmKnob, decidedValue, taskId);
        vm.expectEmit(true, true, true, true, address(gov));
        emit ThoughtSettled(taskId, yesVote, bucket, agreeCount, n, expectedRoot, agreeing);

        vm.recordLogs();
        gov.settle(taskId);

        // --- 4a. ON-CHAIN: the governed knob now holds the decided value ---
        assertEq(gov.getKnob(MODEL_SPEC, aivmKnob), decidedValue, "knob set on-chain to the decided value");
        // Decode the self-describing value: a DAO reader gets the full decision from it.
        uint256 kv = uint256(gov.getKnob(MODEL_SPEC, aivmKnob));
        assertEq(uint8(kv), yesVote, "decoded knob vote = YES");
        assertEq(uint16(kv >> 8), bucket, "decoded knob bucket = 8000");
        assertEq(uint8(kv >> 24), agreeCount, "decoded knob agreeCount = 4");

        // --- 4b. ON-CHAIN: the canonical verdict the DAO reads ---
        (bool settled, IThinkingGovernor.Vote vote, uint16 cbucket, uint8 agree) = gov.getCanonicalVerdict(taskId);
        assertTrue(settled, "canonical verdict settled");
        assertEq(uint8(vote), yesVote, "canonical vote = YES");
        assertEq(cbucket, bucket, "canonical bucket = 8000");
        assertEq(agree, agreeCount, "agreeCount = 4");
        assertGe(agree, threshold, "agreeCount >= threshold (a genuine quorum)");

        // --- 4c. ON-CHAIN: the DAO KeyValuePairsV1 mirror fired ValueUpdated so the
        //         existing DAO subgraph surfaces the spec-qualified decision ---
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool sawKnobSet;
        bool sawSettled;
        bool sawKvpMirror;
        bytes32 specHex = keccak256(bytes(_toHex(MODEL_SPEC))); // for value comparison if needed
        specHex; // (kept for clarity; the assertion below is on the event topic/shape)
        for (uint256 i; i < logs.length; ++i) {
            bytes32 t0 = logs[i].topics[0];
            if (t0 == keccak256("KnobSet(bytes32,string,bytes32,uint256)")) {
                sawKnobSet = true;
                assertEq(logs[i].topics[1], MODEL_SPEC, "KnobSet indexed by the governing spec");
                assertEq(uint256(logs[i].topics[2]), taskId, "KnobSet indexed by taskId");
            } else if (t0 == keccak256("ThoughtSettled(uint256,uint8,uint16,uint8,uint8,bytes32,address[])")) {
                sawSettled = true;
                assertEq(uint256(logs[i].topics[1]), taskId, "ThoughtSettled taskId");
                assertEq(uint256(logs[i].topics[2]), yesVote, "ThoughtSettled vote=YES indexed");
            } else if (t0 == keccak256("ValueUpdated(address,string,string)")) {
                // The mirror is emitted BY the KeyValuePairs singleton, with the
                // ThinkingGovernor as the indexed sender.
                sawKvpMirror = true;
                assertEq(address(uint160(uint256(logs[i].topics[1]))), address(gov), "KVP sender = governor");
            }
        }
        assertTrue(sawKnobSet, "KnobSet emitted on-chain");
        assertTrue(sawSettled, "ThoughtSettled emitted on-chain");
        assertTrue(sawKvpMirror, "DAO KeyValuePairs ValueUpdated mirror emitted (subgraph visibility)");

        // A DIFFERENT spec's view of the SAME knobKey is untouched: the decision is
        // bound to MODEL_SPEC, so a consumer reading under another spec sees nothing.
        assertEq(gov.getKnob(keccak256("some.other.spec"), aivmKnob), bytes32(0), "decision scoped to its spec");
    }

    /// @dev "0x"-prefixed lowercase hex of a bytes32 (mirrors the contract's mirror key
    /// derivation; used only for documentation/labels in the headline demo).
    function _toHex(bytes32 value) internal pure returns (string memory) {
        bytes16 sym = "0123456789abcdef";
        bytes memory buf = new bytes(66);
        buf[0] = "0";
        buf[1] = "x";
        for (uint256 i; i < 32; ++i) {
            uint8 b = uint8(value[i]);
            buf[2 + i * 2] = sym[b >> 4];
            buf[3 + i * 2] = sym[b & 0x0f];
        }
        return string(buf);
    }

    // ======================================================================
    // helpers bound to a specific governor instance (for multi-instance tests)
    // ======================================================================

    function _vd(
        ThinkingGovernor g,
        uint256 taskId,
        address operator,
        uint256 pk,
        uint8 vote,
        uint16 bucket,
        bytes32 evidence
    ) internal pure returns (bytes memory) {
        bytes32 digest = g.verdictDigest(taskId, operator, MODEL_SPEC, vote, bucket, evidence);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _closeWindowOn(ThinkingGovernor g, uint256 taskId) internal {
        vm.warp(g.getThought(taskId).deadline + 1);
    }
}
