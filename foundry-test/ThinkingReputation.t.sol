// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {ThinkingReputation} from "../contracts/deployables/thinking/ThinkingReputation.sol";
import {IThinkingGovernor} from "../contracts/deployables/thinking/interfaces/IThinkingGovernor.sol";

/// @dev Governor stand-in exposing only what ThinkingReputation reads:
/// getThought + getVerdicts, stored per taskId so multi-thought EMA can be tested.
contract MockGovernor {
    mapping(uint256 => IThinkingGovernor.Thought) internal _t;
    mapping(uint256 => IThinkingGovernor.Verdict[]) internal _v;

    function setThought(uint256 id, IThinkingGovernor.Thought memory t) external {
        _t[id] = t;
    }

    function addVerdict(uint256 id, address op, IThinkingGovernor.Vote vote, uint16 bucket) external {
        _v[id].push(
            IThinkingGovernor.Verdict({
                operator: op,
                vote: vote,
                confidenceBucket: bucket,
                evidenceHash: bytes32(0),
                submittedAt: 0
            })
        );
    }

    function getThought(uint256 id) external view returns (IThinkingGovernor.Thought memory) {
        return _t[id];
    }

    function getVerdicts(uint256 id) external view returns (IThinkingGovernor.Verdict[] memory) {
        return _v[id];
    }
}

/// @notice Proves Proof-of-AI reputation: agreement with the settled canonical
/// decision raises weight (EMA toward 10000), divergence decays it (toward 0),
/// recording is idempotent, and the ledger enumerates measured validators.
contract ThinkingReputationTest is Test {
    MockGovernor gov;
    ThinkingReputation rep;

    bytes32 constant SPEC = keccak256("zen/thinking-governor/model-spec/v1");
    address constant A1 = address(0xA11CE);
    address constant A2 = address(0xB0B);
    address constant A3 = address(0xC0FFEE);
    address constant DIS = address(0xDEAD); // dissenter
    uint32 constant ALPHA = 2000; // 0.2

    function setUp() public {
        gov = new MockGovernor();
        rep = new ThinkingReputation(IThinkingGovernor(address(gov)), ALPHA);
    }

    // settled thought: canonical = YES @ 8000
    function _settle(uint256 id) internal {
        IThinkingGovernor.Thought memory t;
        t.modelSpecHash = SPEC;
        t.status = IThinkingGovernor.Status.Settled;
        t.canonicalVote = IThinkingGovernor.Vote.Yes;
        t.canonicalBucket = 8000;
        t.n = 4;
        t.threshold = 3;
        gov.setThought(id, t);
    }

    function test_AgreersRise_DissenterStaysZero() public {
        _settle(0);
        gov.addVerdict(0, A1, IThinkingGovernor.Vote.Yes, 8000); // agree
        gov.addVerdict(0, A2, IThinkingGovernor.Vote.Yes, 8000); // agree
        gov.addVerdict(0, DIS, IThinkingGovernor.Vote.No, 6000); // diverge

        rep.recordSettled(0);

        // new validators start at 0; one agree => w = 0 + 0.2*(10000-0) = 2000
        assertEq(rep.weightOf(A1), 2000, "agreer after 1 round");
        assertEq(rep.weightOf(A2), 2000, "agreer after 1 round");
        // dissenter: 0 - 0.2*0 = 0
        assertEq(rep.weightOf(DIS), 0, "dissenter stays 0");
        assertEq(rep.repOf(A1).participated, 1);
        assertEq(rep.repOf(A1).agreed, 1);
        assertEq(rep.repOf(DIS).participated, 1);
        assertEq(rep.repOf(DIS).agreed, 0);
        assertEq(rep.knownCount(), 3, "three validators measured");
    }

    function test_EMA_AccruesOverRounds() public {
        // A1 agrees three times: 2000 -> 3600 -> 4880
        for (uint256 i = 0; i < 3; ++i) {
            _settle(i);
            gov.addVerdict(i, A1, IThinkingGovernor.Vote.Yes, 8000);
            rep.recordSettled(i);
        }
        // round1: 2000; round2: 2000+0.2*(8000)=3600; round3: 3600+0.2*(6400)=4880
        assertEq(rep.weightOf(A1), 4880, "EMA accrual over 3 agreements");
        assertEq(rep.repOf(A1).participated, 3);
        assertEq(rep.repOf(A1).agreed, 3);
        assertEq(rep.agreementRateBps(A1), 10000, "100% agreement rate");
    }

    function test_DivergenceDecaysFromHigh() public {
        // build A1 up over 5 agreements, then diverge once
        for (uint256 i = 0; i < 5; ++i) {
            _settle(i);
            gov.addVerdict(i, A1, IThinkingGovernor.Vote.Yes, 8000);
            rep.recordSettled(i);
        }
        uint32 high = rep.weightOf(A1);
        assertGt(high, 6000, "built up high weight");

        // round 6: diverge (NO@6000 vs canonical YES@8000) -> w - 0.2*w
        _settle(5);
        gov.addVerdict(5, A1, IThinkingGovernor.Vote.No, 6000);
        rep.recordSettled(5);

        uint32 after_ = rep.weightOf(A1);
        assertEq(after_, high - (uint32(ALPHA) * high) / 10000, "decays by alpha*w");
        assertLt(after_, high, "divergence decays weight");
        assertEq(rep.agreementRateBps(A1), uint32((uint256(5) * 10000) / 6), "5/6 agreement");
    }

    function test_WrongBucketCountsAsDivergence() public {
        // right vote, wrong confidence bucket = not the canonical pair = divergence
        _settle(0);
        gov.addVerdict(0, A1, IThinkingGovernor.Vote.Yes, 8000); // exact match
        gov.addVerdict(0, A2, IThinkingGovernor.Vote.Yes, 6000); // right vote, wrong bucket
        rep.recordSettled(0);
        assertEq(rep.weightOf(A1), 2000, "exact match agrees");
        assertEq(rep.weightOf(A2), 0, "off-bucket diverges");
    }

    function test_Idempotent() public {
        _settle(0);
        gov.addVerdict(0, A1, IThinkingGovernor.Vote.Yes, 8000);
        rep.recordSettled(0);
        vm.expectRevert(abi.encodeWithSelector(ThinkingReputation.AlreadyProcessed.selector, uint256(0)));
        rep.recordSettled(0);
    }

    function test_RevertsIfNotSettled() public {
        IThinkingGovernor.Thought memory t;
        t.status = IThinkingGovernor.Status.Open;
        gov.setThought(7, t);
        vm.expectRevert(abi.encodeWithSelector(ThinkingReputation.NotSettled.selector, uint256(7)));
        rep.recordSettled(7);
    }

    function test_WeightNeverExceedsONE_orUnderflows() public {
        // 50 agreements -> approaches but never exceeds 10000
        for (uint256 i = 0; i < 50; ++i) {
            _settle(i);
            gov.addVerdict(i, A1, IThinkingGovernor.Vote.Yes, 8000);
            rep.recordSettled(i);
        }
        assertLe(rep.weightOf(A1), 10000, "never exceeds ONE");
        assertGt(rep.weightOf(A1), 9900, "converges to ONE");
        // then 50 divergences -> approaches but never below 0
        for (uint256 i = 50; i < 100; ++i) {
            _settle(i);
            gov.addVerdict(i, A1, IThinkingGovernor.Vote.No, 6000);
            rep.recordSettled(i);
        }
        assertGe(rep.weightOf(A1), 0, "never underflows");
        assertLt(rep.weightOf(A1), 100, "decays toward 0");
    }

    function test_Enumeration() public {
        _settle(0);
        gov.addVerdict(0, A1, IThinkingGovernor.Vote.Yes, 8000);
        gov.addVerdict(0, A2, IThinkingGovernor.Vote.Yes, 8000);
        gov.addVerdict(0, A3, IThinkingGovernor.Vote.Yes, 8000);
        rep.recordSettled(0);
        assertEq(rep.knownCount(), 3);
        assertEq(rep.knownAt(0), A1);
        assertEq(rep.knownAt(2), A3);
    }
}
