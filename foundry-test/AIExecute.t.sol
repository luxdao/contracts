// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {AIExecute, IThinkingValue, IConsensusApproval, IGuard} from
    "../contracts/deployables/thinking/AIExecute.sol";
import {AIPolicy} from "../contracts/deployables/thinking/AIPolicy.sol";

/// Stand-in for AIParams/ThinkingParameters: a knob's validator-decided value.
contract MockParams is IThinkingValue {
    mapping(bytes32 => mapping(bytes32 => uint256)) value;
    mapping(bytes32 => mapping(bytes32 => bool)) decided;

    function set(bytes32 spec, string calldata key, uint256 v) external {
        bytes32 k = keccak256(bytes(key));
        value[spec][k] = v;
        decided[spec][k] = true;
    }

    function valueOf(bytes32 spec, string calldata key) external view returns (uint256, bool) {
        bytes32 k = keccak256(bytes(key));
        return (value[spec][k], decided[spec][k]);
    }
}

/// Stand-in for the thinking-quorum's op approvals: an op id is approved when validators settle YES.
contract MockApproval is IConsensusApproval {
    mapping(bytes32 => uint64) public at; // 0 = not approved

    function approve(bytes32 id, uint64 when) external {
        at[id] = when;
    }

    function approved(bytes32 id) external view returns (bool, uint64) {
        return (at[id] != 0, at[id]);
    }
}

/// A governed target with both a simple knob setter (Tier 1) and an ARBITRARY multi-arg method (Tier 3),
/// each callable only by the executor.
contract Target {
    address public gov;
    bool public flag;
    uint256 public limit;
    int256 public rate;
    // arbitrary multi-arg state
    uint256 public a;
    address public b;
    bytes32 public c;
    bool public d;

    constructor(address g) {
        gov = g;
    }

    modifier onlyGov() {
        require(msg.sender == gov, "not gov");
        _;
    }

    function setFlag(bool v) external onlyGov {
        flag = v;
    }

    function setLimit(uint256 v) external onlyGov {
        limit = v;
    }

    function setRate(int256 v) external onlyGov {
        rate = v;
    }

    function complexUpdate(uint256 a_, address b_, bytes32 c_, bool d_) external onlyGov returns (uint256) {
        (a, b, c, d) = (a_, b_, c_, d_);
        return a_ + 1; // a structured return flows back through execute()
    }
}

contract AIExecuteTest is Test {
    MockParams params;
    MockApproval approvals;
    AIExecute exec;
    Target target;

    address guardian = address(0x6066);
    uint64 constant MIN_DELAY = 1 days;
    uint64 constant T0 = 1_700_000_000;
    bytes32 constant SPEC = bytes32("zen-coder-flash");

    function setUp() public {
        vm.warp(T0);
        params = new MockParams();
        approvals = new MockApproval();
        exec = new AIExecute(address(params), address(approvals), MIN_DELAY, guardian);
        target = new Target(address(exec));
    }

    function _op() internal view returns (AIExecute.Operation memory) {
        return AIExecute.Operation({
            target: address(target),
            value: 0,
            data: abi.encodeWithSelector(Target.complexUpdate.selector, uint256(42), address(0xBEEF), bytes32("hi"), true),
            predecessor: bytes32(0),
            salt: bytes32("salt"),
            earliestExecTime: 0, // let the protocol floor (approvedAt + minDelay) govern
            expiryTime: 0
        });
    }

    // ---- Tier 1: typed enact (no timelock) -----------------------------------

    function test_EnactNumber() public {
        params.set(SPEC, "tithe_bps", 1500);
        exec.enact(SPEC, "tithe_bps", address(target), target.setLimit.selector);
        assertEq(target.limit(), 1500, "consensus number enacted immediately");
    }

    function test_EnactBool_YesNo() public {
        params.set(SPEC, "paused", 1);
        exec.enact(SPEC, "paused", address(target), target.setFlag.selector);
        assertTrue(target.flag(), "YES (1) sets the flag");
        params.set(SPEC, "paused", 0);
        exec.enact(SPEC, "paused", address(target), target.setFlag.selector);
        assertFalse(target.flag(), "NO (0) clears it");
    }

    function test_EnactSignedInt() public {
        params.set(SPEC, "rate", uint256(int256(-42)));
        exec.enact(SPEC, "rate", address(target), target.setRate.selector);
        assertEq(target.rate(), -42, "signed number enacted");
    }

    function test_Enact_NotDecided_Reverts() public {
        vm.expectRevert(AIExecute.NotDecided.selector);
        exec.enact(SPEC, "undecided", address(target), target.setLimit.selector);
    }

    // ---- structured read ------------------------------------------------------

    function test_ReadStructured() public {
        params.set(SPEC, "tithe_bps", 777);
        exec.enact(SPEC, "tithe_bps", address(target), target.setLimit.selector);
        assertEq(exec.readUint(address(target), abi.encodeWithSelector(target.limit.selector)), 777, "readUint");
        params.set(SPEC, "paused", 1);
        exec.enact(SPEC, "paused", address(target), target.setFlag.selector);
        assertTrue(exec.readBool(address(target), abi.encodeWithSelector(target.flag.selector)), "readBool yes/no");
    }

    // ---- Tier 3: arbitrary execute (windowed) --------------------------------

    function test_ApprovedArbitraryCall_ExecutesAfterFloor() public {
        AIExecute.Operation memory op = _op();
        bytes32 id = exec.hashOperation(op);
        approvals.approve(id, uint64(block.timestamp));
        vm.warp(block.timestamp + MIN_DELAY + 1); // past approvedAt + minDelay
        bytes memory ret = exec.execute(op);
        assertEq(target.a(), 42);
        assertEq(target.b(), address(0xBEEF));
        assertEq(target.c(), bytes32("hi"));
        assertTrue(target.d(), "the whole arbitrary multi-arg call ran by consensus");
        assertEq(abi.decode(ret, (uint256)), 43, "structured return flows back through execute()");
    }

    function test_Execute_NotApproved_Reverts() public {
        vm.expectRevert(AIExecute.NotApproved.selector);
        exec.execute(_op());
    }

    // protocol floor: even with earliest=0, cannot fire before approvedAt + minDelay.
    function test_Execute_TimelockedByFloor() public {
        AIExecute.Operation memory op = _op();
        bytes32 id = exec.hashOperation(op);
        uint64 t = uint64(block.timestamp);
        approvals.approve(id, t);
        vm.expectRevert(abi.encodeWithSelector(AIExecute.Timelocked.selector, t + MIN_DELAY));
        exec.execute(op); // still inside the floor timelock
    }

    // proposer may demand MORE delay than the floor; the later time wins.
    function test_Execute_HonorsLongerDeclaredEarliest() public {
        AIExecute.Operation memory op = _op();
        op.earliestExecTime = T0 + 10 days; // much later than the 1-day floor
        bytes32 id = exec.hashOperation(op);
        approvals.approve(id, T0);
        vm.warp(T0 + MIN_DELAY + 1); // past floor, before declared earliest
        vm.expectRevert(abi.encodeWithSelector(AIExecute.Timelocked.selector, T0 + 10 days));
        exec.execute(op);
        vm.warp(T0 + 10 days);
        exec.execute(op); // now allowed
        assertEq(target.a(), 42);
    }

    function test_Execute_Expired() public {
        AIExecute.Operation memory op = _op();
        op.expiryTime = T0 + 2 days;
        bytes32 id = exec.hashOperation(op);
        approvals.approve(id, T0);
        vm.warp(T0 + 3 days); // past expiry
        vm.expectRevert(abi.encodeWithSelector(AIExecute.Expired.selector, T0 + 2 days));
        exec.execute(op);
    }

    function test_Execute_OneShot() public {
        AIExecute.Operation memory op = _op();
        bytes32 id = exec.hashOperation(op);
        approvals.approve(id, T0);
        vm.warp(T0 + MIN_DELAY + 1);
        exec.execute(op);
        vm.expectRevert(AIExecute.AlreadyExecuted.selector);
        exec.execute(op);
    }

    // predecessor ordering: op B (predecessor = A) cannot run until A has executed.
    function test_Execute_PredecessorOrdering() public {
        AIExecute.Operation memory a = _op();
        bytes32 idA = exec.hashOperation(a);

        AIExecute.Operation memory b = _op();
        b.salt = bytes32("b");
        b.data = abi.encodeWithSelector(Target.complexUpdate.selector, uint256(99), address(0xCAFE), bytes32("b"), false);
        b.predecessor = idA;
        bytes32 idB = exec.hashOperation(b);

        approvals.approve(idA, T0);
        approvals.approve(idB, T0);
        vm.warp(T0 + MIN_DELAY + 1);

        vm.expectRevert(abi.encodeWithSelector(AIExecute.PredecessorPending.selector, idA));
        exec.execute(b); // A not executed yet

        exec.execute(a);
        exec.execute(b); // now ordered correctly
        assertEq(target.a(), 99);
    }

    // guardian veto kills an approved op during its window.
    function test_Execute_GuardianCancel() public {
        AIExecute.Operation memory op = _op();
        bytes32 id = exec.hashOperation(op);
        approvals.approve(id, T0);
        vm.prank(guardian);
        exec.cancel(id);
        vm.warp(T0 + MIN_DELAY + 1);
        vm.expectRevert(AIExecute.OperationCanceled.selector);
        exec.execute(op);
    }

    function test_Cancel_OnlyGuardian() public {
        vm.expectRevert(AIExecute.NotGuardian.selector);
        exec.cancel(bytes32("x"));
    }

    // the approval binds the EXACT op: any changed byte → different id → not approved.
    function test_Execute_BindsExactOperation() public {
        AIExecute.Operation memory op = _op();
        approvals.approve(exec.hashOperation(op), T0);
        vm.warp(T0 + MIN_DELAY + 1);
        op.value = 1; // change one field
        vm.expectRevert(AIExecute.NotApproved.selector);
        exec.execute(op);
    }

    // chainId + this-executor are in the hash → an approval can't be replayed on another instance.
    function test_HashBindsChainAndExecutor() public {
        AIExecute other = new AIExecute(address(params), address(approvals), MIN_DELAY, guardian);
        AIExecute.Operation memory op = _op();
        assertTrue(
            exec.hashOperation(op) != other.hashOperation(op),
            "same op hashes differently per executor instance"
        );
    }

    function test_Target_TrustsOnlyExecutor() public {
        vm.expectRevert(bytes("not gov"));
        target.setLimit(999);
    }
}
