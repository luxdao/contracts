// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {AIExecute, IThinkingValue, IConsensusApproval} from "../contracts/deployables/thinking/AIExecute.sol";
import {AIPolicy} from "../contracts/deployables/thinking/AIPolicy.sol";

contract MockApproval is IConsensusApproval {
    mapping(bytes32 => uint64) public at;

    function approve(bytes32 id, uint64 when) external {
        at[id] = when;
    }

    function approved(bytes32 id) external view returns (bool, uint64) {
        return (at[id] != 0, at[id]);
    }
}

contract NoParams is IThinkingValue {
    function valueOf(bytes32, string calldata) external pure returns (uint256, bool) {
        return (0, false);
    }
}

contract Sink {
    address public gov;
    uint256 public ping;

    constructor(address g) {
        gov = g;
    }

    function poke() external {
        require(msg.sender == gov, "not gov");
        ping++;
    }

    function take() external payable {
        require(msg.sender == gov, "not gov");
    }
}

/// AIPolicy is the second wall: even an approved op must fit the envelope a deployment configured.
contract AIPolicyTest is Test {
    MockApproval approvals;
    AIExecute exec;
    AIPolicy policy;
    Sink sink;

    address guardian = address(this); // test acts as guardian/admin
    uint64 constant MIN_DELAY = 1 days;
    uint64 constant T0 = 1_700_000_000;

    function setUp() public {
        vm.warp(T0);
        approvals = new MockApproval();
        exec = new AIExecute(address(new NoParams()), address(approvals), MIN_DELAY, guardian);
        policy = new AIPolicy(address(exec), address(this));
        exec.setGuard(policy); // guardian (this) plugs the guard
        sink = new Sink(address(exec));
    }

    function _poke() internal view returns (AIExecute.Operation memory) {
        return AIExecute.Operation({
            target: address(sink),
            value: 0,
            data: abi.encodeWithSelector(Sink.poke.selector),
            predecessor: bytes32(0),
            salt: bytes32("p"),
            earliestExecTime: 0,
            expiryTime: 0
        });
    }

    function _approveAndWarp(AIExecute.Operation memory op) internal {
        approvals.approve(exec.hashOperation(op), T0);
        vm.warp(T0 + MIN_DELAY + 1);
    }

    // baseline: guardless-equivalent (no allowlists, maxValue 0, no gap) lets a value-0 op through.
    function test_PermissiveByDefault() public {
        AIExecute.Operation memory op = _poke();
        _approveAndWarp(op);
        exec.execute(op);
        assertEq(sink.ping(), 1);
    }

    function test_TargetAllowlist_Blocks() public {
        policy.setAllowlists(true, false); // only allowed targets
        AIExecute.Operation memory op = _poke();
        _approveAndWarp(op);
        vm.expectRevert(abi.encodeWithSelector(AIPolicy.TargetNotAllowed.selector, address(sink)));
        exec.execute(op);
        // allow it → passes
        policy.setTargetAllowed(address(sink), true);
        exec.execute(op);
        assertEq(sink.ping(), 1);
    }

    function test_SelectorAllowlist_Blocks() public {
        policy.setAllowlists(false, true); // only allowed selectors
        AIExecute.Operation memory op = _poke();
        _approveAndWarp(op);
        vm.expectRevert(
            abi.encodeWithSelector(AIPolicy.SelectorNotAllowed.selector, address(sink), Sink.poke.selector)
        );
        exec.execute(op);
        policy.setSelectorAllowed(address(sink), Sink.poke.selector, true);
        exec.execute(op);
        assertEq(sink.ping(), 1);
    }

    function test_MaxValue_Blocks() public {
        AIExecute.Operation memory op = AIExecute.Operation({
            target: address(sink),
            value: 1 ether,
            data: abi.encodeWithSelector(Sink.take.selector),
            predecessor: bytes32(0),
            salt: bytes32("v"),
            earliestExecTime: 0,
            expiryTime: 0
        });
        _approveAndWarp(op);
        vm.deal(address(this), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(AIPolicy.ValueTooHigh.selector, 1 ether, 0));
        exec.execute{value: 1 ether}(op); // default maxValue 0 blocks native value
        policy.setMaxValue(1 ether);
        exec.execute{value: 1 ether}(op); // now within cap
        assertEq(address(sink).balance, 1 ether);
    }

    function test_RateLimit_Blocks() public {
        policy.setMinGap(address(sink), 1 hours);
        // first op passes and stamps lastCall
        AIExecute.Operation memory op1 = _poke();
        _approveAndWarp(op1);
        exec.execute(op1);
        assertEq(sink.ping(), 1);
        // a second op to the same target within the gap is rate-limited
        AIExecute.Operation memory op2 = _poke();
        op2.salt = bytes32("p2");
        approvals.approve(exec.hashOperation(op2), uint64(block.timestamp));
        vm.warp(block.timestamp + MIN_DELAY + 1); // satisfies the execution floor...
        // ...but only ~1 day passed since lastCall < required? 1 day > 1 hour, so it WOULD pass.
        // Tighten: set a large gap to force the limit.
        policy.setMinGap(address(sink), 30 days);
        uint64 next = sink_lastCall() + 30 days;
        vm.expectRevert(abi.encodeWithSelector(AIPolicy.RateLimited.selector, address(sink), next));
        exec.execute(op2);
    }

    function sink_lastCall() internal view returns (uint64) {
        return policy.lastCall(address(sink));
    }

    function test_Check_OnlyExecutor() public {
        vm.expectRevert(AIPolicy.NotExecutor.selector);
        policy.check(address(sink), 0, abi.encodeWithSelector(Sink.poke.selector));
    }

    function test_Admin_OnlyAdmin() public {
        vm.prank(address(0xdead));
        vm.expectRevert(AIPolicy.NotAdmin.selector);
        policy.setMaxValue(5);
    }

    receive() external payable {}
}
