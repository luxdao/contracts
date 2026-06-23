// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {ThinkingParameters} from "../contracts/deployables/thinking/ThinkingParameters.sol";
import {IThinkingGovernor} from "../contracts/deployables/thinking/interfaces/IThinkingGovernor.sol";

/// @dev Minimal governor stand-in exposing only the eligibility views
/// ThinkingParameters reads (isOperator, bondOf, minBond). The real governor's
/// bonding mechanics are covered by its own suite; here we only need a controllable
/// eligible-operator set.
contract MockGov {
    mapping(address => bool) public isOperator;
    mapping(address => uint256) public bondOf;
    uint256 public minBond = 1 ether;

    function setOperator(address who, bool ok) external {
        isOperator[who] = ok;
        bondOf[who] = ok ? 1 ether : 0;
    }
}

/// @notice Proves value-deciding governance: operators' LLMs propose numbers, the
/// chain settles to the Byzantine-robust median, and the decided value goes live.
contract ThinkingParametersTest is Test {
    ThinkingParameters params;
    MockGov gov;

    bytes32 constant SPEC = keccak256("zen/thinking-governor/model-spec/v1");
    bytes32 constant PROMPT = keccak256("what should the conservation tithe be, in bps?");
    string constant KNOB = "beluga.conservation.tithe.bps";
    bytes32 constant EV = keccak256("rationale");

    // 5 operators with deterministic keys
    uint256[5] PK = [uint256(0xA11CE), 0xB0B, 0xC0FFEE, 0xD00D, 0xE11E];
    address[5] OP;

    function setUp() public {
        vm.warp(1_700_000_000);
        gov = new MockGov();
        params = new ThinkingParameters(IThinkingGovernor(address(gov)));
        for (uint256 i = 0; i < 5; ++i) {
            OP[i] = vm.addr(PK[i]);
            gov.setOperator(OP[i], true);
        }
    }

    function _open(uint256 lo, uint256 hi, uint8 n, uint8 threshold) internal returns (uint256 id) {
        id = params.open(SPEC, PROMPT, KNOB, lo, hi, n, threshold, 3600);
    }

    function _propose(uint256 id, uint256 i, uint256 value, uint16 bucket) internal {
        bytes32 digest = params.proposalDigest(id, OP[i], SPEC, value, bucket, EV);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PK[i], digest);
        vm.prank(OP[i]);
        params.submitProposal(id, value, bucket, EV, abi.encodePacked(r, s, v));
    }

    // ---- the core: the LLM decides the value, the chain takes the median -------

    function test_MedianOdd_DecidesAndGoesLive() public {
        uint256 id = _open(0, 2000, 5, 3);
        uint256[5] memory vals = [uint256(100), 250, 300, 450, 500];
        for (uint256 i = 0; i < 5; ++i) _propose(id, i, vals[i], 9000);

        vm.warp(block.timestamp + 3601);
        (uint256 value, bool decided) = params.settle(id);
        assertTrue(decided, "settled");
        assertEq(value, 300, "median of 5");

        // loop closes: the decided value is live and readable
        (uint256 live, bool isSet) = params.valueOf(SPEC, KNOB);
        assertEq(live, 300, "live knob value = median");
        assertTrue(isSet, "value decided flag");
        assertEq(uint8(params.getRound(id).status), 2, "Settled");
    }

    function test_MedianEven_AveragesCentralPair() public {
        uint256 id = _open(0, 2000, 4, 3);
        uint256[4] memory vals = [uint256(100), 200, 300, 500];
        for (uint256 i = 0; i < 4; ++i) _propose(id, i, vals[i], 8000);
        vm.warp(block.timestamp + 3601);
        (uint256 value,) = params.settle(id);
        assertEq(value, 250, "even median = (200+300)/2");
    }

    /// @notice The median is Byzantine-robust: a minority proposing extreme values
    /// cannot move the decided value beyond the honest center.
    function test_MedianRobustToAdversarialExtremes() public {
        uint256 id = _open(0, 1_000_000, 5, 3);
        // 3 honest cluster around 500; 2 adversaries at the range extremes
        _propose(id, 0, 0, 100); //        adversary low
        _propose(id, 1, 480, 9000); //     honest
        _propose(id, 2, 500, 9000); //     honest
        _propose(id, 3, 520, 9000); //     honest
        _propose(id, 4, 1_000_000, 100); // adversary high
        vm.warp(block.timestamp + 3601);
        (uint256 value,) = params.settle(id);
        assertEq(value, 500, "adversarial extremes cannot move the median off the honest center");
    }

    // ---- gating + safety -------------------------------------------------------

    function test_OnlyEligibleOperatorMayPropose() public {
        uint256 id = _open(0, 2000, 5, 3);
        uint256 strangerPk = 0xBADBAD;
        address stranger = vm.addr(strangerPk);
        bytes32 digest = params.proposalDigest(id, stranger, SPEC, 100, 9000, EV);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(strangerPk, digest);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ThinkingParameters.NotEligibleOperator.selector, stranger));
        params.submitProposal(id, 100, 9000, EV, abi.encodePacked(r, s, v));
    }

    function test_ValueOutOfRangeReverts() public {
        uint256 id = _open(100, 200, 5, 3);
        bytes32 digest = params.proposalDigest(id, OP[0], SPEC, 201, 9000, EV);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PK[0], digest);
        vm.prank(OP[0]);
        vm.expectRevert(abi.encodeWithSelector(ThinkingParameters.ValueOutOfRange.selector, uint256(201), uint256(100), uint256(200)));
        params.submitProposal(id, 201, 9000, EV, abi.encodePacked(r, s, v));
    }

    function test_DoubleProposeReverts() public {
        uint256 id = _open(0, 2000, 5, 3);
        _propose(id, 0, 100, 9000);
        bytes32 digest = params.proposalDigest(id, OP[0], SPEC, 150, 9000, EV);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PK[0], digest);
        vm.prank(OP[0]);
        vm.expectRevert(abi.encodeWithSelector(ThinkingParameters.AlreadyProposed.selector, id, OP[0]));
        params.submitProposal(id, 150, 9000, EV, abi.encodePacked(r, s, v));
    }

    function test_SignerMismatchReverts() public {
        uint256 id = _open(0, 2000, 5, 3);
        // OP[1] signs but OP[0] submits
        bytes32 digest = params.proposalDigest(id, OP[0], SPEC, 100, 9000, EV);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PK[1], digest);
        vm.prank(OP[0]);
        vm.expectRevert();
        params.submitProposal(id, 100, 9000, EV, abi.encodePacked(r, s, v));
    }

    /// @notice The digest binds chainId + this contract (no cross-chain/instance replay).
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
        uint256 id = _open(0, 2000, 5, 3);
        _propose(id, 0, 100, 9000);
        _propose(id, 1, 200, 9000); // only 2 < threshold 3
        vm.warp(block.timestamp + 3601);
        (uint256 value, bool decided) = params.settle(id);
        assertFalse(decided, "failed quorum");
        assertEq(value, 0);
        (, bool isSet) = params.valueOf(SPEC, KNOB);
        assertFalse(isSet, "no live value on failed round");
        assertEq(uint8(params.getRound(id).status), 3, "Failed");
    }

    function test_SettleGatedUntilDeadlineUnlessFull() public {
        uint256 id = _open(0, 2000, 5, 3);
        _propose(id, 0, 100, 9000);
        _propose(id, 1, 300, 9000);
        _propose(id, 2, 500, 9000); // 3 of 5, before deadline -> not full, gated
        vm.expectRevert(abi.encodeWithSelector(ThinkingParameters.VotingOpen.selector, id));
        params.settle(id);
        // fill the committee -> settle allowed before deadline
        _propose(id, 3, 700, 9000);
        _propose(id, 4, 900, 9000);
        (uint256 value, bool decided) = params.settle(id);
        assertTrue(decided);
        assertEq(value, 500, "median of full committee");
    }

    function test_BadRangeAndCommitteeReverts() public {
        vm.expectRevert(abi.encodeWithSelector(ThinkingParameters.BadRange.selector, uint256(10), uint256(5)));
        params.open(SPEC, PROMPT, KNOB, 10, 5, 5, 3, 3600);
        vm.expectRevert(abi.encodeWithSelector(ThinkingParameters.BadCommittee.selector, uint8(5), uint8(2)));
        params.open(SPEC, PROMPT, KNOB, 0, 100, 5, 2, 3600); // threshold < n/2+1
    }
}
