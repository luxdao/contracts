// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {AIExecute, IConsensusApproval} from "@luxfi/standard/ai/thinking/AIExecute.sol";
import {AIApproval} from "@luxfi/standard/ai/thinking/AIApproval.sol";
import {ThinkingGovernor} from "@luxfi/standard/ai/thinking/ThinkingGovernor.sol";
import {ThinkingParameters} from "@luxfi/standard/ai/thinking/ThinkingParameters.sol";
import {IThinkingGovernor} from "@luxfi/standard/ai/thinking/interfaces/IThinkingGovernor.sol";
import {KeyValuePairsV1} from "@luxfi/standard/dao/singletons/KeyValuePairsV1.sol";

/// The arbitrary target consensus governs: a multi-arg method callable only by AIExecute.
contract GovernedTarget {
    address public gov;
    uint256 public a;
    address public b;
    bool public c;

    constructor(address g) {
        gov = g;
    }

    function complexUpdate(uint256 a_, address b_, bool c_) external returns (uint256) {
        require(msg.sender == gov, "not gov");
        (a, b, c) = (a_, b_, c_);
        return a_ + 1;
    }
}

/// Proves the REAL Proof-of-AI governance→execution stack on a live node, with GENUINE operator
/// signatures and NO stand-in approval stub. Stage 1 (this script): deploy the real ThinkingGovernor +
/// ThinkingParameters + AIExecute + AIApproval + target, register a real operator committee, open a
/// Thought whose promptHash IS the AIExecute operation hash, and submit genuine signed YES verdicts.
/// Stage 2 (driver, after the real voting window elapses on-chain): settle → confirm → execute.
///
/// The committee uses anvil's deterministic prefunded accounts as real, independently-keyed operators.
contract ProvePoAILive is Script {
    bytes32 constant SPEC = keccak256("zen/thinking-governor/model-spec/v1");
    string constant KNOB = "execute.op";
    uint256 constant MIN_BOND = 1 ether;
    uint64 constant COOLDOWN = 7 days;
    uint256 constant REWARD = 0.5 ether;
    uint256 constant OPEN_FEE = 0.1 ether;
    uint64 constant WINDOW = 1 hours; // == MIN_VOTING_WINDOW
    address constant TREASURY = address(0x7EA5);

    function run() external {
        // anvil deterministic keys: #0 deployer, #1..#3 the operator committee.
        uint256 d = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        uint256[3] memory ops = [
            uint256(0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d),
            uint256(0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a),
            uint256(0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6)
        ];

        // ---- deploy the real stack (deployer) ----
        vm.startBroadcast(d);
        KeyValuePairsV1 kvp = new KeyValuePairsV1();
        ThinkingGovernor gov = new ThinkingGovernor(MIN_BOND, COOLDOWN, REWARD, OPEN_FEE, TREASURY, address(kvp));
        ThinkingParameters params = new ThinkingParameters(IThinkingGovernor(address(gov)), TREASURY, 0, 0);
        AIApproval approval = new AIApproval(IThinkingGovernor(address(gov)));
        AIExecute exec = new AIExecute(address(params), address(approval), 0, vm.addr(d));
        GovernedTarget target = new GovernedTarget(address(exec));
        vm.stopBroadcast();

        // ---- the operation consensus will authorize: an arbitrary multi-arg call ----
        AIExecute.Operation memory op = AIExecute.Operation({
            target: address(target),
            value: 0,
            data: abi.encodeWithSelector(GovernedTarget.complexUpdate.selector, uint256(42), address(0xBEEF), true),
            predecessor: bytes32(0),
            salt: bytes32("poai-live"),
            earliestExecTime: 0,
            expiryTime: 0
        });
        bytes32 opHash = exec.hashOperation(op);

        // ---- register the operator committee (each a distinct real key) ----
        for (uint256 i; i < 3; i++) {
            vm.startBroadcast(ops[i]);
            gov.registerOperator{value: MIN_BOND}();
            vm.stopBroadcast();
        }

        // ---- open the Thought: promptHash = opHash (the question IS "execute this op?") ----
        vm.startBroadcast(d);
        uint256 taskId =
            gov.openThought{value: REWARD + OPEN_FEE}(SPEC, opHash, keccak256("evidence"), 3, 2, WINDOW, KNOB);
        vm.stopBroadcast();

        // ---- genuine signed YES verdicts from each operator ----
        for (uint256 i; i < 3; i++) {
            address opAddr = vm.addr(ops[i]);
            bytes32 ev = keccak256(abi.encodePacked("ev", i));
            bytes32 digest = gov.verdictDigest(taskId, opAddr, SPEC, 1 /*Yes*/, 8000 /*80%*/, ev);
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(ops[i], digest);
            vm.startBroadcast(ops[i]);
            gov.submitVerdict(taskId, 1, 8000, ev, abi.encodePacked(r, s, v));
            vm.stopBroadcast();
        }

        console.log("GOV      ", address(gov));
        console.log("APPROVAL ", address(approval));
        console.log("EXEC     ", address(exec));
        console.log("TARGET   ", address(target));
        console.log("TASKID   ", taskId);
        console.logBytes32(opHash);
        console.log("deadline ", gov.getThought(taskId).deadline);
    }
}
