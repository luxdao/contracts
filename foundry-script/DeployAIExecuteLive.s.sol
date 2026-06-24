// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {AIExecute, IThinkingValue, IConsensusApproval} from "../contracts/deployables/thinking/AIExecute.sol";

/// Live stand-in for the thinking-quorum's op-approval surface. In production the ThinkingGovernor
/// writes an opHash here when validators settle YES; here the deployer approves so we can prove the
/// arbitrary-execution path end-to-end on a real chain.
contract LiveApprovals is IConsensusApproval {
    address public owner;
    mapping(bytes32 => uint64) public at;

    constructor() {
        owner = msg.sender;
    }

    function approve(bytes32 id) external {
        require(msg.sender == owner, "not owner");
        at[id] = uint64(block.timestamp);
    }

    function approved(bytes32 id) external view returns (bool, uint64) {
        return (at[id] != 0, at[id]);
    }
}

/// Live stand-in for AIParams: a knob's decided value.
contract LiveParams is IThinkingValue {
    mapping(bytes32 => mapping(bytes32 => uint256)) v;
    mapping(bytes32 => mapping(bytes32 => bool)) d;

    function set(bytes32 s, string calldata k, uint256 x) external {
        v[s][keccak256(bytes(k))] = x;
        d[s][keccak256(bytes(k))] = true;
    }

    function valueOf(bytes32 s, string calldata k) external view returns (uint256, bool) {
        bytes32 key = keccak256(bytes(k));
        return (v[s][key], d[s][key]);
    }
}

/// A governed contract: a simple knob (Tier 1) and an arbitrary multi-arg method (Tier 3).
contract LiveTarget {
    address public gov;
    uint256 public limit;
    uint256 public a;
    address public b;
    bool public d;

    constructor(address g) {
        gov = g;
    }

    modifier onlyGov() {
        require(msg.sender == gov, "not gov");
        _;
    }

    function setLimit(uint256 x) external onlyGov {
        limit = x;
    }

    function complexUpdate(uint256 a_, address b_, bool d_) external onlyGov returns (uint256) {
        (a, b, d) = (a_, b_, d_);
        return a_ + 1;
    }
}

/// Deploys AIExecute live and drives BOTH tiers through it on-chain: a decided knob is enacted, and an
/// arbitrary approved operation is executed. minDelay = 0 so the demo needs no wall-clock wait (the
/// window mechanics are proven under vm.warp in the test suite).
contract DeployAIExecuteLive is Script {
    bytes32 constant SPEC = bytes32("zen-coder-flash");

    function run() external {
        uint256 pk = vm.envUint("PRIVKEY");
        address me = vm.addr(pk);

        vm.startBroadcast(pk);
        LiveApprovals approvals = new LiveApprovals();
        LiveParams params = new LiveParams();
        AIExecute exec = new AIExecute(address(params), address(approvals), 0, me);
        LiveTarget target = new LiveTarget(address(exec));

        // Tier 1 — enact a validator-DECIDED knob (no timelock).
        params.set(SPEC, "tithe_bps", 1500);
        exec.enact(SPEC, "tithe_bps", address(target), target.setLimit.selector);

        // Tier 3 — approve and execute an ARBITRARY multi-arg operation.
        AIExecute.Operation memory op = AIExecute.Operation({
            target: address(target),
            value: 0,
            data: abi.encodeWithSelector(LiveTarget.complexUpdate.selector, uint256(42), address(0xBEEF), true),
            predecessor: bytes32(0),
            salt: bytes32("live"),
            earliestExecTime: 0,
            expiryTime: 0
        });
        bytes32 id = exec.hashOperation(op);
        approvals.approve(id);
        bytes memory ret = exec.execute(op);
        vm.stopBroadcast();

        console.log("AIExecute:      ", address(exec));
        console.log("LiveTarget:     ", address(target));
        console.log("Tier1 limit:    ", target.limit()); // expect 1500
        console.log("Tier3 a:        ", target.a()); // expect 42
        console.log("Tier3 b:        ", target.b()); // expect 0xBEEF
        console.log("Tier3 d:        ", target.d()); // expect true
        console.log("Tier3 return:   ", abi.decode(ret, (uint256))); // expect 43
        console.log("op executed:    ", exec.executed(id)); // expect true
    }
}
