// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ReputationV1} from "../contracts/deployables/bounty/ReputationV1.sol";
import {IReputationV1} from "../contracts/interfaces/dao/deployables/IReputationV1.sol";

/// @notice Direct unit proofs for ReputationV1: single-writer authorization,
/// monotonic completion/earnings, dispute-loss tracking, and composable reads.
contract ReputationV1Test is Test {
    ReputationV1 internal rep;

    address internal owner = address(0x0420);
    address internal writer = address(0xB0117); // the work-market contract
    address internal worker = address(0x9A0);
    address internal worker2 = address(0x9A1);

    function setUp() public {
        ReputationV1 impl = new ReputationV1();
        rep = ReputationV1(
            address(new ERC1967Proxy(address(impl), abi.encodeCall(ReputationV1.initialize, (owner, writer))))
        );
    }

    function test_InitializesAsProxy() public view {
        assertEq(rep.writer(), writer, "writer set");
        assertEq(rep.owner(), owner, "owner set");
        assertEq(rep.version(), 1);
        assertTrue(rep.deploymentBlock() > 0);
        assertTrue(rep.supportsInterface(type(IReputationV1).interfaceId));
    }

    function test_RevertsOnZeroWriter() public {
        ReputationV1 impl = new ReputationV1();
        vm.expectRevert(IReputationV1.InvalidWriter.selector);
        new ERC1967Proxy(address(impl), abi.encodeCall(ReputationV1.initialize, (owner, address(0))));
    }

    function test_OnlyWriterCanRecordCompletion() public {
        vm.expectRevert(IReputationV1.OnlyWriter.selector);
        rep.recordCompletion(worker, 1 ether);
    }

    function test_OnlyWriterCanRecordDisputeLoss() public {
        vm.expectRevert(IReputationV1.OnlyWriter.selector);
        rep.recordDisputeLoss(worker);
    }

    function test_CompletionAccrues() public {
        vm.startPrank(writer);
        rep.recordCompletion(worker, 3 ether);
        rep.recordCompletion(worker, 7 ether);
        vm.stopPrank();

        (uint64 completed, uint64 lost, uint256 earned) = rep.reputationOf(worker);
        assertEq(completed, 2, "two completions");
        assertEq(lost, 0, "no losses");
        assertEq(earned, 10 ether, "earnings summed");
        assertEq(rep.completedOf(worker), 2);
        assertEq(rep.earnedOf(worker), 10 ether);
    }

    function test_DisputeLossAccrues() public {
        vm.startPrank(writer);
        rep.recordDisputeLoss(worker);
        rep.recordDisputeLoss(worker);
        rep.recordDisputeLoss(worker);
        vm.stopPrank();

        (, uint64 lost, ) = rep.reputationOf(worker);
        assertEq(lost, 3, "three losses");
        assertEq(rep.completedOf(worker), 0, "no completions");
    }

    function test_WorkersAreIndependent() public {
        vm.startPrank(writer);
        rep.recordCompletion(worker, 5 ether);
        rep.recordCompletion(worker2, 11 ether);
        rep.recordDisputeLoss(worker2);
        vm.stopPrank();

        assertEq(rep.earnedOf(worker), 5 ether);
        assertEq(rep.completedOf(worker), 1);
        assertEq(rep.earnedOf(worker2), 11 ether);
        (, uint64 lost2, ) = rep.reputationOf(worker2);
        assertEq(lost2, 1);
    }

    function test_ZeroWorkerRejected() public {
        vm.prank(writer);
        vm.expectRevert(IReputationV1.InvalidWorker.selector);
        rep.recordCompletion(address(0), 1 ether);
    }

    function test_EmitsCompletionEvent() public {
        vm.expectEmit(true, false, false, true, address(rep));
        emit IReputationV1.CompletionRecorded(worker, 4 ether, 1, 4 ether);
        vm.prank(writer);
        rep.recordCompletion(worker, 4 ether);
    }
}
