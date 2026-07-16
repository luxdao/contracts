// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {BountyV1} from "../contracts/deployables/bounty/BountyV1.sol";
import {EscrowV1} from "../contracts/deployables/bounty/EscrowV1.sol";
import {ReputationV1} from "../contracts/deployables/bounty/ReputationV1.sol";
import {IBountyV1} from "../contracts/interfaces/dao/deployables/IBountyV1.sol";
import {IEscrowV1} from "../contracts/interfaces/dao/deployables/IEscrowV1.sol";
import {IReputationV1} from "../contracts/interfaces/dao/deployables/IReputationV1.sol";
import {MockERC20} from "../contracts/mocks/MockERC20.sol";
import {MockFeeOnTransferERC20} from "../contracts/mocks/MockFeeOnTransferERC20.sol";

/// @dev A minimal contract "signer" standing in for a Safe (incl. a PQ-signed Safe):
/// it can be a bounty's funder, approver, and arbiter, proving the market never
/// assumes an EOA. It forwards arbitrary calls so the test can act AS the Safe.
contract SafeLike {
    function exec(address to, uint256 value, bytes calldata data) external payable returns (bytes memory) {
        (bool ok, bytes memory ret) = to.call{value: value}(data);
        require(ok, "SafeLike: call failed");
        return ret;
    }

    receive() external payable {}
}

/// @dev Malicious worker that, on receiving the native reward during accept(),
/// tries to reenter BountyV1. The nonReentrant guard + already-terminal state must
/// make any reentry revert; the attacker swallows it so we can assert no double-pay.
contract ReentrantWorker {
    BountyV1 public immutable bounty;
    uint256 public bountyId;
    bool public tried;

    constructor(BountyV1 bounty_) {
        bounty = bounty_;
    }

    function setBounty(uint256 id) external {
        bountyId = id;
    }

    function doClaim(uint256 id) external payable {
        bountyId = id;
        bounty.claim{value: msg.value}(id);
    }

    function doSubmit(uint256 id, string calldata ref) external {
        bounty.submit(id, ref);
    }

    receive() external payable {
        if (!tried) {
            tried = true;
            // Try to claim again / re-accept -- must revert under the guard.
            try bounty.accept(bountyId) {} catch {}
        }
    }
}

/// @notice Full-lifecycle proofs for the permissionless work market. Conservation is
/// asserted across happy path, slash, dispute (split + refund), cancel and reclaim.
contract BountyV1Test is Test {
    BountyV1 internal bounty;
    EscrowV1 internal escrow;
    ReputationV1 internal rep;
    MockERC20 internal token;

    address internal owner = address(0x0420);
    address internal funder = address(0xF4DE7);
    address internal approver = address(0xA999);
    address internal arbiter = address(0xA981E7);
    address internal worker = address(0x9A0);
    address internal stranger = address(0x57A);
    address internal treasury = address(0x77EA);

    address internal constant NATIVE = address(0);

    uint256 internal constant REWARD = 10 ether;
    uint256 internal constant STAKE = 1 ether;
    uint64 internal constant WINDOW = 3 days; // claim window
    uint64 internal constant REVIEW = 3 days; // review window (liveness escape)

    function setUp() public {
        token = new MockERC20("Work Token", "WORK", 18);

        // Break the escrow<->bounty wiring cycle by predicting the bounty proxy
        // address: in setUp() the next CREATE from this contract after the escrow
        // impl + escrow proxy + reputation impl + reputation proxy + bounty impl is
        // the bounty proxy. This mirrors a deploy script that predicts the proxy
        // address, points escrow/reputation at it, then deploys the proxy.
        EscrowV1 escrowImpl = new EscrowV1();
        ReputationV1 repImpl = new ReputationV1();
        BountyV1 bountyImpl = new BountyV1();

        // After the two proxies below + nothing else, the bounty proxy is created at
        // nonce(this)+3 (escrow proxy, rep proxy, bounty proxy). Compute it now.
        address predictedBounty = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 2);

        escrow = EscrowV1(
            payable(
                address(
                    new ERC1967Proxy(
                        address(escrowImpl),
                        abi.encodeCall(EscrowV1.initialize, (owner, predictedBounty))
                    )
                )
            )
        );
        rep = ReputationV1(
            address(
                new ERC1967Proxy(
                    address(repImpl),
                    abi.encodeCall(ReputationV1.initialize, (owner, predictedBounty))
                )
            )
        );
        bounty = BountyV1(
            address(
                new ERC1967Proxy(
                    address(bountyImpl),
                    abi.encodeCall(BountyV1.initialize, (owner, address(escrow), address(rep), treasury))
                )
            )
        );

        assertEq(address(bounty), predictedBounty, "prediction held");
        assertEq(escrow.controller(), address(bounty), "escrow controller is bounty");
        assertEq(rep.writer(), address(bounty), "reputation writer is bounty");
    }

    // ==================================================================
    // Wiring / deployability
    // ==================================================================

    function test_InitializesAsProxy() public view {
        assertEq(bounty.escrow(), address(escrow));
        assertEq(bounty.reputation(), address(rep));
        assertEq(bounty.treasury(), treasury);
        assertEq(bounty.owner(), owner);
        assertEq(bounty.version(), 1);
        assertTrue(bounty.deploymentBlock() > 0);
        assertTrue(bounty.supportsInterface(type(IBountyV1).interfaceId));
    }

    // ==================================================================
    // R1 -- window bound: an unbounded review/claim window would overflow
    // submit()'s deadline math and brick a staked worker. propose() rejects it.
    // ==================================================================

    function test_R1_ProposeRejectsUnboundedWindow() public {
        uint64 maxW = 365 days;

        // The R1 attack value: a near-uint64.max reviewWindow that would overflow
        // submit()'s `block.timestamp + reviewWindow` -- rejected at propose(), so the
        // worker-stake brick can never be set up.
        vm.prank(funder);
        vm.expectRevert(abi.encodeWithSelector(IBountyV1.WindowTooLong.selector, type(uint64).max, maxW));
        bounty.propose(NATIVE, REWARD, STAKE, approver, arbiter, WINDOW, type(uint64).max, "issue");

        // Just-over-max claimWindow is likewise rejected (checked first).
        vm.prank(funder);
        vm.expectRevert(abi.encodeWithSelector(IBountyV1.WindowTooLong.selector, maxW + 1, maxW));
        bounty.propose(NATIVE, REWARD, STAKE, approver, arbiter, maxW + 1, REVIEW, "issue");

        // Exactly MAX_WINDOW is a legitimate long bounty and is accepted (no overflow).
        vm.prank(funder);
        uint256 id = bounty.propose(NATIVE, REWARD, STAKE, approver, arbiter, maxW, maxW, "issue");
        assertEq(uint8(bounty.stateOf(id)), uint8(IBountyV1.State.Open), "max window accepted");
    }

    // ==================================================================
    // Review-window boundary: at t == reviewDeadline, dispute is last-open and
    // finalize is not-yet-open -- exactly one exit live, no double-exit, no gap.
    // ==================================================================

    function test_ReviewBoundary_ExactDeadline_DisputeOpenFinalizeClosed() public {
        vm.deal(funder, REWARD);
        vm.deal(worker, STAKE);

        vm.prank(funder);
        uint256 id = bounty.propose(NATIVE, REWARD, STAKE, approver, arbiter, WINDOW, REVIEW, "issue");
        vm.prank(funder);
        bounty.fund{value: REWARD}(id);
        vm.prank(worker);
        bounty.claim{value: STAKE}(id);
        vm.prank(worker);
        bounty.submit(id, "PR");

        uint64 deadline = bounty.bounties(id).reviewDeadline;

        // At EXACTLY the deadline: finalize needs strictly-greater time -> reverts.
        vm.warp(deadline);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IBountyV1.ReviewWindowNotElapsed.selector, id, deadline));
        bounty.finalize(id);

        // ...and dispute (gated <= deadline) is still open at the exact tick.
        vm.prank(funder);
        bounty.dispute(id, "reason");
        assertEq(uint8(bounty.stateOf(id)), uint8(IBountyV1.State.Disputed), "dispute open at exact deadline");
    }

    // ==================================================================
    // Happy path -- NATIVE -- full conservation
    // ==================================================================

    function test_HappyPath_Native_Conserves() public {
        // Conservation baseline: total native across all actors + escrow is constant.
        vm.deal(funder, REWARD);
        vm.deal(worker, STAKE);
        uint256 total = _sumNative();

        // Propose (funder) -- permissionless.
        vm.prank(funder);
        uint256 id = bounty.propose(NATIVE, REWARD, STAKE, approver, arbiter, WINDOW, REVIEW, "ipfs://issue");
        assertEq(uint8(bounty.stateOf(id)), uint8(IBountyV1.State.Open));

        // Fund (funder escrows reward).
        vm.prank(funder);
        bounty.fund{value: REWARD}(id);
        assertEq(uint8(bounty.stateOf(id)), uint8(IBountyV1.State.Funded));
        assertEq(address(escrow).balance, REWARD, "reward escrowed");

        // Claim (worker stakes) -- permissionless.
        vm.prank(worker);
        bounty.claim{value: STAKE}(id);
        assertEq(uint8(bounty.stateOf(id)), uint8(IBountyV1.State.Claimed));
        assertEq(address(escrow).balance, REWARD + STAKE, "reward + stake escrowed");

        // Submit (worker).
        vm.prank(worker);
        bounty.submit(id, "ipfs://deliverable");
        assertEq(uint8(bounty.stateOf(id)), uint8(IBountyV1.State.Submitted));

        // Accept (approver) -- atomic payout.
        vm.prank(approver);
        bounty.accept(id);
        assertEq(uint8(bounty.stateOf(id)), uint8(IBountyV1.State.Paid));

        // Worker got reward + stake back; escrow empty; reputation credited.
        assertEq(worker.balance, REWARD + STAKE, "worker paid reward + stake returned");
        assertEq(address(escrow).balance, 0, "escrow drained");
        assertEq(rep.completedOf(worker), 1, "completion recorded");
        assertEq(rep.earnedOf(worker), REWARD, "earnings recorded");

        // Conservation: nothing minted or burned.
        assertEq(_sumNative(), total, "native conserved across lifecycle");
    }

    // ==================================================================
    // Happy path -- ERC-20 -- full conservation
    // ==================================================================

    function test_HappyPath_ERC20_Conserves() public {
        token.mint(funder, REWARD);
        token.mint(worker, STAKE);
        uint256 supply = token.totalSupply();

        vm.prank(funder);
        uint256 id = bounty.propose(address(token), REWARD, STAKE, approver, arbiter, WINDOW, REVIEW, "issue");

        // Funder approves the ESCROW (escrow pulls), then funds.
        vm.prank(funder);
        token.approve(address(escrow), REWARD);
        vm.prank(funder);
        bounty.fund(id);
        assertEq(token.balanceOf(address(escrow)), REWARD);

        // Worker approves the escrow, then claims.
        vm.prank(worker);
        token.approve(address(escrow), STAKE);
        vm.prank(worker);
        bounty.claim(id);
        assertEq(token.balanceOf(address(escrow)), REWARD + STAKE);

        vm.prank(worker);
        bounty.submit(id, "deliverable");
        vm.prank(approver);
        bounty.accept(id);

        assertEq(token.balanceOf(worker), REWARD + STAKE, "worker reward + stake");
        assertEq(token.balanceOf(address(escrow)), 0, "escrow drained");
        assertEq(token.totalSupply(), supply, "token supply conserved");
        assertEq(rep.completedOf(worker), 1);
    }

    // ==================================================================
    // Permissionless claim
    // ==================================================================

    function test_AnyAddressCanClaim() public {
        uint256 id = _proposeAndFundNative();

        // An arbitrary, never-allowlisted address claims successfully.
        address rando = address(0xBEEF1234);
        vm.deal(rando, STAKE);
        vm.prank(rando);
        bounty.claim{value: STAKE}(id);

        IBountyV1.Bounty memory b = bounty.bounties(id);
        assertEq(b.worker, rando, "arbitrary address became worker");
        assertEq(uint8(b.state), uint8(IBountyV1.State.Claimed));
    }

    // ==================================================================
    // Stake slash on abandonment / timeout
    // ==================================================================

    function test_ReclaimSlashesStakeToTreasury_AndReopens() public {
        uint256 id = _proposeAndFundNative();
        vm.deal(worker, STAKE);
        vm.prank(worker);
        bounty.claim{value: STAKE}(id);

        // Before deadline: cannot reclaim.
        IBountyV1.Bounty memory b0 = bounty.bounties(id);
        vm.expectRevert(abi.encodeWithSelector(IBountyV1.DeadlineNotPassed.selector, id, b0.claimDeadline));
        bounty.reclaim(id);

        // After deadline: ANYONE reclaims; stake is slashed to treasury, bounty reopens.
        vm.warp(block.timestamp + WINDOW + 1);
        uint256 treStart = treasury.balance;
        vm.prank(stranger);
        bounty.reclaim(id);

        assertEq(treasury.balance, treStart + STAKE, "stake slashed to treasury");
        IBountyV1.Bounty memory b1 = bounty.bounties(id);
        assertEq(uint8(b1.state), uint8(IBountyV1.State.Funded), "reopened");
        assertEq(b1.worker, address(0), "worker cleared");
        assertEq(address(escrow).balance, REWARD, "reward still escrowed");

        // A fresh worker can now claim the reopened bounty.
        vm.deal(worker, STAKE);
        vm.prank(worker);
        bounty.claim{value: STAKE}(id);
        assertEq(uint8(bounty.stateOf(id)), uint8(IBountyV1.State.Claimed));
    }

    function test_SlashRoutesToFunderWhenNoTreasury() public {
        // Re-deploy a market with treasury == address(0): slash must route to funder.
        (BountyV1 b2, EscrowV1 e2, ) = _deployMarket(address(0));

        vm.deal(funder, REWARD);
        vm.prank(funder);
        uint256 id = b2.propose(NATIVE, REWARD, STAKE, approver, arbiter, WINDOW, REVIEW, "issue");
        vm.prank(funder);
        b2.fund{value: REWARD}(id);
        vm.deal(worker, STAKE);
        vm.prank(worker);
        b2.claim{value: STAKE}(id);

        vm.warp(block.timestamp + WINDOW + 1);
        uint256 funderStart = funder.balance;
        b2.reclaim(id);
        assertEq(funder.balance, funderStart + STAKE, "slash routed to funder");
        assertEq(address(e2).balance, REWARD, "reward intact");
    }

    function test_SubmitAfterDeadlineReverts() public {
        uint256 id = _proposeAndFundNative();
        vm.deal(worker, STAKE);
        vm.prank(worker);
        bounty.claim{value: STAKE}(id);

        vm.warp(block.timestamp + WINDOW + 1);
        IBountyV1.Bounty memory b = bounty.bounties(id);
        vm.prank(worker);
        vm.expectRevert(abi.encodeWithSelector(IBountyV1.DeadlinePassed.selector, id, b.claimDeadline));
        bounty.submit(id, "late");
    }

    // ==================================================================
    // Dispute -> arbiter resolve (split + refund + stake decision), conservation
    // ==================================================================

    function test_Dispute_SplitRewardKeepStake_Conserves() public {
        // Drive to Submitted (helper deals + escrows reward and stake), then snapshot
        // the conservation total: reward + stake now live in the escrow.
        uint256 id = _toSubmitted(NATIVE);
        uint256 total = _sumNative();

        // Funder disputes.
        vm.prank(funder);
        bounty.dispute(id, "ipfs://reason");
        assertEq(uint8(bounty.stateOf(id)), uint8(IBountyV1.State.Disputed));

        // Arbiter splits 7 to worker / 3 back to funder, worker keeps stake.
        vm.prank(arbiter);
        bounty.resolveDispute(id, 7 ether, 3 ether, true);

        assertEq(uint8(bounty.stateOf(id)), uint8(IBountyV1.State.Paid));
        assertEq(worker.balance, 7 ether + STAKE, "worker: split + stake");
        assertEq(funder.balance, 3 ether, "funder: refunded portion");
        assertEq(address(escrow).balance, 0, "escrow drained");
        assertEq(rep.completedOf(worker), 1, "nonzero worker payout => completion");
        assertEq(_sumNative(), total, "conserved across dispute split");
    }

    function test_Dispute_FullRefundSlashStake_RecordsLoss_Conserves() public {
        uint256 id = _toSubmitted(NATIVE);
        uint256 total = _sumNative();

        vm.prank(approver);
        bounty.dispute(id, "bad work");

        // Arbiter: 0 to worker, full reward back to funder, slash the stake to treasury.
        uint256 treStart = treasury.balance;
        vm.prank(arbiter);
        bounty.resolveDispute(id, 0, REWARD, false);

        assertEq(worker.balance, 0, "worker gets nothing");
        assertEq(funder.balance, REWARD, "funder fully refunded");
        assertEq(treasury.balance, treStart + STAKE, "stake slashed to treasury");
        assertEq(address(escrow).balance, 0, "escrow drained");
        (, uint64 lost, ) = rep.reputationOf(worker);
        assertEq(lost, 1, "dispute loss recorded");
        assertEq(rep.completedOf(worker), 0, "no completion");
        assertEq(_sumNative(), total, "conserved across full-refund + slash");
    }

    function test_Dispute_SplitMustEqualReward() public {
        uint256 id = _toSubmitted(NATIVE);
        vm.prank(funder);
        bounty.dispute(id, "r");
        vm.prank(arbiter);
        vm.expectRevert(abi.encodeWithSelector(IBountyV1.SplitExceedsReward.selector, id, REWARD, 11 ether));
        bounty.resolveDispute(id, 8 ether, 3 ether, true); // 11 != 10
    }

    function test_OnlyArbiterResolves() public {
        uint256 id = _toSubmitted(NATIVE);
        vm.prank(funder);
        bounty.dispute(id, "r");
        vm.prank(stranger);
        vm.expectRevert(IBountyV1.OnlyArbiter.selector);
        bounty.resolveDispute(id, REWARD, 0, true);
    }

    function test_OnlyFunderOrApproverDisputes() public {
        uint256 id = _toSubmitted(NATIVE);
        vm.prank(stranger);
        vm.expectRevert(IBountyV1.OnlyApprover.selector);
        bounty.dispute(id, "r");
    }

    // ==================================================================
    // Cancel / refund on expiry
    // ==================================================================

    function test_CancelOpen_NoEscrow() public {
        vm.prank(funder);
        uint256 id = bounty.propose(NATIVE, REWARD, STAKE, approver, arbiter, WINDOW, REVIEW, "issue");
        vm.prank(funder);
        bounty.cancel(id);
        assertEq(uint8(bounty.stateOf(id)), uint8(IBountyV1.State.Cancelled));
    }

    function test_CancelFunded_RefundsReward_Conserves() public {
        uint256 id = _proposeAndFundNative();
        uint256 total = _sumNative();

        vm.prank(funder);
        bounty.cancel(id);

        assertEq(uint8(bounty.stateOf(id)), uint8(IBountyV1.State.Cancelled));
        assertEq(funder.balance, REWARD, "reward refunded to funder");
        assertEq(address(escrow).balance, 0, "escrow drained");
        assertEq(_sumNative(), total, "conserved across cancel/refund");
    }

    function test_OnlyFunderCancels() public {
        uint256 id = _proposeAndFundNative();
        vm.prank(stranger);
        vm.expectRevert(IBountyV1.OnlyFunder.selector);
        bounty.cancel(id);
    }

    function test_CannotCancelAfterClaimed() public {
        uint256 id = _proposeAndFundNative();
        vm.deal(worker, STAKE);
        vm.prank(worker);
        bounty.claim{value: STAKE}(id);
        vm.prank(funder);
        vm.expectRevert(
            abi.encodeWithSelector(IBountyV1.InvalidState.selector, id, IBountyV1.State.Claimed, IBountyV1.State.Funded)
        );
        bounty.cancel(id);
    }

    // ==================================================================
    // Illegal-transition guards
    // ==================================================================

    function test_CannotClaimUnfunded() public {
        vm.prank(funder);
        uint256 id = bounty.propose(NATIVE, REWARD, STAKE, approver, arbiter, WINDOW, REVIEW, "issue");
        vm.deal(worker, STAKE);
        vm.prank(worker);
        vm.expectRevert(
            abi.encodeWithSelector(IBountyV1.InvalidState.selector, id, IBountyV1.State.Open, IBountyV1.State.Funded)
        );
        bounty.claim{value: STAKE}(id);
    }

    function test_CannotSubmitBeforeClaim() public {
        uint256 id = _proposeAndFundNative();
        vm.prank(worker);
        vm.expectRevert(
            abi.encodeWithSelector(IBountyV1.InvalidState.selector, id, IBountyV1.State.Funded, IBountyV1.State.Claimed)
        );
        bounty.submit(id, "x");
    }

    function test_CannotAcceptBeforeSubmit() public {
        uint256 id = _proposeAndFundNative();
        vm.deal(worker, STAKE);
        vm.prank(worker);
        bounty.claim{value: STAKE}(id);
        vm.prank(approver);
        vm.expectRevert(
            abi.encodeWithSelector(
                IBountyV1.InvalidState.selector,
                id,
                IBountyV1.State.Claimed,
                IBountyV1.State.Submitted
            )
        );
        bounty.accept(id);
    }

    function test_OnlyWorkerSubmits() public {
        uint256 id = _proposeAndFundNative();
        vm.deal(worker, STAKE);
        vm.prank(worker);
        bounty.claim{value: STAKE}(id);
        vm.prank(stranger);
        vm.expectRevert(IBountyV1.OnlyWorker.selector);
        bounty.submit(id, "x");
    }

    function test_OnlyApproverAccepts() public {
        uint256 id = _toSubmitted(NATIVE);
        vm.prank(stranger);
        vm.expectRevert(IBountyV1.OnlyApprover.selector);
        bounty.accept(id);
    }

    function test_UnknownBountyReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IBountyV1.UnknownBounty.selector, uint256(999)));
        bounty.fund{value: 0}(999);
    }

    function test_ProposeRejectsZeroRewardOrStake() public {
        vm.prank(funder);
        vm.expectRevert(IBountyV1.ZeroAmount.selector);
        bounty.propose(NATIVE, 0, STAKE, approver, arbiter, WINDOW, REVIEW, "i");
        vm.prank(funder);
        vm.expectRevert(IBountyV1.ZeroAmount.selector);
        bounty.propose(NATIVE, REWARD, 0, approver, arbiter, WINDOW, REVIEW, "i");
    }

    function test_ProposeRejectsZeroApprover() public {
        vm.prank(funder);
        vm.expectRevert(IBountyV1.InvalidApprover.selector);
        bounty.propose(NATIVE, REWARD, STAKE, address(0), arbiter, WINDOW, REVIEW, "i");
    }

    // ==================================================================
    // Native-value mismatches at the boundary
    // ==================================================================

    function test_FundNativeWrongValueReverts() public {
        vm.prank(funder);
        uint256 id = bounty.propose(NATIVE, REWARD, STAKE, approver, arbiter, WINDOW, REVIEW, "i");
        vm.deal(funder, REWARD);
        vm.prank(funder);
        vm.expectRevert(abi.encodeWithSelector(IBountyV1.StakeMismatch.selector, REWARD, 1 ether));
        bounty.fund{value: 1 ether}(id);
    }

    function test_FundERC20WithNativeValueReverts() public {
        token.mint(funder, REWARD);
        vm.prank(funder);
        uint256 id = bounty.propose(address(token), REWARD, STAKE, approver, arbiter, WINDOW, REVIEW, "i");
        vm.prank(funder);
        token.approve(address(escrow), REWARD);
        vm.deal(funder, 1 ether);
        vm.prank(funder);
        vm.expectRevert(IBountyV1.UnexpectedNativeValue.selector);
        bounty.fund{value: 1 wei}(id);
    }

    // ==================================================================
    // Reentrancy: malicious worker cannot double-spend on accept()
    // ==================================================================

    function test_ReentrantWorkerCannotDoublePay() public {
        ReentrantWorker attacker = new ReentrantWorker(bounty);
        uint256 id = _proposeAndFundNative();

        // Fund the stake from the test contract (the caller pays doClaim's value), so
        // the attacker starts at zero and ends holding exactly what it is paid.
        vm.deal(address(this), STAKE);
        attacker.doClaim{value: STAKE}(id);
        attacker.doSubmit(id, "deliverable");
        assertEq(address(attacker).balance, 0, "attacker forwarded its whole stake");

        uint256 escrowBefore = address(escrow).balance; // REWARD + STAKE
        vm.prank(approver);
        bounty.accept(id);

        assertTrue(attacker.tried(), "attacker attempted reentry on receive");
        // Attacker received exactly REWARD + STAKE once; escrow emptied; no extra.
        assertEq(address(attacker).balance, REWARD + STAKE, "paid exactly once");
        assertEq(address(escrow).balance, escrowBefore - (REWARD + STAKE), "escrow drained exactly");
        assertEq(uint8(bounty.stateOf(id)), uint8(IBountyV1.State.Paid));
    }

    /// @dev finalize() shares the payout helper with accept(); prove the same reentrancy
    /// guard + terminal-state protection holds on the permissionless finalize path.
    function test_ReentrantWorkerCannotDoublePayOnFinalize() public {
        ReentrantWorker attacker = new ReentrantWorker(bounty);
        uint256 id = _proposeAndFundNative();

        vm.deal(address(this), STAKE);
        attacker.doClaim{value: STAKE}(id);
        attacker.doSubmit(id, "deliverable");

        // Warp past the review window; anyone may finalize. The attacker's receive() tries
        // to reenter (accept) during its payout and is stopped by the guard + terminal state.
        IBountyV1.Bounty memory b = bounty.bounties(id);
        vm.warp(uint256(b.reviewDeadline) + 1);
        uint256 escrowBefore = address(escrow).balance;
        vm.prank(stranger);
        bounty.finalize(id);

        assertTrue(attacker.tried(), "attacker attempted reentry on receive");
        assertEq(address(attacker).balance, REWARD + STAKE, "paid exactly once via finalize");
        assertEq(address(escrow).balance, escrowBefore - (REWARD + STAKE), "escrow drained exactly");
        assertEq(uint8(bounty.stateOf(id)), uint8(IBountyV1.State.Paid));
    }

    // ==================================================================
    // Contract signer (Safe / PQ-Safe) as funder + separate approver/arbiter
    // ==================================================================

    function test_SafeContractAsFunderAndApprover() public {
        // Two distinct Safe-like contracts: one funds (funder), one reviews (approver +
        // arbiter). M2 forbids funder == approver/arbiter, so the roles are held by
        // SEPARATE contract signers — proving the market never assumes an EOA while
        // respecting the anti-self-dealing guard.
        SafeLike funderSafe = new SafeLike();
        SafeLike reviewSafe = new SafeLike();
        vm.deal(address(funderSafe), REWARD);

        bytes memory ret = funderSafe.exec(
            address(bounty),
            0,
            abi.encodeCall(
                IBountyV1.propose,
                (NATIVE, REWARD, STAKE, address(reviewSafe), address(reviewSafe), WINDOW, REVIEW, "issue")
            )
        );
        uint256 id = abi.decode(ret, (uint256));

        funderSafe.exec(address(bounty), REWARD, abi.encodeCall(IBountyV1.fund, (id)));

        vm.deal(worker, STAKE);
        vm.prank(worker);
        bounty.claim{value: STAKE}(id);
        vm.prank(worker);
        bounty.submit(id, "deliverable");

        // The review Safe accepts (as approver) -- authorization is purely "caller == approver".
        reviewSafe.exec(address(bounty), 0, abi.encodeCall(IBountyV1.accept, (id)));

        assertEq(uint8(bounty.stateOf(id)), uint8(IBountyV1.State.Paid));
        assertEq(worker.balance, REWARD + STAKE, "worker paid by Safe-run market");
        assertEq(rep.completedOf(worker), 1);
    }

    // ==================================================================
    // H1 -- LIVENESS: an idle approver can never lock a delivered worker
    // ==================================================================

    /// @dev THE invariant: from Submitted, if the approver ghosts (never accepts) and no
    /// one disputes within the review window, ANYONE may finalize and the worker is paid
    /// reward + stake. No reachable state locks a delivered worker's funds by inaction.
    function test_Finalize_ApproverGhosts_WorkerAlwaysEscapes_Conserves() public {
        uint256 id = _toSubmitted(NATIVE);
        uint256 total = _sumNative();

        // The approver never accepts; no dispute is raised. Before the window: no escape.
        IBountyV1.Bounty memory b = bounty.bounties(id);
        vm.expectRevert(abi.encodeWithSelector(IBountyV1.ReviewWindowNotElapsed.selector, id, b.reviewDeadline));
        bounty.finalize(id);

        // After the review window elapses, a STRANGER (permissionless) finalizes.
        vm.warp(uint256(b.reviewDeadline) + 1);
        vm.prank(stranger);
        bounty.finalize(id);

        // Worker paid reward + stake; escrow drained; completion recorded; conserved.
        assertEq(uint8(bounty.stateOf(id)), uint8(IBountyV1.State.Paid), "Paid via finalize");
        assertEq(worker.balance, REWARD + STAKE, "worker paid reward + stake");
        assertEq(address(escrow).balance, 0, "escrow drained");
        assertEq(rep.completedOf(worker), 1, "completion recorded on finalize");
        assertEq(_sumNative(), total, "native conserved across finalize");
    }

    function test_Finalize_RevertsBeforeSubmitted() public {
        uint256 id = _proposeAndFundNative();
        // Funded (not Submitted): finalize is an illegal transition.
        vm.expectRevert(
            abi.encodeWithSelector(
                IBountyV1.InvalidState.selector,
                id,
                IBountyV1.State.Funded,
                IBountyV1.State.Submitted
            )
        );
        bounty.finalize(id);
    }

    function test_AcceptStillWorksAfterWindow() public {
        // The approver retains the ability to accept explicitly even after the window
        // (accept and finalize both pay the worker; accept just attributes it).
        uint256 id = _toSubmitted(NATIVE);
        IBountyV1.Bounty memory b = bounty.bounties(id);
        vm.warp(uint256(b.reviewDeadline) + 1);
        vm.prank(approver);
        bounty.accept(id);
        assertEq(uint8(bounty.stateOf(id)), uint8(IBountyV1.State.Paid), "approver can still accept");
        assertEq(worker.balance, REWARD + STAKE, "worker paid");
    }

    function test_DisputeAfterReviewWindowReverts() public {
        // Dispute is gated to the review window: once it elapses the worker's finalize
        // escape cannot be retroactively pulled into arbitration by a sleeping funder.
        uint256 id = _toSubmitted(NATIVE);
        IBountyV1.Bounty memory b = bounty.bounties(id);
        vm.warp(uint256(b.reviewDeadline) + 1);
        vm.prank(funder);
        vm.expectRevert(abi.encodeWithSelector(IBountyV1.ReviewWindowElapsed.selector, id, b.reviewDeadline));
        bounty.dispute(id, "too late");
    }

    function test_DisputeWithinWindowStopsAutoAccept() public {
        // The funder CAN still dispute before the window to route to the arbiter; once
        // Disputed, finalize is an illegal transition (state != Submitted).
        uint256 id = _toSubmitted(NATIVE);
        vm.prank(funder);
        bounty.dispute(id, "contest");
        assertEq(uint8(bounty.stateOf(id)), uint8(IBountyV1.State.Disputed), "Disputed");

        IBountyV1.Bounty memory b = bounty.bounties(id);
        vm.warp(uint256(b.reviewDeadline) + 1);
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                IBountyV1.InvalidState.selector,
                id,
                IBountyV1.State.Disputed,
                IBountyV1.State.Submitted
            )
        );
        bounty.finalize(id);
    }

    // ==================================================================
    // M2 -- anti-self-dealing: funder cannot be its own approver/arbiter
    // ==================================================================

    /// @dev The self-dealing robbery (funder=approver=arbiter disputes its own bounty and
    /// resolves workerAmount=0 + slash-to-self) is UNREACHABLE: it cannot even be proposed.
    function test_SelfDealing_RobberyUnreachableAtPropose() public {
        // funder == approver == arbiter: rejected at the approver check.
        vm.prank(funder);
        vm.expectRevert(IBountyV1.ApproverIsFunder.selector);
        bounty.propose(NATIVE, REWARD, STAKE, funder, funder, WINDOW, REVIEW, "rob");
        // funder == arbiter (distinct approver): rejected at the arbiter check.
        vm.prank(funder);
        vm.expectRevert(IBountyV1.ArbiterIsFunder.selector);
        bounty.propose(NATIVE, REWARD, STAKE, approver, funder, WINDOW, REVIEW, "rob");
    }

    // ==================================================================
    // L1 -- self-review earns no reputation (worker == approver)
    // ==================================================================

    /// @dev A worker who is also the approver (self-review) is PAID but earns no reputation,
    /// so completions/earnings cannot be farmed with a single key. worker == approver is
    /// allowed (M2 only forbids funder == approver); reputation is simply withheld.
    function test_SelfReview_WorkerEqualsApprover_NoReputationButPaid() public {
        vm.deal(funder, REWARD);
        // approver = worker (distinct from funder, so M2 passes).
        vm.prank(funder);
        uint256 id = bounty.propose(NATIVE, REWARD, STAKE, worker, arbiter, WINDOW, REVIEW, "self-review");
        vm.prank(funder);
        bounty.fund{value: REWARD}(id);
        vm.deal(worker, STAKE);
        vm.prank(worker);
        bounty.claim{value: STAKE}(id);
        vm.prank(worker);
        bounty.submit(id, "deliverable");
        // Worker is the approver: accepts its own work.
        vm.prank(worker);
        bounty.accept(id);

        assertEq(uint8(bounty.stateOf(id)), uint8(IBountyV1.State.Paid), "paid");
        assertEq(worker.balance, REWARD + STAKE, "worker paid reward + stake");
        assertEq(rep.completedOf(worker), 0, "no reputation farmed on self-review");
        assertEq(rep.earnedOf(worker), 0, "no earnings farmed on self-review");
    }

    // ==================================================================
    // funder == worker is allowed (only reputation independence differs)
    // ==================================================================

    /// @dev A funder may also be the worker (nothing forbids it). Distinct approver, so M2
    /// passes and reputation IS credited (worker != approver). Conservation holds.
    function test_FunderIsWorker_PaidAndConserves() public {
        vm.deal(funder, REWARD + STAKE);
        uint256 total = _sumNative();

        vm.prank(funder);
        uint256 id = bounty.propose(NATIVE, REWARD, STAKE, approver, arbiter, WINDOW, REVIEW, "self-work");
        vm.prank(funder);
        bounty.fund{value: REWARD}(id);
        // Funder claims their own funded bounty as the worker.
        vm.prank(funder);
        bounty.claim{value: STAKE}(id);
        vm.prank(funder);
        bounty.submit(id, "deliverable");
        vm.prank(approver);
        bounty.accept(id);

        assertEq(uint8(bounty.stateOf(id)), uint8(IBountyV1.State.Paid), "paid");
        assertEq(funder.balance, REWARD + STAKE, "funder-worker made whole (net-zero funding)");
        assertEq(rep.completedOf(funder), 1, "completion credited (worker != approver)");
        assertEq(_sumNative(), total, "conserved across funder-is-worker path");
    }

    // ==================================================================
    // H2 -- fee-on-transfer token is rejected at fund; no lock
    // ==================================================================

    /// @dev Funding with a fee-on-transfer token reverts at the escrow deposit (the exact
    /// nominal amount cannot arrive), so the whole fund() reverts: the bounty stays Open,
    /// nothing is escrowed, and the funder keeps their tokens. No reward is ever stranded.
    function test_FundFeeOnTransferToken_RevertsNoLock() public {
        MockFeeOnTransferERC20 feeToken = new MockFeeOnTransferERC20("Fee", "FEE", 100); // 1% fee
        feeToken.mint(funder, REWARD);

        vm.prank(funder);
        uint256 id = bounty.propose(address(feeToken), REWARD, STAKE, approver, arbiter, WINDOW, REVIEW, "fee");
        vm.prank(funder);
        feeToken.approve(address(escrow), REWARD);

        uint256 fee = (REWARD * 100) / 10_000;
        vm.prank(funder);
        vm.expectRevert(abi.encodeWithSelector(IEscrowV1.DepositAmountMismatch.selector, REWARD, REWARD - fee));
        bounty.fund(id);

        // No lock: bounty still Open, escrow empty, funder still holds the full amount.
        assertEq(uint8(bounty.stateOf(id)), uint8(IBountyV1.State.Open), "still Open (fund reverted)");
        assertEq(feeToken.balanceOf(address(escrow)), 0, "nothing escrowed");
        assertEq(feeToken.balanceOf(funder), REWARD, "funder keeps tokens");
    }

    // ==================================================================
    // helpers
    // ==================================================================

    function _deployMarket(address treasury_) internal returns (BountyV1 b, EscrowV1 e, ReputationV1 r) {
        EscrowV1 ei = new EscrowV1();
        ReputationV1 ri = new ReputationV1();
        BountyV1 bi = new BountyV1();
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 2);
        e = EscrowV1(
            payable(address(new ERC1967Proxy(address(ei), abi.encodeCall(EscrowV1.initialize, (owner, predicted)))))
        );
        r = ReputationV1(
            address(new ERC1967Proxy(address(ri), abi.encodeCall(ReputationV1.initialize, (owner, predicted))))
        );
        b = BountyV1(
            address(
                new ERC1967Proxy(
                    address(bi),
                    abi.encodeCall(BountyV1.initialize, (owner, address(e), address(r), treasury_))
                )
            )
        );
        require(address(b) == predicted, "predict");
    }

    function _proposeAndFundNative() internal returns (uint256 id) {
        vm.deal(funder, funder.balance + REWARD);
        vm.prank(funder);
        id = bounty.propose(NATIVE, REWARD, STAKE, approver, arbiter, WINDOW, REVIEW, "issue");
        vm.prank(funder);
        bounty.fund{value: REWARD}(id);
    }

    function _toSubmitted(address tok) internal returns (uint256 id) {
        if (tok == NATIVE) {
            id = _proposeAndFundNative();
            vm.deal(worker, worker.balance + STAKE);
            vm.prank(worker);
            bounty.claim{value: STAKE}(id);
        } else {
            token.mint(funder, REWARD);
            token.mint(worker, STAKE);
            vm.prank(funder);
            id = bounty.propose(tok, REWARD, STAKE, approver, arbiter, WINDOW, REVIEW, "issue");
            vm.prank(funder);
            token.approve(address(escrow), REWARD);
            vm.prank(funder);
            bounty.fund(id);
            vm.prank(worker);
            token.approve(address(escrow), STAKE);
            vm.prank(worker);
            bounty.claim(id);
        }
        vm.prank(worker);
        bounty.submit(id, "deliverable");
    }

    /// @dev Sum of native held by every actor + the escrow. Invariant across paths.
    function _sumNative() internal view returns (uint256) {
        return
            funder.balance +
            worker.balance +
            approver.balance +
            arbiter.balance +
            stranger.balance +
            treasury.balance +
            address(escrow).balance +
            address(bounty).balance;
    }
}
