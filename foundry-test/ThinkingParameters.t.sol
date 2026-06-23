// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {ThinkingParameters} from "../contracts/deployables/thinking/ThinkingParameters.sol";
import {Sortition} from "../contracts/deployables/thinking/Sortition.sol";
import {IThinkingGovernor} from "../contracts/deployables/thinking/interfaces/IThinkingGovernor.sol";

/// @dev Minimal governor stand-in exposing the eligibility + sortition views
/// ThinkingParameters reads (isOperator, bondOf, minBond, operatorCount,
/// operatorSince). Records registration block so "registered before open" is testable.
contract MockGov {
    mapping(address => bool) public isOperator;
    mapping(address => uint256) public bondOf;
    mapping(address => uint64) public operatorSince;
    uint256 public minBond = 1 ether;
    uint256 public operatorCount;

    function setOperator(address who, bool ok) external {
        if (ok && !isOperator[who]) operatorCount += 1;
        if (!ok && isOperator[who]) operatorCount -= 1;
        isOperator[who] = ok;
        bondOf[who] = ok ? 1 ether : 0;
        if (ok && operatorSince[who] == 0) operatorSince[who] = uint64(block.number);
    }
}

/// @notice Proves value-deciding governance is permissionless-safe: only sortition-
/// sampled operators (registered before open) may propose, the committee is bounded
/// to n, a sunk fee prices each seat, and the median is settled to a live value.
contract ThinkingParametersTest is Test {
    ThinkingParameters params;
    MockGov gov;

    bytes32 constant SPEC = keccak256("zen/thinking-governor/model-spec/v1");
    bytes32 constant PROMPT = keccak256("what should the conservation tithe be, in bps?");
    string constant KNOB = "beluga.conservation.tithe.bps";
    bytes32 constant EV = keccak256("rationale");
    address constant TREASURY = address(0x7EA5);

    uint256[5] PK = [uint256(0xA11CE), 0xB0B, 0xC0FFEE, 0xD00D, 0xE11E];
    address[5] OP;

    function setUp() public {
        vm.warp(1_700_000_000);
        vm.roll(100); // a realistic block height; operators register here, rounds open later
        gov = new MockGov();
        params = new ThinkingParameters(IThinkingGovernor(address(gov)), TREASURY, 0, 0);
        for (uint256 i = 0; i < 5; ++i) {
            OP[i] = vm.addr(PK[i]);
            gov.setOperator(OP[i], true); // registeredAt = 100 (before any round opens)
        }
    }

    // open a round, then advance one block so blockhash(openBlock) (the seed) exists
    function _openRound(uint256 lo, uint256 hi, uint8 n, uint8 threshold) internal returns (uint256 id) {
        id = params.open(SPEC, PROMPT, KNOB, lo, hi, n, threshold, 3600);
        vm.roll(block.number + 1);
    }

    function _propose(uint256 id, uint256 i, uint256 value, uint16 bucket) internal {
        bytes32 digest = params.proposalDigest(id, OP[i], SPEC, value, bucket, EV);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PK[i], digest);
        vm.prank(OP[i]);
        params.submitProposal(id, value, bucket, EV, abi.encodePacked(r, s, v));
    }

    // ---- core: LLM proposes, chain takes the median, value goes live -----------

    function test_MedianOdd_DecidesAndGoesLive() public {
        uint256 id = _openRound(0, 2000, 5, 3); // pop=5, n=5 -> all sampled
        uint256[5] memory vals = [uint256(100), 250, 300, 450, 500];
        for (uint256 i = 0; i < 5; ++i) _propose(id, i, vals[i], 9000);
        vm.warp(block.timestamp + 3601);
        (uint256 value, bool decided) = params.settle(id);
        assertTrue(decided);
        assertEq(value, 300, "median of 5");
        (uint256 live, bool isSet) = params.valueOf(SPEC, KNOB);
        assertEq(live, 300, "live knob value = median");
        assertTrue(isSet);
        assertEq(uint8(params.getRound(id).status), 2, "Settled");
    }

    function test_MedianEven_AveragesCentralPair() public {
        uint256 id = _openRound(0, 2000, 5, 3); // n=5=pop -> all sampled; 4 of them propose
        uint256[4] memory vals = [uint256(100), 200, 300, 500];
        for (uint256 i = 0; i < 4; ++i) _propose(id, i, vals[i], 8000);
        vm.warp(block.timestamp + 3601);
        (uint256 value,) = params.settle(id);
        assertEq(value, 250, "even median = (200+300)/2");
    }

    function test_MedianRobustToAdversarialExtremes() public {
        uint256 id = _openRound(0, 1_000_000, 5, 3);
        _propose(id, 0, 0, 100); //        adversary low
        _propose(id, 1, 480, 9000);
        _propose(id, 2, 500, 9000);
        _propose(id, 3, 520, 9000);
        _propose(id, 4, 1_000_000, 100); // adversary high
        vm.warp(block.timestamp + 3601);
        (uint256 value,) = params.settle(id);
        assertEq(value, 500, "adversarial extremes cannot move the median off the honest center");
    }

    // ---- permissionless committee: sortition + registered-before-open ----------

    /// @notice With population > committee, only sortition-sampled operators may
    /// propose; an unsampled (but bonded) operator is rejected. This is the
    /// permissionless fix: committee share ~ population share.
    function test_Sortition_UnsampledOperatorRejected() public {
        // 40 operators, committee n=5 -> ~5 sampled, most NOT sampled
        uint256 N = 40;
        uint256[] memory pk = new uint256[](N);
        address[] memory op = new address[](N);
        for (uint256 i = 0; i < N; ++i) {
            pk[i] = 1000 + i;
            op[i] = vm.addr(pk[i]);
            gov.setOperator(op[i], true);
        }
        uint256 id = params.open(SPEC, PROMPT, KNOB, 0, 2000, 5, 3, 3600);
        vm.roll(block.number + 1);
        bytes32 seed = blockhash(uint256(block.number - 1)); // == blockhash(openBlock)

        // find a sampled op (to cache the seed) and an unsampled op
        int256 sampled = -1;
        int256 unsampled = -1;
        for (uint256 i = 0; i < N; ++i) {
            if (Sortition.isSelected(seed, op[i], 45, 5)) {
                if (sampled < 0) sampled = int256(i);
            } else if (unsampled < 0) {
                unsampled = int256(i);
            }
        }
        assertTrue(sampled >= 0 && unsampled >= 0, "need one sampled and one unsampled");

        // sampled op proposes (caches the seed + passes sortition)
        uint256 si = uint256(sampled);
        bytes32 d1 = params.proposalDigest(id, op[si], SPEC, 1000, 9000, EV);
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(pk[si], d1);
        vm.prank(op[si]);
        params.submitProposal(id, 1000, 9000, EV, abi.encodePacked(r1, s1, v1));

        // unsampled op is rejected even though bonded + valid signature
        uint256 ui = uint256(unsampled);
        bytes32 d2 = params.proposalDigest(id, op[ui], SPEC, 1000, 9000, EV);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(pk[ui], d2);
        vm.prank(op[ui]);
        vm.expectRevert(abi.encodeWithSelector(ThinkingParameters.NotSampled.selector, op[ui]));
        params.submitProposal(id, 1000, 9000, EV, abi.encodePacked(r2, s2, v2));
    }

    /// @notice An operator registered AFTER a round opened cannot join its committee
    /// (so an attacker cannot register fresh identities once the seed is known).
    function test_NotRegisteredBeforeOpen_Rejected() public {
        uint256 id = _openRound(0, 2000, 5, 3);
        uint256 latePk = 0xFADE;
        address late = vm.addr(latePk);
        gov.setOperator(late, true); // registers AFTER open (block > openBlock)
        bytes32 d = params.proposalDigest(id, late, SPEC, 100, 9000, EV);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(latePk, d);
        vm.prank(late);
        vm.expectRevert(abi.encodeWithSelector(ThinkingParameters.NotRegisteredBeforeOpen.selector, late));
        params.submitProposal(id, 100, 9000, EV, abi.encodePacked(r, s, v));
    }

    // (The n-cap `submissionCount >= n -> CommitteeFull` guard is a backstop for a
    // sortition overshoot; the full-committee path submissionCount==n is exercised
    // by test_SettleGatedUntilDeadlineUnlessFull below.)

    // ---- sunk cost + anti-spam -------------------------------------------------

    function test_SunkFees_RoutedToTreasury() public {
        ThinkingParameters pf = new ThinkingParameters(IThinkingGovernor(address(gov)), TREASURY, 0.01 ether, 0.02 ether);
        uint256 id = pf.open{value: 0.01 ether}(SPEC, PROMPT, KNOB, 0, 2000, 5, 3, 3600);
        vm.roll(block.number + 1);
        // wrong fee rejected
        bytes32 d = pf.proposalDigest(id, OP[0], SPEC, 100, 9000, EV);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PK[0], d);
        vm.prank(OP[0]);
        vm.expectRevert(abi.encodeWithSelector(ThinkingParameters.WrongFee.selector, uint256(0), uint256(0.02 ether)));
        pf.submitProposal(id, 100, 9000, EV, abi.encodePacked(r, s, v));
        // correct fee accrues, sunk to treasury
        vm.deal(OP[0], 1 ether);
        vm.prank(OP[0]);
        pf.submitProposal{value: 0.02 ether}(id, 100, 9000, EV, abi.encodePacked(r, s, v));
        assertEq(pf.treasuryFees(), 0.01 ether + 0.02 ether, "open + proposal fee accrued");
        uint256 before = TREASURY.balance;
        pf.withdrawFees();
        assertEq(TREASURY.balance - before, 0.03 ether, "fees swept to treasury");
    }

    function test_WindowTooShort_Rejected() public {
        vm.expectRevert(abi.encodeWithSelector(ThinkingParameters.WindowTooShort.selector, uint64(60)));
        params.open(SPEC, PROMPT, KNOB, 0, 2000, 5, 3, 60); // < MIN_WINDOW (1h)
    }

    function test_SeedNotReady_SameBlockAsOpen() public {
        uint256 id = params.open(SPEC, PROMPT, KNOB, 0, 2000, 5, 3, 3600); // no roll
        bytes32 d = params.proposalDigest(id, OP[0], SPEC, 100, 9000, EV);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PK[0], d);
        vm.prank(OP[0]);
        vm.expectRevert(abi.encodeWithSelector(ThinkingParameters.SeedNotReady.selector, id));
        params.submitProposal(id, 100, 9000, EV, abi.encodePacked(r, s, v));
    }

    // ---- safety: gating, range, replay, quorum --------------------------------

    function test_OnlyEligibleOperatorMayPropose() public {
        uint256 id = _openRound(0, 2000, 5, 3);
        uint256 strangerPk = 0xBADBAD;
        address stranger = vm.addr(strangerPk);
        bytes32 d = params.proposalDigest(id, stranger, SPEC, 100, 9000, EV);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(strangerPk, d);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ThinkingParameters.NotEligibleOperator.selector, stranger));
        params.submitProposal(id, 100, 9000, EV, abi.encodePacked(r, s, v));
    }

    function test_ValueOutOfRangeReverts() public {
        uint256 id = _openRound(100, 200, 5, 3);
        bytes32 d = params.proposalDigest(id, OP[0], SPEC, 201, 9000, EV);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PK[0], d);
        vm.prank(OP[0]);
        vm.expectRevert(abi.encodeWithSelector(ThinkingParameters.ValueOutOfRange.selector, uint256(201), uint256(100), uint256(200)));
        params.submitProposal(id, 201, 9000, EV, abi.encodePacked(r, s, v));
    }

    function test_DoubleProposeReverts() public {
        uint256 id = _openRound(0, 2000, 5, 3);
        _propose(id, 0, 100, 9000);
        bytes32 d = params.proposalDigest(id, OP[0], SPEC, 150, 9000, EV);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PK[0], d);
        vm.prank(OP[0]);
        vm.expectRevert(abi.encodeWithSelector(ThinkingParameters.AlreadyProposed.selector, id, OP[0]));
        params.submitProposal(id, 150, 9000, EV, abi.encodePacked(r, s, v));
    }

    function test_SignerMismatchReverts() public {
        uint256 id = _openRound(0, 2000, 5, 3);
        // OP[0] signs a proposal bound to OP[0]; OP[1] tries to RELAY it (msg.sender=OP[1]).
        // The contract recomputes the digest bound to msg.sender (OP[1]), so recover
        // over OP[0]'s signature yields an address != OP[1] -> SignerMismatch.
        bytes32 d = params.proposalDigest(id, OP[0], SPEC, 100, 9000, EV);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PK[0], d);
        vm.prank(OP[1]);
        vm.expectRevert();
        params.submitProposal(id, 100, 9000, EV, abi.encodePacked(r, s, v));
    }

    function test_DigestBindsChainIdAndAddress() public view {
        bytes32 got = params.proposalDigest(7, OP[0], SPEC, 1234, 9000, EV);
        bytes32 want = keccak256(
            abi.encodePacked(
                params.PROPOSAL_DOMAIN(), block.chainid, address(params), uint256(7), SPEC, uint256(1234), uint16(9000), EV, OP[0]
            )
        );
        assertEq(got, want, "digest must bind chainId + address(this)");
    }

    function test_QuorumFail_NoValueSet() public {
        uint256 id = _openRound(0, 2000, 5, 3);
        _propose(id, 0, 100, 9000);
        _propose(id, 1, 200, 9000); // 2 < threshold 3
        vm.warp(block.timestamp + 3601);
        (uint256 value, bool decided) = params.settle(id);
        assertFalse(decided);
        assertEq(value, 0);
        (, bool isSet) = params.valueOf(SPEC, KNOB);
        assertFalse(isSet);
        assertEq(uint8(params.getRound(id).status), 3, "Failed");
    }

    function test_SettleGatedUntilDeadlineUnlessFull() public {
        uint256 id = _openRound(0, 2000, 5, 3);
        _propose(id, 0, 100, 9000);
        _propose(id, 1, 300, 9000);
        _propose(id, 2, 500, 9000); // 3 of 5 before deadline -> gated
        vm.expectRevert(abi.encodeWithSelector(ThinkingParameters.VotingOpen.selector, id));
        params.settle(id);
        _propose(id, 3, 700, 9000);
        _propose(id, 4, 900, 9000); // full committee -> settle allowed
        (uint256 value, bool decided) = params.settle(id);
        assertTrue(decided);
        assertEq(value, 500, "median of full committee");
    }

    function test_BadRangeAndCommitteeReverts() public {
        vm.expectRevert(abi.encodeWithSelector(ThinkingParameters.BadRange.selector, uint256(10), uint256(5)));
        params.open(SPEC, PROMPT, KNOB, 10, 5, 5, 3, 3600);
        vm.expectRevert(abi.encodeWithSelector(ThinkingParameters.BadCommittee.selector, uint8(5), uint8(2)));
        params.open(SPEC, PROMPT, KNOB, 0, 100, 5, 2, 3600);
    }
}
