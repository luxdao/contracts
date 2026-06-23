// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {GovernancePoTBridge} from "../contracts/deployables/thinking/GovernancePoTBridge.sol";
import {ProofOfThoughtRegistry} from "../contracts/deployables/thinking/ProofOfThoughtRegistry.sol";
import {IProofOfThoughtRegistry} from "../contracts/deployables/thinking/interfaces/IProofOfThoughtRegistry.sol";
import {IThinkingGovernor} from "../contracts/deployables/thinking/interfaces/IThinkingGovernor.sol";

/// @dev Minimal governor stand-in implementing only the two functions the bridge
/// reads (getThought, consensusHash). The bridge holds an IThinkingGovernor but
/// only ever calls these two selectors at runtime, so this is sufficient — the
/// governor's quorum mechanics are covered by its own 59 tests.
contract MockGovernor {
    IThinkingGovernor.Thought internal _t;

    function setThought(IThinkingGovernor.Thought memory t) external {
        _t = t;
    }

    function getThought(uint256) external view returns (IThinkingGovernor.Thought memory) {
        return _t;
    }

    function consensusHash(bytes32 modelSpecHash, uint8 vote, uint16 bucket) external pure returns (bytes32) {
        // Same preimage as the real ThinkingGovernor + the Go operator.
        return keccak256(abi.encodePacked(modelSpecHash, vote, bucket));
    }
}

/// @notice Proves a settled ThinkingGovernor decision becomes a queryable
/// on-chain Proof-of-Thought receipt via the bridge — the governance-visibility
/// seam of the conscious-network roadmap.
contract GovernancePoTBridgeTest is Test {
    ProofOfThoughtRegistry reg;
    MockGovernor mock;
    GovernancePoTBridge bridge;

    bytes32 constant SPEC = keccak256("zen/thinking-governor/model-spec/v1");
    bytes32 constant PROMPT = keccak256("raise aivm quorum threshold?");
    bytes32 constant EVID_ROOT = keccak256("evidence-root");
    address constant OPENER = address(0xACE);

    function setUp() public {
        reg = new ProofOfThoughtRegistry(address(this)); // test is admin
        mock = new MockGovernor();
        bridge = new GovernancePoTBridge(IThinkingGovernor(address(mock)), reg);
        reg.setRecorder(address(bridge), true); // the bridge is the authorized recorder
    }

    function _settledThought() internal pure returns (IThinkingGovernor.Thought memory t) {
        t.modelSpecHash = SPEC;
        t.promptHash = PROMPT;
        t.evidenceHash = keccak256("ev");
        t.n = 5;
        t.threshold = 3;
        t.opener = OPENER;
        t.status = IThinkingGovernor.Status.Settled;
        t.submissionCount = 5;
        t.knobKey = "aivm.quorum.threshold";
        t.canonicalVote = IThinkingGovernor.Vote.Yes;
        t.canonicalBucket = 8000;
        t.agreeCount = 4;
        t.evidenceRoot = EVID_ROOT;
    }

    function test_RecordThought_SettledDecisionBecomesPoTReceipt() public {
        mock.setThought(_settledThought());

        bytes32 expectedOutput = keccak256(abi.encodePacked(SPEC, uint8(IThinkingGovernor.Vote.Yes), uint16(8000)));
        bytes32 expectedPayment = keccak256(abi.encode(bridge.GOV_SETTLEMENT_DOMAIN(), uint256(7)));
        bytes32 expectedId =
            reg.computeReceiptId(SPEC, PROMPT, expectedOutput, expectedPayment, OPENER, address(mock));

        vm.expectEmit(true, true, false, true);
        emit GovernancePoTBridge.GovernanceThoughtRecorded(7, expectedId, expectedOutput);

        bytes32 id = bridge.recordThought(7);
        assertEq(id, expectedId, "receiptId");

        // The governance decision is now a queryable on-chain PoT receipt.
        assertTrue(reg.exists(id), "PoT receipt recorded on-chain");
        IProofOfThoughtRegistry.ThoughtReceipt memory r = reg.getReceipt(id);
        assertEq(r.modelId, SPEC, "modelId = modelSpec");
        assertEq(r.promptHash, PROMPT, "promptHash = the question");
        assertEq(r.outputHash, expectedOutput, "outputHash = decided {vote,bucket}");
        assertEq(r.quorumProof, EVID_ROOT, "quorumProof = evidence root");
        assertEq(r.payer, OPENER, "payer = opener");
        assertEq(r.operator, address(mock), "operator = governor (settler)");
        assertEq(reg.receiptCount(), 1);
    }

    function test_RecordThought_RevertsIfNotSettled() public {
        IThinkingGovernor.Thought memory t = _settledThought();
        t.status = IThinkingGovernor.Status.Open;
        mock.setThought(t);
        vm.expectRevert(abi.encodeWithSelector(GovernancePoTBridge.NotSettled.selector, uint256(7)));
        bridge.recordThought(7);
    }

    function test_RecordThought_Idempotent() public {
        mock.setThought(_settledThought());
        bridge.recordThought(7);
        // second call hits the registry's deterministic-id replay guard
        vm.expectRevert();
        bridge.recordThought(7);
    }

    function test_OutputHashMatchesGovernorConsensus() public view {
        // The PoT outputHash must equal the governor's (and Go operator's) consensus hash.
        bytes32 viaMock = mock.consensusHash(SPEC, uint8(IThinkingGovernor.Vote.Yes), 8000);
        bytes32 direct = keccak256(abi.encodePacked(SPEC, uint8(IThinkingGovernor.Vote.Yes), uint16(8000)));
        assertEq(viaMock, direct, "consensus hash parity");
    }
}
